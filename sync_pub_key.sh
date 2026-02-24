#!/usr/bin/env bash
set -euo pipefail

# 用法：
#   ./sync_github_keys.sh https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>
# 示例：
#   ./sync_github_keys.sh https://raw.githubusercontent.com/acme/keys/main/authorized_keys

RAW_URL="${1:-}"

if [[ -z "${RAW_URL}" ]]; then
  echo "Usage: $0 <github_raw_url>" >&2
  exit 1
fi

SSH_DIR="${HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

MARK_BEGIN="# BEGIN github-public-keys ${RAW_URL}"
MARK_END="# END github-public-keys"

umask 077
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

tmp="$(mktemp)"
cleanup() { rm -f "${tmp}"; }
trap cleanup EXIT

# 下载
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${RAW_URL}" -o "${tmp}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${tmp}" "${RAW_URL}"
else
  echo "Need curl or wget" >&2
  exit 1
fi

# 仅保留合法公钥行（ssh-ed25519），去掉空行/注释，去重
keys_filtered="$(mktemp)"
trap 'rm -f "${tmp}" "${keys_filtered}"' EXIT

awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  $1 == "ssh-ed25519" && $2 ~ /^[A-Za-z0-9+\/=]+$/ { print $0 }
' "${tmp}" | awk '!seen[$0]++' > "${keys_filtered}"

if [[ ! -s "${keys_filtered}" ]]; then
  echo "No ssh-ed25519 public keys found at: ${RAW_URL}" >&2
  exit 1
fi

# 确保 authorized_keys 存在
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"

# 移除旧标记块（如果存在），再写入新块
# macOS/BSD sed 与 GNU sed 兼容处理：
remove_block() {
  # 删除 MARK_BEGIN 到 MARK_END（含）之间的内容
  sed "/^$(printf '%s' "${MARK_BEGIN}" | sed 's/[\/&]/\\&/g')$/,/^$(printf '%s' "${MARK_END}" | sed 's/[\/&]/\\&/g')$/d" "${AUTH_KEYS}"
}

auth_new="$(mktemp)"
trap 'rm -f "${tmp}" "${keys_filtered}" "${auth_new}"' EXIT

remove_block > "${auth_new}"

{
  cat "${auth_new}"
  echo "${MARK_BEGIN}"
  cat "${keys_filtered}"
  echo "${MARK_END}"
} > "${AUTH_KEYS}"

echo "Synced $(wc -l < "${keys_filtered}") key(s) into ${AUTH_KEYS}"
