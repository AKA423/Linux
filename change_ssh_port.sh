#!/bin/bash
#
# Debian 一键修改 SSH 端口（支持自定义）
# 用法：
#   bash change_ssh_port.sh
#   或运行后输入端口
#

SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

# 读取端口（优先命令行参数）
if [ -n "$1" ]; then
    NEW_PORT="$1"
else
    read -p "请输入新的 SSH 端口: " NEW_PORT
fi

# 校验端口
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "[ERROR] 端口无效：$NEW_PORT"
    exit 1
fi

echo "=== Debian SSH 端口修改工具 ==="
echo "[INFO] 新端口: $NEW_PORT"

# 1. 备份配置
cp $SSH_CONFIG $BACKUP
echo "[OK] 已备份配置到: $BACKUP"

# 2. 修改 sshd_config
if grep -q "^#Port " $SSH_CONFIG || grep -q "^Port " $SSH_CONFIG; then
    sed -i "s/^#Port .*/Port $NEW_PORT/" $SSH_CONFIG
    sed -i "s/^Port .*/Port $NEW_PORT/" $SSH_CONFIG
else
    echo "Port $NEW_PORT" >> $SSH_CONFIG
fi
echo "[OK] SSH 配置文件已更新"

# 3. 放行防火墙
if command -v ufw >/dev/null 2>&1; then
    echo "[INFO] 检测到 UFW，放行端口..."
    ufw allow ${NEW_PORT}/tcp
elif command -v iptables >/dev/null 2>&1; then
    echo "[INFO] 使用 iptables 放行端口..."
    iptables -A INPUT -p tcp --dport ${NEW_PORT} -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
fi
echo "[OK] 防火墙规则已更新"

# 4. 重启 SSH 服务
echo "[INFO] 正在重启 SSH 服务..."
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# 5. 检查端口是否监听
sleep 1
if ss -tlnp | grep -q ":$NEW_PORT"; then
    echo "[SUCCESS] SSH 已成功监听端口 $NEW_PORT"
    echo "请测试新端口："
    echo "ssh root@服务器IP -p $NEW_PORT"
else
    echo "[ERROR] SSH 未成功监听新端口，已保留当前会话。"
    echo "你可以恢复备份："
    echo "cp $BACKUP $SSH_CONFIG && systemctl restart ssh"
fi

echo "=== 完成 ==="
