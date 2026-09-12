#!/usr/bin/env bash
#
# ssh-port.sh —— 交互式修改 SSH 端口（Debian / Ubuntu）
#
# 用法: sudo ./ssh-port.sh
#
set -euo pipefail

CONF=/etc/ssh/sshd_config
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN=$DROPIN_DIR/99-ssh-port.conf
BACKUP=$CONF.bak.$(date +%Y%m%d-%H%M%S)

# ---------- 基础检查 ----------
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行: sudo $0"; exit 1; }
[ -t 0 ] || { echo "需要终端交互，请勿用 curl | bash，改用: bash <(curl -fsSL <URL>)"; exit 1; }

echo "==================== SSH 端口修改 ===================="
echo "当前 SSH 端口: $(sshd -T 2>/dev/null | awk '/^port /{printf "%s ",$2}')"
echo "====================================================="

# ---------- 输入端口 ----------
while true; do
  read -rp "请输入新端口 (1-65535) [默认 2222]: " PORT
  PORT=${PORT:-2222}
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] && break
  echo "  ! 端口无效，请重新输入"
done

# ---------- 端口占用检查 ----------
if ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "  ! 端口 $PORT 已被占用，退出"; exit 1
fi
echo "  ✓ 端口 $PORT 可用"

# ---------- 是否放行防火墙 ----------
read -rp "是否放行防火墙端口? [Y/n]: " FW
case "${FW:-y}" in
  n|N) OPEN_FW=0 ;;
  *)   OPEN_FW=1 ;;
esac

# ---------- 确认 ----------
echo
echo "将执行:  SSH 端口 -> $PORT $([ "$OPEN_FW" = 1 ] && echo '+ 放行防火墙' || echo '（不动防火墙）')"
read -rp "确认修改? [Y/n]: " GO
case "${GO:-y}" in n|N) echo "已取消"; exit 0 ;; esac

# ---------- 1. 放行防火墙 ----------
if [ "$OPEN_FW" = 1 ]; then
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "$PORT"/tcp >/dev/null && echo "  ✓ ufw 已放行 $PORT/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null && firewall-cmd --reload >/dev/null
    echo "  ✓ firewalld 已放行 $PORT/tcp"
  elif command -v iptables >/dev/null && iptables -S 2>/dev/null | grep -q -- '-A INPUT'; then
    iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null
    echo "  ✓ iptables 已放行 $PORT/tcp"
  else
    echo "  - 未检测到启用的防火墙，跳过"
  fi
fi

# ---------- 2. 备份 ----------
cp -a "$CONF" "$BACKUP"
echo "  ✓ 已备份: $BACKUP"

# ---------- 3. 修改配置 ----------
sed -i -E 's/^([[:space:]]*Port[[:space:]]+.*)$/#\1/' "$CONF"
if [ -d "$DROPIN_DIR" ] && grep -q 'sshd_config.d' "$CONF"; then
  echo "Port $PORT" > "$DROPIN"
  TARGET="$DROPIN"
else
  echo "Port $PORT" >> "$CONF"
  TARGET="$CONF"
fi
echo "  ✓ 已写入: $TARGET"

# ---------- 4. 兼容 ssh.socket (Ubuntu 22.10+) ----------
SOCKET_MODE=0
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  SOCKET_MODE=1
  mkdir -p /etc/systemd/system/ssh.socket.d
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$PORT" > /etc/systemd/system/ssh.socket.d/10-port.conf
  echo "  ✓ 已配置 ssh.socket"
fi

# ---------- 5. 校验 + 重启 ----------
if ! sshd -t; then
  echo "  ✗ 配置校验失败，正在回滚..."
  cp -a "$BACKUP" "$CONF"; rm -f "$DROPIN"
  exit 1
fi
echo "  ✓ 配置校验通过"

systemctl daemon-reload
if [ "$SOCKET_MODE" = 1 ]; then
  systemctl restart ssh.socket && systemctl try-restart ssh.service
else
  systemctl restart ssh
fi

# ---------- 6. 验证 + 返回结果 ----------
sleep 1
echo
if ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "==================== 修改成功 ===================="
  echo "  新端口   : $PORT"
  echo "  生效端口 : $(sshd -T 2>/dev/null | awk '/^port /{printf "%s ",$2}')"
  echo "  备份文件 : $BACKUP"
  echo "================================================="
  echo "  ⚠ 请新开终端测试: ssh -p $PORT <用户>@<主机>"
  echo "    确认能连上再断开当前会话！"
else
  echo "  ✗ 未检测到 $PORT 监听，正在回滚..."
  cp -a "$BACKUP" "$CONF"; rm -f "$DROPIN"
  systemctl daemon-reload
  systemctl restart ssh
  echo "  已回滚到原配置"
  exit 1
fi
