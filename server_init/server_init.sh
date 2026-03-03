#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

DRY_RUN="${DRY_RUN:-0}"

print_help() {
    cat <<'EOF'
用法:
  bash server_init.sh --help
  bash server_init.sh --dry-run
  bash server_init.sh --print-os
  bash server_init.sh --print-tui
  bash server_init.sh --tui
  bash server_init.sh create-users --users "u1,u2" [--reset-passwords] (--pubkey "ssh-ed25519 ..." | --pubkey-url "https://...")
  bash server_init.sh disable-root-password-login
  bash server_init.sh change-ssh-port --port <1-65535>
  bash server_init.sh --tui-create-users

说明:
  --help      显示帮助信息（只读）
  --dry-run   演练模式：仅打印计划动作，不执行安装/联网/写入/重启
  --print-os  检测并打印发行版类型（只读，输出 debian 或 arch）
  --print-tui 检测并打印 TUI 后端（只读，输出 whiptail 或 dialog 或 text）
  --tui       显示主菜单（默认无参数时也会进入主菜单）
  create-users 非交互创建/更新用户（需要 root）
  disable-root-password-login 禁止 root 密码登录（保留 root 公钥登录，且不注入 root 公钥）（需要 root）
  change-ssh-port 修改 SSH 监听端口（仅改 Port，带校验与回滚）（需要 root）
  --tui-create-users 交互式创建/更新用户流程（需要 root）

环境变量:
  TUI_FORCE   指定 TUI 后端: auto|whiptail|dialog|text（默认 auto）

注意:
  修改 SSH 配置后请先新开会话验证可登录，再关闭当前会话。
EOF
}

print_dry_run_actions() {
    cat <<'EOF'
[dry-run] 可执行动作:
  - create-users
  - disable-root-password-login
  - change-ssh-port
  - --tui（主菜单可多选并按固定顺序执行）
EOF
}

validate_pubkey_url_source() {
    local url="${1:-}"
    local host=""

    if [[ -z "$url" ]]; then
        echo "错误: 公钥 URL 不能为空" 1>&2
        return 1
    fi
    if [[ ! "$url" =~ ^https:// ]]; then
        echo "错误: 仅允许 HTTPS 公钥 URL: $url" 1>&2
        return 1
    fi

    host="${url#https://}"
    host="${host%%/*}"
    host="${host%%:*}"
    case "$host" in
        github.com|raw.githubusercontent.com|gist.githubusercontent.com)
            return 0
            ;;
        *)
            echo "错误: 不在允许列表的公钥来源主机: $host" 1>&2
            return 1
            ;;
    esac
}

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "错误: 该脚本必须以 root 用户运行" 1>&2
        exit 1
    fi
}

detect_os() {
    local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
    local id=""
    local id_like=""

    if [[ ! -r "$os_release_file" ]]; then
        echo "错误: 无法读取系统信息文件: $os_release_file" 1>&2
        return 1
    fi

    while IFS='=' read -r key value; do
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            ID) id="$value" ;;
            ID_LIKE) id_like="$value" ;;
        esac
    done < "$os_release_file"

    case " $id $id_like " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*)
            echo "debian"
            return 0
            ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*)
            echo "arch"
            return 0
            ;;
    esac

    echo "错误: 仅支持 Debian-like 与 Arch-like 发行版 (ID=$id, ID_LIKE=$id_like)" 1>&2
    return 1
}

pkg_install() {
    require_root
    if [[ "$#" -eq 0 ]]; then
        echo "错误: pkg_install 需要至少一个包名参数" 1>&2
        return 1
    fi

    case "$(detect_os)" in
        debian)
            apt-get update -qq
            apt-get install -y "$@"
            ;;
        arch)
            pacman -Syu --noconfirm --needed "$@"
            ;;
        *)
            echo "错误: 不支持的系统" 1>&2
            return 1
            ;;
    esac
}

ensure_cmd() {
    local cmd_name="${1:-}"
    local debian_pkg="${2:-}"
    local arch_pkg="${3:-}"
    local target_pkg=""
    local os_family=""

    if [[ -z "$cmd_name" ]]; then
        echo "错误: ensure_cmd 缺少命令名参数" 1>&2
        return 1
    fi

    if command -v "$cmd_name" >/dev/null 2>&1; then
        return 0
    fi

    os_family="$(detect_os)"
    case "$os_family" in
        debian)
            target_pkg="$debian_pkg"
            ;;
        arch)
            target_pkg="$arch_pkg"
            ;;
        *)
            echo "错误: 不支持的系统: $os_family" 1>&2
            return 1
            ;;
    esac

    if [[ -z "$target_pkg" ]]; then
        echo "错误: ensure_cmd 缺少 $os_family 对应包名。用法: ensure_cmd <cmd> <debian-pkg> <arch-pkg>" 1>&2
        return 1
    fi

    pkg_install "$target_pkg"
}

validate_pubkey() {
    local line="${1:-}"
    local key_type=""
    local key_data=""

    [[ -n "$line" ]] || return 1

    IFS=' ' read -r key_type key_data _ <<< "$line"
    [[ -n "$key_type" && -n "$key_data" ]] || return 1

    case "$key_type" in
        ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            return 1
            ;;
    esac

    [[ "$key_data" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || return 1
    return 0
}

fetch_pubkeys_from_url() {
    local url="${1:-}"
    local tmp_file=""
    local line=""
    local byte_size=0
    local key_count=0
    local -A seen=()

    if ! validate_pubkey_url_source "$url"; then
        return 1
    fi

    tmp_file="$(mktemp)"
    if ! curl -fsSL --connect-timeout 5 --max-time 15 --max-filesize 65536 "$url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        echo "错误: 下载公钥失败或超出大小限制: $url" 1>&2
        return 1
    fi

    byte_size="$(wc -c < "$tmp_file")"
    if [[ "$byte_size" -gt 65536 ]]; then
        rm -f "$tmp_file"
        echo "错误: 公钥内容超过 65536 字节限制: $url" 1>&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if validate_pubkey "$line"; then
            if [[ -z "${seen[$line]+x}" ]]; then
                printf '%s\n' "$line"
                seen[$line]=1
                key_count=$((key_count + 1))
            fi
        fi
    done < "$tmp_file"

    rm -f "$tmp_file"

    if [[ "$key_count" -eq 0 ]]; then
        echo "错误: 未找到合法 SSH 公钥: $url" 1>&2
        return 1
    fi

    return 0
}

install_pubkeys_for_user() {
    local target_user="${1:-}"
    local passwd_entry=""
    local home_dir=""
    local target_group=""
    local ssh_dir=""
    local auth_keys=""
    local tmp_file=""
    local line=""
    local -A seen=()

    if [[ -z "$target_user" ]]; then
        echo "错误: install_pubkeys_for_user 缺少用户名参数" 1>&2
        return 1
    fi

    shift
    if [[ "$#" -eq 0 ]]; then
        echo "错误: install_pubkeys_for_user 至少需要一条公钥" 1>&2
        return 1
    fi

    passwd_entry="$(getent passwd "$target_user" || true)"
    if [[ -z "$passwd_entry" ]]; then
        echo "错误: 用户不存在: $target_user" 1>&2
        return 1
    fi

    IFS=':' read -r _ _ _ _ _ home_dir _ <<< "$passwd_entry"
    if [[ -z "$home_dir" ]]; then
        echo "错误: 无法解析用户家目录: $target_user" 1>&2
        return 1
    fi

    ssh_dir="$home_dir/.ssh"
    auth_keys="$ssh_dir/authorized_keys"

    umask 077
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_keys"
    chmod 600 "$auth_keys"

    tmp_file="$(mktemp)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "${seen[$line]+x}" ]]; then
            printf '%s\n' "$line" >> "$tmp_file"
            seen[$line]=1
        fi
    done < "$auth_keys"

    for line in "$@"; do
        if ! validate_pubkey "$line"; then
            rm -f "$tmp_file"
            echo "错误: 非法 SSH 公钥: $line" 1>&2
            return 1
        fi
        if [[ -z "${seen[$line]+x}" ]]; then
            printf '%s\n' "$line" >> "$tmp_file"
            seen[$line]=1
        fi
    done

    cat "$tmp_file" > "$auth_keys"
    rm -f "$tmp_file"

    if [[ "$(id -u)" -eq 0 ]]; then
        target_group="$(id -gn "$target_user" 2>/dev/null || true)"
        if [[ -n "$target_group" ]]; then
            chown "$target_user:$target_group" "$ssh_dir" "$auth_keys"
        else
            chown "$target_user" "$ssh_dir" "$auth_keys"
        fi
    fi

    return 0
}

detect_ssh_unit() {
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
            echo "sshd.service"
            return 0
        fi
        if systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
            echo "ssh.service"
            return 0
        fi
    fi

    if [[ -e /etc/systemd/system/sshd.service || -e /lib/systemd/system/sshd.service ]]; then
        echo "sshd.service"
        return 0
    fi
    if [[ -e /etc/systemd/system/ssh.service || -e /lib/systemd/system/ssh.service ]]; then
        echo "ssh.service"
        return 0
    fi

    echo "错误: 未检测到 sshd.service 或 ssh.service。请先安装并启用 openssh 服务。" 1>&2
    return 1
}

sshd_find_binary() {
    local sshd_bin=""
    local candidate=""
    local candidates=(
        "/usr/sbin/sshd"
        "/usr/local/sbin/sshd"
        "/sbin/sshd"
    )

    if sshd_bin="$(command -v sshd 2>/dev/null)" && [[ -n "$sshd_bin" ]]; then
        printf '%s\n' "$sshd_bin"
        return 0
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "错误: 未找到 sshd 可执行文件。请先安装 OpenSSH 服务端。" 1>&2
    return 1
}

sshd_validate_config() {
    local sshd_bin=""
    local validate_output=""

    sshd_bin="$(sshd_find_binary)" || return 1

    if validate_output="$("$sshd_bin" -t 2>&1)"; then
        return 0
    fi

    echo "错误: sshd 配置校验失败（$sshd_bin -t）。" 1>&2
    if [[ -n "$validate_output" ]]; then
        printf '%s\n' "$validate_output" 1>&2
    fi
    return 1
}

choose_sshd_config_target() {
    local main_config="/etc/ssh/sshd_config"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="$dropin_dir/99-server-init.conf"

    if [[ ! -e "$main_config" ]]; then
        echo "错误: SSHD 主配置文件不存在: $main_config" 1>&2
        return 1
    fi

    if [[ -d "$dropin_dir" ]]; then
        printf '%s\n' "$dropin_file"
        return 0
    fi

    if [[ -r "$main_config" ]] && awk '
        BEGIN { found = 0 }
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            low = tolower(line)
            if (low ~ /^[[:space:]]*include[[:space:]]+/) {
                n = split(low, parts, /[[:space:]]+/)
                for (i = 2; i <= n; i++) {
                    if (parts[i] ~ /(^|\/)sshd_config\.d(\/|\*|$)/) {
                        found = 1
                    }
                }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "$main_config"; then
        printf '%s\n' "$dropin_file"
        return 0
    fi

    if [[ -e "$main_config" ]]; then
        printf '%s\n' "$main_config"
        return 0
    fi

    echo "错误: 未找到可用的 SSHD 配置目标（/etc/ssh/sshd_config 或 drop-in）。" 1>&2
    return 1
}

sshd_set_directive_in_file() {
    local file_path="${1:-}"
    local directive="${2:-}"
    local directive_value="${3:-}"
    local tmp_file=""

    if [[ -z "$file_path" || -z "$directive" || -z "$directive_value" ]]; then
        echo "错误: sshd_set_directive_in_file 参数不足" 1>&2
        return 1
    fi

    tmp_file="$(mktemp)"
    if ! awk -v key="$directive" -v value="$directive_value" '
        BEGIN {
            done = 0
            key_pat = "^[[:space:]]*#?[[:space:]]*" key "([[:space:]]+|$)"
        }
        {
            if ($0 ~ key_pat) {
                if (!done) {
                    print key " " value
                    done = 1
                }
                next
            }
            print
        }
        END {
            if (!done) {
                print key " " value
            }
        }
    ' "$file_path" > "$tmp_file"; then
        rm -f "$tmp_file"
        echo "错误: 更新 SSHD 指令失败: $directive" 1>&2
        return 1
    fi

    cat "$tmp_file" > "$file_path"
    rm -f "$tmp_file"
    return 0
}

sshd_read_directive_from_file() {
    local file_path="${1:-}"
    local directive="${2:-}"
    local value=""

    if [[ -z "$file_path" || -z "$directive" ]]; then
        echo "错误: sshd_read_directive_from_file 需要参数 <file_path> <directive>" 1>&2
        return 1
    fi

    if [[ ! -r "$file_path" ]]; then
        return 1
    fi

    value="$(awk -v key="$directive" '
        {
            line = $0
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") {
                next
            }
            n = split(line, parts, /[[:space:]]+/)
            if (n >= 2 && tolower(parts[1]) == tolower(key)) {
                print parts[2]
                exit
            }
        }
    ' "$file_path")"

    if [[ -z "$value" ]]; then
        return 1
    fi

    printf '%s\n' "$value"
    return 0
}

sshd_get_current_port() {
    local dropin_file="/etc/ssh/sshd_config.d/99-server-init.conf"
    local main_config="/etc/ssh/sshd_config"
    local value=""

    if [[ -r "$dropin_file" ]]; then
        value="$(sshd_read_directive_from_file "$dropin_file" "Port" || true)"
    fi

    if [[ -z "$value" && -r "$main_config" ]]; then
        value="$(sshd_read_directive_from_file "$main_config" "Port" || true)"
    fi

    if [[ -z "$value" ]]; then
        value="22"
    fi

    printf '%s\n' "$value"
    return 0
}

sshd_get_current_pubkey_auth() {
    local dropin_file="/etc/ssh/sshd_config.d/99-server-init.conf"
    local main_config="/etc/ssh/sshd_config"
    local value=""

    if [[ -r "$dropin_file" ]]; then
        value="$(sshd_read_directive_from_file "$dropin_file" "PubkeyAuthentication" || true)"
    fi

    if [[ -z "$value" && -r "$main_config" ]]; then
        value="$(sshd_read_directive_from_file "$main_config" "PubkeyAuthentication" || true)"
    fi

    if [[ -z "$value" ]]; then
        value="yes"
    fi

    printf '%s\n' "$value"
    return 0
}

sshd_write_managed_config() {
    local port="${1:-}"
    local permit_root_login="${2:-}"
    local pubkey_auth="${3:-}"
    local target=""

    if [[ -z "$port" || -z "$permit_root_login" || -z "$pubkey_auth" ]]; then
        echo "错误: sshd_write_managed_config 需要参数 <port> <permit_root_login> <pubkey_auth>" 1>&2
        return 1
    fi

    target="$(choose_sshd_config_target)" || return 1

    if [[ "$target" == "/etc/ssh/sshd_config.d/99-server-init.conf" ]]; then
        mkdir -p "/etc/ssh/sshd_config.d"
        cat > "$target" <<EOF
# Managed by server_init.sh
Port $port
PermitRootLogin $permit_root_login
PubkeyAuthentication $pubkey_auth
EOF
        return 0
    fi

    if [[ "$target" != "/etc/ssh/sshd_config" ]]; then
        echo "错误: 非预期的 SSHD 配置目标: $target" 1>&2
        return 1
    fi

    if [[ ! -e "$target" ]]; then
        echo "错误: SSHD 主配置文件不存在: $target" 1>&2
        return 1
    fi

    sshd_set_directive_in_file "$target" "Port" "$port"
    sshd_set_directive_in_file "$target" "PermitRootLogin" "$permit_root_login"
    sshd_set_directive_in_file "$target" "PubkeyAuthentication" "$pubkey_auth"
    return 0
}

sshd_apply_with_rollback() {
    local port="${1:-}"
    local permit_root_login="${2:-}"
    local pubkey_auth="${3:-}"
    local ssh_unit=""
    local target=""
    local backup=""
    local had_original="0"

    if [[ -z "$port" || -z "$permit_root_login" || -z "$pubkey_auth" ]]; then
        echo "错误: sshd_apply_with_rollback 需要参数 <port> <permit_root_login> <pubkey_auth>" 1>&2
        return 1
    fi

    require_root
    ssh_unit="$(detect_ssh_unit)" || return 1
    target="$(choose_sshd_config_target)" || return 1

    if [[ -e "$target" ]]; then
        backup="$(mktemp)"
        cp -a "$target" "$backup"
        had_original="1"
    fi

    if ! sshd_write_managed_config "$port" "$permit_root_login" "$pubkey_auth"; then
        if [[ "$had_original" == "1" ]]; then
            cat "$backup" > "$target"
        else
            rm -f "$target"
        fi
        rm -f "$backup"
        return 1
    fi

    if ! sshd_validate_config; then
        if [[ "$had_original" == "1" ]]; then
            cat "$backup" > "$target"
        else
            rm -f "$target"
        fi
        rm -f "$backup"
        return 1
    fi

    if systemctl restart "$ssh_unit"; then
        rm -f "$backup"
        return 0
    fi

    echo "警告: SSH 服务重启失败，正在回滚配置并重试一次。" 1>&2
    if [[ "$had_original" == "1" ]]; then
        cat "$backup" > "$target"
    else
        rm -f "$target"
    fi

    rm -f "$backup"

    if ! sshd_validate_config; then
        echo "错误: 回滚后 sshd 配置校验失败，请手动介入。" 1>&2
        return 1
    fi

    if ! systemctl restart "$ssh_unit"; then
        echo "错误: 回滚后 SSH 服务重启仍失败，请手动排查。" 1>&2
        return 1
    fi

    return 0
}

sshd_apply_port_with_rollback() {
    local port="${1:-}"
    local ssh_unit=""
    local target=""
    local backup=""
    local had_original="0"

    if [[ -z "$port" ]]; then
        echo "错误: sshd_apply_port_with_rollback 需要参数 <port>" 1>&2
        return 1
    fi

    require_root
    ssh_unit="$(detect_ssh_unit)" || return 1
    target="$(choose_sshd_config_target)" || return 1

    if [[ "$target" == "/etc/ssh/sshd_config.d/99-server-init.conf" ]]; then
        mkdir -p "/etc/ssh/sshd_config.d"
        if [[ ! -e "$target" ]]; then
            : > "$target"
        fi
    fi

    if [[ -e "$target" ]]; then
        backup="$(mktemp)"
        cp -a "$target" "$backup"
        had_original="1"
    fi

    if ! sshd_set_directive_in_file "$target" "Port" "$port"; then
        if [[ "$had_original" == "1" ]]; then
            cat "$backup" > "$target"
        else
            rm -f "$target"
        fi
        rm -f "$backup"
        return 1
    fi

    if ! sshd_validate_config; then
        if [[ "$had_original" == "1" ]]; then
            cat "$backup" > "$target"
        else
            rm -f "$target"
        fi
        rm -f "$backup"
        return 1
    fi

    if systemctl restart "$ssh_unit"; then
        rm -f "$backup"
        return 0
    fi

    echo "警告: SSH 服务重启失败，正在回滚配置并重试一次。" 1>&2
    if [[ "$had_original" == "1" ]]; then
        cat "$backup" > "$target"
    else
        rm -f "$target"
    fi
    rm -f "$backup"

    if ! sshd_validate_config; then
        echo "错误: 回滚后 sshd 配置校验失败，请手动介入。" 1>&2
        return 1
    fi

    if ! systemctl restart "$ssh_unit"; then
        echo "错误: 回滚后 SSH 服务重启仍失败，请手动排查。" 1>&2
        return 1
    fi

    return 0
}

cmd_disable_root_password_login() {
    local current_port=""
    local current_pubkey_auth=""

    if [[ "$#" -gt 0 ]]; then
        if [[ "$1" == "--help" || "$1" == "-h" ]]; then
            cat <<'EOF'
用法:
  bash server_init.sh disable-root-password-login

说明:
  设置 PermitRootLogin prohibit-password，禁止 root 密码登录。
  保持当前 Port 与 PubkeyAuthentication 不变，不修改 PasswordAuthentication。
EOF
            return 0
        fi
        echo "错误: disable-root-password-login 不接受参数" 1>&2
        return 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] disable-root-password-login"
        echo "[dry-run] 计划: 设置 PermitRootLogin prohibit-password，保持当前 Port 与 PubkeyAuthentication"
        return 0
    fi

    require_root

    current_port="$(sshd_get_current_port)"
    current_pubkey_auth="$(sshd_get_current_pubkey_auth)"

    sshd_apply_with_rollback "$current_port" "prohibit-password" "$current_pubkey_auth"
    echo "提示: 已设置 PermitRootLogin prohibit-password。仍允许 root 使用密钥登录，但本脚本不会注入 root 公钥。"
}

print_change_ssh_port_help() {
    cat <<'EOF'
用法:
  bash server_init.sh change-ssh-port --port <1-65535>

参数:
  --port    目标 SSH 监听端口（必须为 1-65535）
  --help    显示本帮助

说明:
  仅更新 Port 指令，不修改 PermitRootLogin 与 PubkeyAuthentication。
  变更前会输出风险提示；变更后请先新开 SSH 会话验证，再关闭当前会话。
EOF
}

validate_port_range() {
    local port="${1:-}"

    if [[ -z "$port" ]]; then
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        return 1
    fi

    return 0
}

cmd_change_ssh_port() {
    local arg=""
    local port=""

    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --help|-h)
                print_change_ssh_port_help
                return 0
                ;;
            --port)
                if [[ "$#" -lt 2 ]]; then
                    echo "错误: --port 需要参数" 1>&2
                    return 1
                fi
                port="$2"
                shift 2
                ;;
            *)
                echo "错误: change-ssh-port 未知参数: $arg" 1>&2
                return 1
                ;;
        esac
    done

    if ! validate_port_range "$port"; then
        echo "错误: 无效端口: $port（允许范围 1-65535）" 1>&2
        return 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s\n' "[dry-run] change-ssh-port"
        printf '%s\n' "[dry-run] 计划: 将 SSH 端口改为 $port（不会写配置，不会重启服务）"
        return 0
    fi

    printf '%s\n' "危险提示: 修改 SSH 端口可能导致当前会话断开或无法重连。"
    printf '%s\n' "请先确认新端口已放行且有备用会话。"

    if ! tui_confirm "危险确认" "即将修改 SSH 端口为 $port，可能导致失联。确认继续？"; then
        echo "已取消: 未修改 SSH 端口。"
        return 0
    fi

    sshd_apply_port_with_rollback "$port"

    printf '%s\n' "完成: SSH 端口已更新为 $port。"
    printf '%s\n' "重连示例: ssh -p $port <user>@<server-ip>"
    printf '%s\n' "重要: 请先新开一个 SSH 会话验证登录成功，再退出当前会话。"
    return 0
}

tui_detect_backend() {
    local allow_install="${1:-0}"
    local force="${TUI_FORCE:-auto}"

    case "$force" in
        text)
            echo "text"
            return 0
            ;;
        auto)
            if command -v whiptail >/dev/null 2>&1; then
                echo "whiptail"
                return 0
            fi
            if command -v dialog >/dev/null 2>&1; then
                echo "dialog"
                return 0
            fi
            echo "text"
            return 0
            ;;
        whiptail)
            if command -v whiptail >/dev/null 2>&1; then
                echo "whiptail"
                return 0
            fi
            if [[ "$allow_install" == "1" ]]; then
                ensure_cmd whiptail whiptail libnewt
                if command -v whiptail >/dev/null 2>&1; then
                    echo "whiptail"
                    return 0
                fi
            fi
            echo "错误: TUI_FORCE=whiptail 但系统缺少 whiptail" 1>&2
            return 1
            ;;
        dialog)
            if command -v dialog >/dev/null 2>&1; then
                echo "dialog"
                return 0
            fi
            if [[ "$allow_install" == "1" ]]; then
                ensure_cmd dialog dialog dialog
                if command -v dialog >/dev/null 2>&1; then
                    echo "dialog"
                    return 0
                fi
            fi
            echo "错误: TUI_FORCE=dialog 但系统缺少 dialog" 1>&2
            return 1
            ;;
        *)
            echo "错误: 无效的 TUI_FORCE: $force (允许值: auto|whiptail|dialog|text)" 1>&2
            return 1
            ;;
    esac
}

tui_msg() {
    local title="${1:-提示}"
    local text="${2:-}"
    local backend=""

    backend="$(tui_detect_backend "${TUI_ALLOW_INSTALL:-0}")"
    case "$backend" in
        whiptail)
            whiptail --title "$title" --msgbox "$text" 12 70
            ;;
        dialog)
            dialog --title "$title" --msgbox "$text" 12 70
            ;;
        text)
            printf '=== %s ===\n%s\n' "$title" "$text" >&2
            ;;
    esac
}

tui_confirm() {
    local title="${1:-确认}"
    local text="${2:-是否继续?}"
    local backend=""
    local reply=""

    backend="$(tui_detect_backend "${TUI_ALLOW_INSTALL:-0}")"
    case "$backend" in
        whiptail)
            whiptail --title "$title" --yesno "$text" 12 70
            return $?
            ;;
        dialog)
            dialog --title "$title" --yesno "$text" 12 70
            return $?
            ;;
        text)
            printf '=== %s ===\n%s [y/N]: ' "$title" "$text" >&2
            if ! IFS= read -r reply; then
                reply=""
            fi
            case "$reply" in
                y|Y|yes|YES)
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
    esac
}

tui_input() {
    local title="${1:-输入}"
    local prompt="${2:-请输入内容:}"
    local default_value="${3:-}"
    local backend=""
    local result=""

    backend="$(tui_detect_backend "${TUI_ALLOW_INSTALL:-0}")"
    case "$backend" in
        whiptail)
            result="$(whiptail --title "$title" --inputbox "$prompt" 12 70 "$default_value" 3>&1 1>&2 2>&3)" || return $?
            printf '%s\n' "$result"
            ;;
        dialog)
            result="$(dialog --stdout --title "$title" --inputbox "$prompt" 12 70 "$default_value")" || return $?
            printf '%s\n' "$result"
            ;;
        text)
            printf '=== %s ===\n%s' "$title" "$prompt" >&2
            if [[ -n "$default_value" ]]; then
                printf ' [%s]' "$default_value" >&2
            fi
            printf ': ' >&2
            if ! IFS= read -r result; then
                result=""
            fi
            if [[ -z "$result" ]]; then
                result="$default_value"
            fi
            printf '%s\n' "$result"
            ;;
    esac
}

tui_checklist() {
    local title="${1:-选择}"
    local prompt="${2:-请选择:}"
    shift 2
    local items=("$@")
    local backend=""
    local output=""
    local defaults=()
    local idx=0
    local input_line=""
    local token=""

    backend="$(tui_detect_backend "${TUI_ALLOW_INSTALL:-0}")"
    case "$backend" in
        whiptail)
            output="$(whiptail --title "$title" --checklist "$prompt" 20 78 10 --separate-output "${items[@]}" 3>&1 1>&2 2>&3)" || return $?
            printf '%s\n' "$output"
            ;;
        dialog)
            output="$(dialog --stdout --title "$title" --checklist "$prompt" 20 78 10 "${items[@]}")" || return $?
            printf '%s\n' "$output"
            ;;
        text)
            printf '=== %s ===\n%s\n' "$title" "$prompt" >&2
            while [[ "$idx" -lt "${#items[@]}" ]]; do
                local tag="${items[$idx]}"
                local desc="${items[$((idx + 1))]:-}"
                local state="${items[$((idx + 2))]:-off}"
                printf '[ ] %s - %s' "$tag" "$desc" >&2
                case "$state" in
                    on|ON|true|TRUE|1)
                        defaults+=("$tag")
                        printf ' (默认选中)' >&2
                        ;;
                esac
                printf '\n' >&2
                idx=$((idx + 3))
            done

            printf '输入要选择的 tag（空格分隔，留空=默认）: ' >&2
            if ! IFS= read -r input_line; then
                input_line=""
            fi

            if [[ -z "$input_line" ]]; then
                printf '%s\n' "${defaults[@]}"
            else
                for token in $input_line; do
                    printf '%s\n' "$token"
                done
            fi
            ;;
    esac
}

validate_username() {
    local username="${1:-}"
    [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

split_csv_users() {
    local csv="${1:-}"
    local token=""
    local -A seen=()

    if [[ -z "$csv" ]]; then
        echo "错误: 用户列表不能为空" 1>&2
        return 1
    fi

    csv="${csv//,/ }"
    for token in $csv; do
        [[ -z "$token" ]] && continue
        if ! validate_username "$token"; then
            echo "错误: 非法用户名: $token" 1>&2
            return 1
        fi
        if [[ -z "${seen[$token]+x}" ]]; then
            printf '%s\n' "$token"
            seen[$token]=1
        fi
    done

    if [[ "${#seen[@]}" -eq 0 ]]; then
        echo "错误: 未解析到有效用户名" 1>&2
        return 1
    fi

    return 0
}

parse_users_csv() {
    split_csv_users "$@"
}

parse_pubkeys_from_text() {
    local raw_text="${1:-}"
    local line=""
    local key_count=0
    local -A seen=()

    if [[ -z "$raw_text" ]]; then
        echo "错误: 公钥文本不能为空" 1>&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if ! validate_pubkey "$line"; then
            echo "错误: 非法 SSH 公钥: $line" 1>&2
            return 1
        fi
        if [[ -z "${seen[$line]+x}" ]]; then
            printf '%s\n' "$line"
            seen[$line]=1
            key_count=$((key_count + 1))
        fi
    done <<< "$raw_text"

    if [[ "$key_count" -eq 0 ]]; then
        echo "错误: 未提供有效 SSH 公钥" 1>&2
        return 1
    fi

    return 0
}

ensure_group_exists() {
    local group_name="${1:-}"

    if [[ -z "$group_name" ]]; then
        echo "错误: ensure_group_exists 缺少组名" 1>&2
        return 1
    fi

    require_root
    ensure_cmd groupadd passwd shadow
    if ! getent group "$group_name" >/dev/null 2>&1; then
        groupadd "$group_name"
    fi
}

resolve_sudo_group() {
    require_root
    if getent group sudo >/dev/null 2>&1; then
        printf 'sudo\n'
        return 0
    fi
    if getent group wheel >/dev/null 2>&1; then
        printf 'wheel\n'
        return 0
    fi
    ensure_group_exists "sudo"
    printf 'sudo\n'
}

create_sudoers_for_user() {
    local target_user="${1:-}"
    local sudoers_file=""
    local tmp_file=""

    if [[ -z "$target_user" ]]; then
        echo "错误: create_sudoers_for_user 缺少用户名" 1>&2
        return 1
    fi

    require_root
    ensure_cmd visudo sudo sudo
    sudoers_file="/etc/sudoers.d/server-init-$target_user"
    tmp_file="$(mktemp)"

    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$target_user" > "$tmp_file"
    chmod 0440 "$tmp_file"

    if ! visudo -cf "$tmp_file" >/dev/null; then
        rm -f "$tmp_file"
        echo "错误: 生成的 sudoers 内容校验失败: $target_user" 1>&2
        return 1
    fi

    install -m 0440 "$tmp_file" "$sudoers_file"
    rm -f "$tmp_file"
    return 0
}

ensure_sudoers_nopasswd() {
    create_sudoers_for_user "$@"
}

create_credentials_file() {
    local output_file=""
    require_root
    output_file="/root/server_init_credentials_$(date +%Y%m%d_%H%M%S).txt"
    umask 077
    : > "$output_file"
    chmod 600 "$output_file"
    printf '%s\n' "$output_file"
}

write_credentials_file() {
    create_credentials_file "$@"
}

generate_random_password() {
    ensure_cmd openssl openssl openssl
    openssl rand -base64 18
}

provision_user_with_access() {
    local target_user="${1:-}"
    local sudo_group="${2:-}"
    local reset_existing_password="${3:-0}"
    local credentials_file="${4:-}"
    shift 4
    local pubkeys=("$@")
    local user_exists="0"
    local password=""

    if [[ -z "$target_user" || -z "$sudo_group" || -z "$credentials_file" ]]; then
        echo "错误: provision_user_with_access 参数不足" 1>&2
        return 1
    fi
    if ! validate_username "$target_user"; then
        echo "错误: 非法用户名: $target_user" 1>&2
        return 1
    fi
    if [[ "${#pubkeys[@]}" -eq 0 ]]; then
        echo "错误: 用户 $target_user 缺少公钥" 1>&2
        return 1
    fi

    require_root
    ensure_cmd useradd passwd shadow
    ensure_cmd usermod passwd shadow
    ensure_cmd chpasswd passwd shadow

    if id -u "$target_user" >/dev/null 2>&1; then
        user_exists="1"
    else
        useradd -m -s /bin/bash "$target_user"
    fi

    if [[ "$user_exists" == "0" || "$reset_existing_password" == "1" ]]; then
        password="$(generate_random_password)"
        printf '%s:%s\n' "$target_user" "$password" | chpasswd

        if [[ "$user_exists" == "0" ]]; then
            printf 'NEW %s %s\n' "$target_user" "$password" >> "$credentials_file"
        else
            printf 'RESET %s %s\n' "$target_user" "$password" >> "$credentials_file"
        fi
        printf '用户 %s 的密码: %s\n' "$target_user" "$password"
    fi

    usermod -aG "$sudo_group" "$target_user"
    ensure_docker_group
    usermod -aG docker "$target_user"

    ensure_sudoers_nopasswd "$target_user"
    install_pubkeys_for_user "$target_user" "${pubkeys[@]}"
    return 0
}

ensure_docker_group() {
    ensure_group_exists "docker"
}

create_users() {
    local reset_existing_password="${1:-0}"
    local users_csv="${2:-}"
    shift 2
    local pubkeys=("$@")
    local sudo_group=""
    local credentials_file=""
    local username=""
    local -a users=()

    if [[ "$DRY_RUN" == "1" ]]; then
        mapfile -t users < <(parse_users_csv "$users_csv")
        echo "[dry-run] create-users"
        if [[ "${#users[@]}" -eq 0 ]]; then
             echo "[dry-run] 警告: 用户列表为空"
        else
             echo "[dry-run] users: ${users[*]}"
        fi
        echo "[dry-run] reset-passwords=$reset_existing_password"
        echo "[dry-run] pubkey-count=$#"
        echo "[dry-run] 计划: 创建/更新用户、分配 sudo/docker、写入 authorized_keys (跳过 root 检查与实际操作)"
        return 0
    fi

    require_root
    ensure_cmd visudo sudo sudo
    ensure_cmd useradd passwd shadow
    ensure_cmd openssl openssl openssl

    mapfile -t users < <(parse_users_csv "$users_csv")
    if [[ "${#users[@]}" -eq 0 ]]; then
        echo "错误: 用户列表为空" 1>&2
        return 1
    fi
    if [[ "${#pubkeys[@]}" -eq 0 ]]; then
        echo "错误: 公钥列表为空" 1>&2
        return 1
    fi

    sudo_group="$(resolve_sudo_group)"
    credentials_file="$(write_credentials_file)"

    for username in "${users[@]}"; do
        provision_user_with_access "$username" "$sudo_group" "$reset_existing_password" "$credentials_file" "${pubkeys[@]}"
    done

    echo "凭据文件已写入: $credentials_file"
    return 0
}

create_users_with_pubkeys() {
    create_users "$@"
}

print_create_users_help() {
    cat <<'EOF'
用法:
  bash server_init.sh create-users --users "u1,u2" [--reset-passwords] (--pubkey "ssh-ed25519 ..." | --pubkey-url "https://...")

参数:
  --users            逗号分隔用户名列表
  --pubkey           直接传入公钥文本（可包含换行）
  --pubkey-url       从 HTTPS URL 获取公钥
  --reset-passwords  对已存在用户重置随机密码（默认不重置）
  --help             显示本帮助
EOF
}

cmd_create_users() {
    local users_arg=""
    local pubkey_text=""
    local pubkey_url=""
    local reset_passwords="0"
    local arg=""
    local -a pubkeys=()

    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --help|-h)
                print_create_users_help
                return 0
                ;;
            --users)
                if [[ "$#" -lt 2 ]]; then
                    echo "错误: --users 需要参数" 1>&2
                    return 1
                fi
                users_arg="$2"
                shift 2
                ;;
            --pubkey)
                if [[ "$#" -lt 2 ]]; then
                    echo "错误: --pubkey 需要参数" 1>&2
                    return 1
                fi
                pubkey_text="$2"
                shift 2
                ;;
            --pubkey-url)
                if [[ "$#" -lt 2 ]]; then
                    echo "错误: --pubkey-url 需要参数" 1>&2
                    return 1
                fi
                pubkey_url="$2"
                shift 2
                ;;
            --reset-passwords)
                reset_passwords="1"
                shift
                ;;
            *)
                echo "错误: create-users 未知参数: $arg" 1>&2
                return 1
                ;;
        esac
    done

    if [[ -z "$users_arg" ]]; then
        echo "错误: 必须提供 --users \"u1,u2\"" 1>&2
        return 1
    fi

    if [[ -n "$pubkey_text" && -n "$pubkey_url" ]]; then
        echo "错误: --pubkey 与 --pubkey-url 只能二选一" 1>&2
        return 1
    fi
    if [[ -z "$pubkey_text" && -z "$pubkey_url" ]]; then
        echo "错误: 必须提供 --pubkey 或 --pubkey-url" 1>&2
        return 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ -n "$pubkey_url" ]]; then
            validate_pubkey_url_source "$pubkey_url"
        fi
        echo "[dry-run] create-users"
        echo "[dry-run] users=$users_arg"
        if [[ "$reset_passwords" == "1" ]]; then
            echo "[dry-run] reset-passwords=on"
        else
            echo "[dry-run] reset-passwords=off"
        fi
        if [[ -n "$pubkey_text" ]]; then
            echo "[dry-run] pubkey-source=--pubkey"
        else
            echo "[dry-run] pubkey-source=--pubkey-url $pubkey_url"
        fi
        echo "[dry-run] 计划: 创建/更新用户、分配 sudo/docker、写入 authorized_keys"
        return 0
    fi

    if [[ -n "$pubkey_text" ]]; then
        mapfile -t pubkeys < <(parse_pubkeys_from_text "$pubkey_text")
    else
        ensure_cmd curl curl curl
        mapfile -t pubkeys < <(fetch_pubkeys_from_url "$pubkey_url")
    fi

    require_root
    create_users "$reset_passwords" "$users_arg" "${pubkeys[@]}"
}

tui_collect_batch_users() {
    local -a checklist_items=(
        "pub" "预置用户 pub" "on"
        "silencer" "预置用户 silencer" "on"
        "kortan" "预置用户 kortan" "on"
        "universal" "预置用户 universal" "on"
    )
    local extra_users=""
    local token=""
    local -a selected=()
    local -a extras=()
    local -A seen=()

    mapfile -t selected < <(tui_checklist "批量用户" "选择默认用户（可取消）:" "${checklist_items[@]}")
    extra_users="$(tui_input "批量用户" "可添加自定义用户名（逗号分隔，可留空）:" "")" || return 1

    if [[ -n "$extra_users" ]]; then
        mapfile -t extras < <(parse_users_csv "$extra_users")
    fi

    for token in "${selected[@]}" "${extras[@]}"; do
        [[ -z "$token" ]] && continue
        if ! validate_username "$token"; then
            echo "错误: 非法用户名: $token" 1>&2
            return 1
        fi
        if [[ -z "${seen[$token]+x}" ]]; then
            printf '%s\n' "$token"
            seen[$token]=1
        fi
    done

    if [[ "${#seen[@]}" -eq 0 ]]; then
        echo "错误: 未选择任何用户名" 1>&2
        return 1
    fi

    return 0
}

tui_collect_pubkeys() {
    local source_mode=""
    local pasted_key=""
    local pubkey_url=""

    if tui_confirm "公钥来源" "是否从 HTTPS URL 获取公钥？（否则手动粘贴）"; then
        pubkey_url="$(tui_input "公钥 URL" "请输入 HTTPS 公钥地址:" "https://")" || return 1
        ensure_cmd curl curl curl
        fetch_pubkeys_from_url "$pubkey_url"
        return $?
    fi

    pasted_key="$(tui_input "粘贴公钥" "请输入 SSH 公钥（可多行粘贴）:" "")" || return 1
    parse_pubkeys_from_text "$pasted_key"
}

tui_create_users_flow() {
    local mode_is_batch="0"
    local reset_existing="0"
    local single_user=""
    local users_csv=""
    local item=""
    local -a users=()
    local -a pubkeys=()

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[dry-run] tui-create-users: 跳过交互式流程。"
        echo "[dry-run] 若要测试 create-users 逻辑，请使用: bash server_init.sh --dry-run create-users ..."
        return 0
    fi

    require_root

    if tui_confirm "创建用户" "是否使用批量预置模式？"; then
        mode_is_batch="1"
    fi

    if [[ "$mode_is_batch" == "1" ]]; then
        mapfile -t users < <(tui_collect_batch_users)
    else
        single_user="$(tui_input "单用户" "请输入用户名:" "")" || return 1
        if ! validate_username "$single_user"; then
            echo "错误: 非法用户名: $single_user" 1>&2
            return 1
        fi
        users=("$single_user")
    fi

    if [[ "${#users[@]}" -eq 0 ]]; then
        echo "错误: 用户列表为空" 1>&2
        return 1
    fi

    mapfile -t pubkeys < <(tui_collect_pubkeys)
    if [[ "${#pubkeys[@]}" -eq 0 ]]; then
        echo "错误: 公钥列表为空" 1>&2
        return 1
    fi

    if tui_confirm "密码策略" "检测到已存在用户时，是否重置其密码？"; then
        reset_existing="1"
    fi

    for item in "${users[@]}"; do
        if [[ -z "$users_csv" ]]; then
            users_csv="$item"
        else
            users_csv="$users_csv,$item"
        fi
    done

    create_users "$reset_existing" "$users_csv" "${pubkeys[@]}"
}

tui_selection_has_tag() {
    local tag="${1:-}"
    shift || true
    local selected=""

    for selected in "$@"; do
        if [[ "$selected" == "$tag" ]]; then
            return 0
        fi
    done

    return 1
}

tui_main_menu_flow() {
    local -a checklist_items=(
        "create-users" "Create users" "off"
        "disable-root-password-login" "Disable root password login" "off"
        "change-ssh-port" "Change SSH port" "off"
    )
    local -a selected=()
    local target_port=""

    if [[ "$DRY_RUN" == "1" ]]; then
        print_dry_run_actions
        return 0
    fi

    mapfile -t selected < <(tui_checklist "Main Menu" "选择要执行的动作（可多选）:" "${checklist_items[@]}")
    if [[ "${#selected[@]}" -eq 0 ]]; then
        tui_msg "Main Menu" "未选择任何动作，已退出。"
        return 0
    fi

    if tui_selection_has_tag "create-users" "${selected[@]}"; then
        tui_create_users_flow
    fi

    if tui_selection_has_tag "disable-root-password-login" "${selected[@]}"; then
        if tui_confirm "确认" "即将禁用 root 密码登录（保留 root 密钥登录）。是否继续？"; then
            cmd_disable_root_password_login
        else
            echo "已跳过: disable-root-password-login"
        fi
    fi

    if tui_selection_has_tag "change-ssh-port" "${selected[@]}"; then
        target_port="$(tui_input "Change SSH Port" "请输入目标 SSH 端口（1-65535）:" "14535")" || return 1
        if ! tui_confirm "危险确认" "修改 SSH 端口可能导致失联。确认改为 $target_port？"; then
            echo "已跳过: change-ssh-port"
            return 0
        fi
        cmd_change_ssh_port --port "$target_port"
    fi

    return 0
}

main() {
    local action=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="1"
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    action="${1:-}"

    if [[ "$DRY_RUN" == "1" && -z "$action" ]]; then
        print_dry_run_actions
        return 0
    fi

    case "$action" in
        --help|-h)
            print_help
            ;;
        --print-os)
            detect_os
            ;;
        --print-tui)
            tui_detect_backend 0
            ;;
        --tui)
            shift
            while [[ "$#" -gt 0 ]]; do
                case "$1" in
                    --dry-run)
                        DRY_RUN="1"
                        shift
                        ;;
                    *)
                        echo "错误: --tui 未知参数: $1" 1>&2
                        return 1
                        ;;
                esac
            done
            tui_main_menu_flow
            ;;
        --tui-create-users)
            tui_create_users_flow
            ;;
        create-users)
            shift
            cmd_create_users "$@"
            ;;
        disable-root-password-login)
            shift
            cmd_disable_root_password_login "$@"
            ;;
        change-ssh-port)
            shift
            cmd_change_ssh_port "$@"
            ;;
        "")
            tui_main_menu_flow
            ;;
        *)
            echo "错误: 未知参数: $action" 1>&2
            print_help 1>&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
