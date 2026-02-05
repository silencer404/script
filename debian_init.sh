#!/bin/bash

# ============================================================
# Debian 13 服务器初始化脚本
# 作者: Linux Expert
# 功能: 用户创建、SSH配置、Sudo配置、Docker组配置
# ============================================================

# 检查是否以 root 运行
if [ "$(id -u)" != "0" ]; then
   echo "错误: 该脚本必须以 root 用户运行" 1>&2
   exit 1
fi

# ------------------------------------------------------------
# 0. 获取 SSH 公钥输入
# ------------------------------------------------------------
echo "============================================================"
echo "请输入您的 ed25519 公钥 (例如: ssh-ed25519 AAAA...):"
echo "该公钥将被添加到 root, pub, silencer 用户中。"
echo "============================================================"
read -r SSH_PUB_KEY

if [[ -z "$SSH_PUB_KEY" ]]; then
    echo "错误: 未输入公钥，脚本终止。"
    exit 1
fi

echo "已读取公钥，开始执行初始化..."

# ------------------------------------------------------------
# 1. 基础环境检查与安装
# ------------------------------------------------------------
echo "[+] 更新软件源并检查 sudo..."
apt-get update -qq
if ! command -v sudo &> /dev/null; then
    echo "[+] 安装 sudo..."
    apt-get install -y sudo
else
    echo "[+] sudo 已安装。"
fi

# 检查 docker 组是否存在，不存在则创建 (防止 usermod 报错)
if ! getent group docker > /dev/null; then
    echo "[+] Docker 组不存在，正在创建..."
    groupadd docker
fi

# ------------------------------------------------------------
# 2. 创建用户、设置密码、配置组
# ------------------------------------------------------------
USERS=("pub" "silencer" "kortan" "universal")
declare -A USER_PASSWORDS

echo "[+] 开始创建用户..."

for USER_NAME in "${USERS[@]}"; do
    # 创建用户 (如果不存在)
    if id "$USER_NAME" &>/dev/null; then
        echo "    用户 $USER_NAME 已存在，跳过创建，仅更新配置。"
    else
        useradd -m -d "/home/$USER_NAME" -s /bin/bash "$USER_NAME"
        echo "    用户 $USER_NAME 创建成功。"
    fi

    # 生成随机密码 (16位)
    RAND_PASS=$(openssl rand -base64 12)
    echo "$USER_NAME:$RAND_PASS" | chpasswd
    USER_PASSWORDS[$USER_NAME]=$RAND_PASS

    # 加入 sudo 组
    usermod -aG sudo "$USER_NAME"

    # 加入 docker 组
    usermod -aG docker "$USER_NAME"

    # 配置 sudo 免密
    # 在 /etc/sudoers.d/ 下创建独立文件，更安全
    echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/$USER_NAME"
    chmod 0440 "/etc/sudoers.d/$USER_NAME"
done

# ------------------------------------------------------------
# 3. 特殊目录创建
# ------------------------------------------------------------
echo "[+] 创建 /home/pub/docker 目录..."
mkdir -p /home/pub/docker
chown pub:pub /home/pub/docker
chmod 755 /home/pub/docker

# ------------------------------------------------------------
# 4. 配置 SSH 密钥 (Root, Pub, Silencer)
# ------------------------------------------------------------
echo "[+] 配置 SSH 密钥..."

add_ssh_key() {
    local TARGET_USER=$1
    local KEY=$2
    local HOME_DIR
    
    if [ "$TARGET_USER" == "root" ]; then
        HOME_DIR="/root"
    else
        HOME_DIR="/home/$TARGET_USER"
    fi

    mkdir -p "$HOME_DIR/.ssh"
    echo "$KEY" >> "$HOME_DIR/.ssh/authorized_keys"
    
    # 设置权限
    chmod 700 "$HOME_DIR/.ssh"
    chmod 600 "$HOME_DIR/.ssh/authorized_keys"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.ssh"
    
    echo "    已添加密钥到用户: $TARGET_USER"
}

add_ssh_key "root" "$SSH_PUB_KEY"
add_ssh_key "pub" "$SSH_PUB_KEY"
add_ssh_key "silencer" "$SSH_PUB_KEY"

# ------------------------------------------------------------
# 5. 修改 SSHD 配置
# ------------------------------------------------------------
echo "[+] 修改 SSH 配置文件 (/etc/ssh/sshd_config)..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# 备份原始配置
cp $SSHD_CONFIG "${SSHD_CONFIG}.bak.$(date +%F_%T)"

# 修改端口为 14535
# 如果存在 Port 配置则替换，否则追加
if grep -q "^Port " $SSHD_CONFIG; then
    sed -i 's/^Port .*/Port 14535/' $SSHD_CONFIG
elif grep -q "^#Port " $SSHD_CONFIG; then
    sed -i 's/^#Port .*/Port 14535/' $SSHD_CONFIG
else
    echo "Port 14535" >> $SSHD_CONFIG
fi

# 启用公钥验证 (通常默认开启，确保被设置)
if grep -q "^PubkeyAuthentication" $SSHD_CONFIG; then
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' $SSHD_CONFIG
else
    echo "PubkeyAuthentication yes" >> $SSHD_CONFIG
fi

# 禁止 Root 密码登录 (PermitRootLogin prohibit-password)
# 这允许 Root 使用密钥登录，但禁止使用密码
if grep -q "^PermitRootLogin" $SSHD_CONFIG; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' $SSHD_CONFIG
else
    echo "PermitRootLogin prohibit-password" >> $SSHD_CONFIG
fi

# 注意：这里没有全局禁用 PasswordAuthentication，
# 因为 kortan 和 universal 用户没有配置密钥，如果全局禁用，他们将无法登录。

# 重启 SSH 服务
echo "[+] 重启 SSH 服务..."
systemctl restart ssh

# ------------------------------------------------------------
# 6. 输出结果
# ------------------------------------------------------------
echo ""
echo "============================================================"
echo "初始化完成！"
echo "============================================================"
echo "SSH 端口已修改为: 14535"
echo "Root 密码登录已禁用 (仅限密钥登录)"
echo ""
echo "--- 用户随机密码 (请妥善保存) ---"
for USER_NAME in "${USERS[@]}"; do
    echo "用户: $USER_NAME  |  密码: ${USER_PASSWORDS[$USER_NAME]}"
done
echo "============================================================"
echo "注意: 请务必在关闭当前会话前，新开窗口测试 SSH 连接！"
echo "测试命令: ssh -p 14535 pub@<服务器IP>"
echo "============================================================"
