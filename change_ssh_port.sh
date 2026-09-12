#!/usr/bin/env bash
#
# change-ssh-port.sh —— 修改 SSH 端口 + 放行防火墙（Debian / Ubuntu）
#
# 特性:
#   • 自定义端口 (-p)
#   • 自动识别并放行防火墙 (ufw / firewalld / nftables / iptables)
#   • 兼容 sshd_config 主配置 与 sshd_config.d 片段
#   • 兼容 Ubuntu 22.10+ 的 ssh.socket 套接字激活
#   • 改前备份、改后校验 (sshd -t)、失败自动回滚
#   • 输出清晰的执行结果
#
# 用法:
#   sudo ./change-ssh-port.sh -p 2222              # 改成 2222（替换旧端口）
#   sudo ./change-ssh-port.sh -p 2222 --keep-old   # 追加 2222，保留旧端口
#   sudo ./change-ssh-port.sh -p 2222 --no-firewall
#   sudo ./change-ssh-port.sh -p 2222 --dry-run    # 只预览，不改动
#
set -uo pipefail

# ------------------------- 可调参数 -------------------------
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-ssh-port.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN="${SOCKET_DROPIN_DIR}/10-ssh-port.conf"
BACKUP_ROOT="/etc/ssh/.ssh-port-backup"
SSH_SERVICE="ssh.service"
SSH_SOCKET="ssh.socket"

# ------------------------- 变量 -------------------------
NEW_PORT=""
KEEP_OLD=0
DO_FIREWALL=1
DRY_RUN=0
SOCKET_MODE=0
FIREWALL_BACKEND="none"
BACKUP_DIR=""
ROLLBACK_NEEDED=0

# ------------------------- 输出 -------------------------
C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
fi
step() { printf '\n%s==> %s%s\n' "$C_DIM" "$*" "$C_RST"; }
ok()   { printf '%s  ✓ %s%s\n' "$C_OK" "$*" "$C_RST"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_RST"; }
err()  { printf '%s  ✗ %s%s\n' "$C_ERR" "$*" "$C_RST" >&2; }
info() { printf '    %s\n' "$*"; }

usage() {
  # 打印文件头部的注释块（从第 2 行到第一条非注释行之前）
  sed -n '2,/^[^#]/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# 统一执行入口（支持 dry-run）
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] $*"
  else
    "$@"
  fi
}

cleanup_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK_NEEDED" -eq 1 ]; then
    err "脚本异常退出，尝试回滚配置…"
    rollback
  fi
}
trap cleanup_on_exit EXIT

# ------------------------- 参数解析 -------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)      NEW_PORT="${2:-}"; shift 2 ;;
    -p*)            NEW_PORT="${1#-p}"; shift ;;
    --keep-old)     KEEP_OLD=1; shift ;;
    --no-firewall)  DO_FIREWALL=0; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 2 ;;
  esac
done

# ------------------------- 前置检查 -------------------------
if [ "$(id -u)" -ne 0 ]; then
  err "需要 root 权限，请用 sudo 运行。"
  exit 1
fi

if [ -z "$NEW_PORT" ]; then
  err "缺少端口。用法: sudo $0 -p <端口>"
  exit 2
fi

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  err "端口无效: $NEW_PORT （必须是 1-65535 的整数）"
  exit 2
fi

if [ "$NEW_PORT" -lt 1024 ]; then
  warn "端口 $NEW_PORT < 1024，属特权端口（root 运行没问题，但部分安全策略会拦）"
fi

# 发行版检查（Debian / Ubuntu）
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) warn "检测到发行版 '${ID:-unknown}'，本脚本仅针对 Debian/Ubuntu 做过适配，继续但请谨慎。" ;;
  esac
  info "系统: ${PRETTY_NAME:-unknown}"
fi

if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  err "未找到 sshd，请先安装 openssh-server。"
  exit 1
fi
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"

# ------------------------- 工具函数 -------------------------
# 监听检查：输出占用该端口的进程（为空表示未占用）
who_listens() {
  ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $NF" "$4}' | tr '\n' ' '
}

# 当前 sshd 生效的端口
current_ports() {
  "$SSHD_BIN" -T 2>/dev/null | awk '/^port /{printf "%s ",$2}'
}

# 检测是否使用 ssh.socket 套接字激活
detect_socket_mode() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SSH_SOCKET}"; then
    if systemctl is-active --quiet "$SSH_SOCKET" 2>/dev/null; then
      SOCKET_MODE=1
    fi
  fi
}

# 备份 ssh 相关配置
do_backup() {
  mkdir -p "$BACKUP_DIR"
  [ -f "$SSHD_MAIN" ] && cp -a "$SSHD_MAIN" "$BACKUP_DIR/" 2>/dev/null
  if [ -d "$SSHD_DROPIN_DIR" ]; then
    mkdir -p "$BACKUP_DIR/sshd_config.d"
    cp -a "$SSHD_DROPIN_DIR/." "$BACKUP_DIR/sshd_config.d/" 2>/dev/null
  fi
  [ -f "$SOCKET_DROPIN" ] && { mkdir -p "$BACKUP_DIR/socket.d"; cp -a "$SOCKET_DROPIN" "$BACKUP_DIR/socket.d/"; }
  info "备份目录: $BACKUP_DIR"
}

# 回滚
rollback() {
  [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || { err "无备份可回滚"; return 1; }
  [ -f "$BACKUP_DIR/sshd_config" ] && cp -a "$BACKUP_DIR/sshd_config" "$SSHD_MAIN"
  if [ -d "$BACKUP_DIR/sshd_config.d" ]; then
    rm -f "$SSHD_DROPIN_DIR"/*.conf 2>/dev/null
    cp -a "$BACKUP_DIR/sshd_config.d/." "$SSHD_DROPIN_DIR/" 2>/dev/null
  fi
  systemctl daemon-reload 2>/dev/null
  if [ "$SOCKET_MODE" -eq 1 ]; then
    systemctl restart "$SSH_SOCKET" 2>/dev/null
    systemctl try-restart "$SSH_SERVICE" 2>/dev/null
  else
    systemctl restart "$SSH_SERVICE" 2>/dev/null
  fi
  ok "已回滚到修改前配置。"
}

# 注释掉某文件里生效的 Port 行
comment_port_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -qE '^[[:space:]]*Port[[:space:]]+' "$f"; then
    run sed -i -E 's@^([[:space:]]*Port[[:space:]]+.*)$@#&  # disabled by change-ssh-port.sh@' "$f"
    info "已注释旧端口行: $f"
  fi
}

# ------------------------- 1. 防火墙放行（先放行，再改配置） -------------------------
open_firewall() {
  step "1/6 放行防火墙端口 $NEW_PORT/tcp"
  if [ "$DO_FIREWALL" -eq 0 ]; then
    info "已指定 --no-firewall，跳过。"
    return 0
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    FIREWALL_BACKEND="ufw"
    run ufw allow "${NEW_PORT}/tcp"
    ok "ufw: 已允许 ${NEW_PORT}/tcp"

  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FIREWALL_BACKEND="firewalld"
    run firewall-cmd --permanent --add-port="${NEW_PORT}/tcp"
    run firewall-cmd --reload
    ok "firewalld: 已允许 ${NEW_PORT}/tcp"

  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    FIREWALL_BACKEND="nftables"
    warn "检测到 nftables 正在使用：为避免破坏你的现有规则链，脚本不自动改写。"
    info "请手动放行，例如："
    info "  nft add rule inet filter input tcp dport ${NEW_PORT} accept"

  elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q -- '-A INPUT'; then
    FIREWALL_BACKEND="iptables"
    if iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null; then
      info "iptables: 规则已存在"
    else
      run iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT
      ok "iptables: 已插入放行规则"
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
      run netfilter-persistent save && ok "iptables: 规则已持久化"
    else
      warn "未找到 netfilter-persistent，iptables 规则重启后会丢失，请自行持久化。"
    fi

  else
    FIREWALL_BACKEND="none"
    info "未检测到启用的防火墙（ufw / firewalld / nftables / iptables），无需放行。"
  fi
}

# ------------------------- 2. 端口冲突检查 -------------------------
check_conflict() {
  step "2/6 检查端口占用"
  local cur
  cur="$(current_ports)"
  if printf ' %s ' "$cur" | grep -q " ${NEW_PORT} "; then
    ok "该端口已是 SSH 当前端口，无需重复修改。"
    return 10
  fi
  local who
  who="$(who_listens "$NEW_PORT")"
  if [ -n "$who" ]; then
    err "端口 $NEW_PORT 已被占用: $who"
    return 1
  fi
  ok "端口 $NEW_PORT 空闲。"
  return 0
}

# ------------------------- 3. 写入端口配置 -------------------------
apply_config() {
  step "3/6 写入 SSH 端口配置"
  detect_socket_mode
  if [ "$SOCKET_MODE" -eq 1 ]; then
    info "检测到 ssh.socket 套接字激活（Ubuntu 22.10+ / 新版 systemd），将同时配置 socket。"
  fi

  if [ "$KEEP_OLD" -eq 0 ]; then
    # 替换模式：注释掉所有生效的 Port 行
    comment_port_lines "$SSHD_MAIN"
    if [ -d "$SSHD_DROPIN_DIR" ]; then
      local f
      for f in "$SSHD_DROPIN_DIR"/*.conf; do
        [ -e "$f" ] || continue
        [ "$f" = "$SSHD_DROPIN" ] && continue
        comment_port_lines "$f"
      done
    fi
  else
    info "保留旧端口（--keep-old），仅追加新端口。"
  fi

  # 选择落点：优先 drop-in（更干净），否则改主配置
  if [ -d "$SSHD_DROPIN_DIR" ] && grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_MAIN"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 写入 $SSHD_DROPIN （Port $NEW_PORT）"
    else
      printf '# managed by change-ssh-port.sh (%s)\nPort %s\n' "$(date -Is)" "$NEW_PORT" > "$SSHD_DROPIN"
      chmod 600 "$SSHD_DROPIN"
    fi
    ok "已写入片段: $SSHD_DROPIN"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 追加 'Port $NEW_PORT' 到 $SSHD_MAIN"
    else
      printf '\n# managed by change-ssh-port.sh (%s)\nPort %s\n' "$(date -Is)" "$NEW_PORT" >> "$SSHD_MAIN"
    fi
    ok "已追加到主配置: $SSHD_MAIN"
  fi

  # ssh.socket 模式：覆盖 ListenStream
  if [ "$SOCKET_MODE" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] 写入 $SOCKET_DROPIN （ListenStream=$NEW_PORT）"
    else
      mkdir -p "$SOCKET_DROPIN_DIR"
      printf '# managed by change-ssh-port.sh (%s)\n[Socket]\nListenStream=\nListenStream=%s\n' \
        "$(date -Is)" "$NEW_PORT" > "$SOCKET_DROPIN"
      ok "已写入 socket 片段: $SOCKET_DROPIN"
    fi
  fi
}

# ------------------------- 4. 语法校验 -------------------------
validate_config() {
  step "4/6 校验配置 (sshd -t)"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] 跳过校验"; return 0; fi
  if "$SSHD_BIN" -t 2>/tmp/sshd_t.err; then
    ok "配置语法通过。"
  else
    err "配置校验失败："
    cat /tmp/sshd_t.err >&2
    return 1
  fi
}

# ------------------------- 5. 重启服务 -------------------------
restart_ssh() {
  step "5/6 重启 SSH 服务"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] 跳过重启"; return 0; fi
  if [ "$SOCKET_MODE" -eq 1 ]; then
    systemctl daemon-reload
    run systemctl restart "$SSH_SOCKET"
    run systemctl try-restart "$SSH_SERVICE"
  else
    run systemctl restart "$SSH_SERVICE"
  fi
  if systemctl is-active --quiet "$SSH_SERVICE" || systemctl is-active --quiet "$SSH_SOCKET"; then
    ok "SSH 服务已重启。"
  else
    err "SSH 服务未处于 active 状态！"
    return 1
  fi
}

# ------------------------- 6. 验证监听 -------------------------
verify() {
  step "6/6 验证监听端口"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] 跳过验证"; return 0; fi
  local i who
  for i in 1 2 3 4 5; do
    who="$(who_listens "$NEW_PORT")"
    [ -n "$who" ] && break
    sleep 1
  done
  if [ -n "$who" ]; then
    ok "已在 $NEW_PORT 监听: $who"
    ROLLBACK_NEEDED=0
    return 0
  fi
  err "未在 $NEW_PORT 上检测到监听。"
  return 1
}

# ------------------------- 主流程 -------------------------
main() {
  step "0/6 目标: 将 SSH 端口改为 $NEW_PORT （$([ "$KEEP_OLD" -eq 1 ] && echo '保留旧端口' || echo '替换旧端口')）"
  local old_ports; old_ports="$(current_ports)"
  info "修改前生效端口: ${old_ports:-未知}"

  do_backup
  ROLLBACK_NEEDED=1

  open_firewall

  check_conflict; local cc=$?
  if [ "$cc" -eq 10 ]; then
    ROLLBACK_NEEDED=0
    step "结果: 无需修改"
    exit 0
  elif [ "$cc" -ne 0 ]; then
    err "端口冲突，已中止（未做任何修改）。"
    ROLLBACK_NEEDED=0
    exit 1
  fi

  apply_config || { err "写入配置失败"; rollback; exit 1; }
  if ! validate_config; then rollback; exit 1; fi
  if ! restart_ssh; then rollback; exit 1; fi
  if ! verify; then
    err "验证失败，自动回滚…"
    rollback
    exit 1
  fi

  ROLLBACK_NEEDED=0
  step "完成 ✅"
  printf '  新 SSH 端口 : %s\n' "$NEW_PORT"
  printf '  防火墙后端 : %s\n' "$FIREWALL_BACKEND"
  printf '  备份目录   : %s\n' "$BACKUP_DIR"
  printf '  当前生效   : %s\n' "$(current_ports)"
  warn "重要：先别断开当前会话，用新开一个终端测试：ssh -p ${NEW_PORT} <用户>@<主机>"
  if [ "$KEEP_OLD" -eq 0 ]; then
    info "确认能连上后，可关闭旧端口并删除防火墙旧规则（脚本未动旧端口，以防锁死）。"
  fi
}

main "$@"
