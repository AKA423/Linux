#!/bin/bash
#
# 一键修改 SSH 端口 —— 同时支持 Debian / Ubuntu（含 Ubuntu 22.10+ 的 ssh.socket 套接字激活）
# 用法：
#   bash change_ssh_port.sh            # 交互输入端口
#   bash change_ssh_port.sh 22122      # 直接指定端口
#
set -uo pipefail

SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_OVERRIDE="${SOCKET_OVERRIDE_DIR}/override.conf"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info(){ echo -e "[INFO] $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; }

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || { err "请以 root 运行（sudo bash $0）"; exit 1; }
[ -f "$SSH_CONFIG" ] || { err "找不到 $SSH_CONFIG"; exit 1; }

# ---------- 读取端口 ----------
if [ -n "${1:-}" ]; then
    NEW_PORT="$1"
else
    read -p "请输入新的 SSH 端口: " NEW_PORT
fi

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    err "端口无效：$NEW_PORT（应为 1-65535）"; exit 1
fi
[ "$NEW_PORT"-lt 1024 ] && warn "端口 <1024 为特权端口，请确认无冲突"

echo "=== SSH 端口修改工具 (Debian / Ubuntu) ==="
info "新端口: $NEW_PORT"

# ---------- 识别发行版 ----------
DISTRO="unknown"; VER=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO="${ID:-unknown}"; VER="${VERSION_ID:-}"
fi
info "发行版: ${DISTRO} ${VER}"

# ---------- 1. 备份 ----------
cp -a "$SSH_CONFIG" "$BACKUP" && ok "已备份: $BACKUP"

# ---------- 2. 修改 sshd_config ----------
if grep -qiE '^[#[:space:]]*Port[[:space:]]' "$SSH_CONFIG"; then
    sed -i -E "s/^[#[:space:]]*Port[[:space:]].*/Port $NEW_PORT/" "$SSH_CONFIG"
else
    echo "Port $NEW_PORT" >> "$SSH_CONFIG"
fi
ok "sshd_config 已设置 Port $NEW_PORT"

# 子配置（ssh 9.1+ 的 Include）里若有 Port 会覆盖主配置，给出提醒
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSH_CONFIG"; thenif grep -rqiE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config.d/ 2>/dev/null; then
        warn "sshd_config.d/ 子配置里也有 Port，会覆盖主配置，请自行确认"
    fi
fi

# ---------- 3. 语法检查（失败自动回滚） ----------
if command -v sshd >/dev/null 2>&1; then
    if sshd -t >/dev/null 2>/tmp/sshd_t.err; then
        ok "配置语法检查通过"
    else
        err "配置语法错误，已回滚"
        cat /tmp/sshd_t.err
        cp -a "$BACKUP" "$SSH_CONFIG"
        exit 1
    fi
fi

# ---------- 4. 防火墙放行 ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    info "检测到 UFW（已启用），放行 $NEW_PORT/tcp"
    ufw allow "${NEW_PORT}/tcp" && ok "UFW 规则已更新"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "检测到 firewalld（已启用），放行 $NEW_PORT/tcp"
    firewall-cmd--permanent --add-port="${NEW_PORT}/tcp" && firewall-cmd --reload && ok "firewalld 规则已更新"
elif command -v iptables >/dev/null 2>&1; then
    info "使用 iptables 放行 $NEW_PORT/tcp"
    iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT
