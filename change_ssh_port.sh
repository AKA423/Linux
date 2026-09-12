#!/usr/bin/env bash
#
# ssh-port-tui.sh —— 交互式 SSH 端口修改助手（Debian / Ubuntu）
#
# 交互界面：
#   1) 设置 SSH 端口（含防火墙放行、改前备份、失败自动回滚）
#   2) 查看当前状态
#   3) 回滚到某个备份
#   4) 退出
#
# 无外部依赖（不依赖 whiptail/dialog），纯 bash 彩色界面。
#
# 运行方式（交互必须有终端，不要用管道）：
#   chmod +x ssh-port-tui.sh && sudo ./ssh-port-tui.sh
#   或直接:  bash <(curl -fsSL <URL>)
#
set -uo pipefail

# ============================ 常量 ============================
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-ssh-port.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN="${SOCKET_DROPIN_DIR}/10-ssh-port.conf"
BACKUP_ROOT="/etc/ssh/.ssh-port-backup"
SSH_SERVICE="ssh.service"
SSH_SOCKET="ssh.socket"
DEFAULT_PORT="2222"

# ============================ 配色 ============================
if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; MAG=$'\033[35m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

# ============================ 输出 ============================
hr()   { printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────" "$R"; }
title(){ printf '\n%s%s%s\n' "$B$CYN" "$*" "$R"; }
ok()   { printf '%s  ✓ %s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '%s  ! %s%s\n' "$YEL" "$*" "$R"; }
err()  { printf '%s  ✗ %s%s\n' "$RED" "$*" "$R" >&2; }
info() { printf '    %s\n' "$*"; }

pause() { printf '\n%s按回车返回菜单...%s' "$DIM" "$R"; read -r _ || true; }

banner() {
  clear 2>/dev/null || true
  printf '%s' "$MAG"
  cat <<'BANNER'
  ╔══════════════════════════════════════════════════════════╗
  ║           SSH 端口修改助手   (Debian / Ubuntu)           ║
  ╚══════════════════════════════════════════════════════════╝
BANNER
  printf '%s' "$R"
}

# ============================ 输入助手 ============================
ask_yn() { # ask_yn "提示" <默认 y|n>
  local prompt="$1" def="${2:-y}" ans hint
  if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
  while true; do
    printf '  %s [%s] ' "$prompt" "$hint"
    read -r ans || return 1
    ans="${ans:-$def}"
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

ask_port() { # 结果写入 NEW_PORT
  local p
  while true; do
    printf '  请输入新的 SSH 端口 (1-65535) [回车用默认 %s]: ' "$DEFAULT_PORT"
    read -r p || return 1
    p="${p:-$DEFAULT_PORT}"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
      NEW_PORT="$p"; return 0
    fi
    warn "端口无效：$p（必须是 1-65535 的整数）"
  done
}

# ============================ 状态探测 ============================
who_listens() { ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $NF" "$4}' | tr '\n' ' '; }

current_ports() { "$SSHD_BIN" -T 2>/dev/null | awk '/^port /{printf "%s ",$2}'; }

detect_socket_mode() {
  SOCKET_MODE=0
  if systemctl list-unit-files 2>/dev/null | grep -q "^${SSH_SOCKET}"; then
    systemctl is-active --quiet "$SSH_SOCKET" 2>/dev/null && SOCKET_MODE=1
  fi
}

detect_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    echo "ufw (active)"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld (active)"
  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    echo "nftables (使用中，脚本不会自动改写)"
  elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q -- '-A INPUT'; then
    echo "iptables (有规则)"
  else
    echo "未检测到（无放行需求）"
  fi
}

show_status() {
  title "📊  当前状态"
  local os="unknown"
  [ -r /etc/os-release ] && os="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
  local svc="inactive"
  systemctl is-active --quiet "$SSH_SERVICE" && svc="active"
  systemctl is-active --quiet "$SSH_SOCKET"  && svc="$svc / socket: active"
  detect_socket_mode
  hr
  printf '  %-14s %s\n' "系统"        "$os"
  printf '  %-14s %s\n' "SSH 服务"    "$svc"
  printf '  %-14s %s\n' "socket 激活" "$([ "$SOCKET_MODE" -eq 1 ] && echo '是（需同时改 socket）' || echo '否')"
  printf '  %-14s %s\n' "当前端口"    "$(current_ports)"
  printf '  %-14s %s\n' "监听情况"    "$(ss -tlnH 'sport = :ssh' 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
  printf '  %-14s %s\n' "防火墙"      "$(detect_firewall)"
  printf '  %-14s %s\n' "备份数量"    "$(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l)"
  hr
}

# ============================ 备份 / 回滚 ============================
do_backup() {
  BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [ -f "$SSHD_MAIN" ] && cp -a "$SSHD_MAIN" "$BACKUP_DIR/" 2>/dev/null
  if [ -d "$SSHD_DROPIN_DIR" ]; then
    mkdir -p "$BACKUP_DIR/sshd_config.d"
    cp -a "$SSHD_DROPIN_DIR/." "$BACKUP_DIR/sshd_config.d/" 2>/dev/null
  fi
  [ -f "$SOCKET_DROPIN" ] && { mkdir -p "$BACKUP_DIR/socket.d"; cp -a "$SOCKET_DROPIN" "$BACKUP_DIR/socket.d/"; }
}

restore_from() { # restore_from <备份目录>
  local src="$1"
  [ -d "$src" ] || { err "备份不存在: $src"; return 1; }
  [ -f "$src/sshd_config" ] && cp -a "$src/sshd_config" "$SSHD_MAIN"
  if [ -d "$src/sshd_config.d" ] && [ -d "$SSHD_DROPIN_DIR" ]; then
    find "$SSHD_DROPIN_DIR" -maxdepth 1 -name '*.conf' -delete 2>/dev/null
    cp -a "$src/sshd_config.d/." "$SSHD_DROPIN_DIR/" 2>/dev/null
  fi
  systemctl daemon-reload 2>/dev/null
  detect_socket_mode
  if [ "$SOCKET_MODE" -eq 1 ]; then
    systemctl restart "$SSH_SOCKET" 2>/dev/null
    systemctl try-restart "$SSH_SERVICE" 2>/dev/null
  else
    systemctl restart "$SSH_SERVICE" 2>/dev/null
  fi
}

rollback_current() { # 用本轮备份回滚
  [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ] || { err "无本轮备份可回滚"; return 1; }
  restore_from "$BACKUP_DIR" && ok "已回滚到修改前配置。"
}

# ============================ 核心步骤 ============================
comment_port_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  if grep -qE '^[[:space:]]*Port[[:space:]]+' "$f"; then
    sed -i -E 's@^([[:space:]]*Port[[:space:]]+.*)$@#&  # disabled by ssh-port-tui.sh@' "$f"
    info "已注释旧端口行: $f"
  fi
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1 && ok "ufw: 已允许 ${NEW_PORT}/tcp" || err "ufw 放行失败"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${NEW_PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld: 已允许 ${NEW_PORT}/tcp"
  elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    warn "nftables 使用中，脚本不自动改写。请手动放行:"
    info "nft add rule inet filter input tcp dport ${NEW_PORT} accept"
  elif command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null | grep -q -- '-A INPUT'; then
    if iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null; then
      info "iptables: 规则已存在"
    else
      iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT && ok "iptables: 已插入放行规则"
      command -v netfilter-persistent >/dev/null 2>&1 && { netfilter-persistent save >/dev/null 2>&1; ok "iptables: 已持久化"; } \
        || warn "无 netfilter-persistent，规则重启后可能丢失"
    fi
  else
    info "未检测到启用的防火墙，无需放行。"
  fi
}

apply_config() {
  detect_socket_mode
  if [ "$KEEP_OLD" -eq 0 ]; then
    comment_port_lines "$SSHD_MAIN"
    if [ -d "$SSHD_DROPIN_DIR" ]; then
      local f
      for f in "$SSHD_DROPIN_DIR"/*.conf; do
        [ -e "$f" ] || continue
        [ "$f" = "$SSHD_DROPIN" ] && continue
        comment_port_lines "$f"
      done
    fi
  fi

  if [ -d "$SSHD_DROPIN_DIR" ] && grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_MAIN"; then
    printf '# managed by ssh-port-tui.sh (%s)\nPort %s\n' "$(date -Is)" "$NEW_PORT" > "$SSHD_DROPIN"
    chmod 600 "$SSHD_DROPIN"
    ok "已写入: $SSHD_DROPIN"
  else
    printf '\n# managed by ssh-port-tui.sh (%s)\nPort %s\n' "$(date -Is)" "$NEW_PORT" >> "$SSHD_MAIN"
    ok "已追加到: $SSHD_MAIN"
  fi

  if [ "$SOCKET_MODE" -eq 1 ]; then
    mkdir -p "$SOCKET_DROPIN_DIR"
    printf '# managed by ssh-port-tui.sh (%s)\n[Socket]\nListenStream=\nListenStream=%s\n' \
      "$(date -Is)" "$NEW_PORT" > "$SOCKET_DROPIN"
    ok "已写入: $SOCKET_DROPIN"
  fi
}

validate_config() {
  if "$SSHD_BIN" -t 2>/tmp/sshd_t.err; then ok "配置语法通过"; else
    err "配置校验失败:"; cat /tmp/sshd_t.err >&2; return 1
  fi
}

restart_ssh() {
  detect_socket_mode
  if [ "$SOCKET_MODE" -eq 1 ]; then
    systemctl daemon-reload
    systemctl restart "$SSH_SOCKET" && systemctl try-restart "$SSH_SERVICE"
  else
    systemctl restart "$SSH_SERVICE"
  fi
  if systemctl is-active --quiet "$SSH_SERVICE" || systemctl is-active --quiet "$SSH_SOCKET"; then
    ok "SSH 服务已重启"; return 0
  fi
  err "SSH 服务未处于 active 状态"; return 1
}

verify() {
  local i who
  for i in 1 2 3 4 5; do
    who="$(who_listens "$NEW_PORT")"; [ -n "$who" ] && break; sleep 1
  done
  if [ -n "$who" ]; then ok "已在 $NEW_PORT 监听: $who"; return 0; fi
  err "未在 $NEW_PORT 检测到监听"; return 1
}

# ============================ 主流程：设置端口 ============================
flow_set_port() {
  title "🔧  设置 SSH 端口"
  show_status

  detect_socket_mode
  local cur; cur="$(current_ports)"

  echo
  ask_port || return 1

  # 端口是否已是当前端口
  if printf ' %s ' "$cur" | grep -q " ${NEW_PORT} "; then
    warn "端口 $NEW_PORT 已经是 SSH 当前端口，无需修改。"
    return 0
  fi

  # 冲突检查
  local who; who="$(who_listens "$NEW_PORT")"
  if [ -n "$who" ]; then
    err "端口 $NEW_PORT 已被占用: $who"
    return 1
  fi
  ok "端口 $NEW_PORT 可用"

  # 选项收集
  echo
  if ask_yn "是否保留旧端口（更安全，可新旧并存）?" n; then KEEP_OLD=1; else KEEP_OLD=0; fi
  if ask_yn "是否自动放行防火墙?" y; then DO_FIREWALL=1; else DO_FIREWALL=0; fi
  if ask_yn "是否先做一次预演（不改动）?" y; then DRY_RUN=1; else DRY_RUN=0; fi

  # 摘要 + 确认
  echo
  hr
  printf '  目标端口   : %s%s%s\n' "$B" "$NEW_PORT" "$R"
  printf '  旧端口     : %s\n' "$([ "$KEEP_OLD" -eq 1 ] && echo '保留' || echo '替换（注释掉旧 Port）')"
  printf '  防火墙     : %s\n' "$([ "$DO_FIREWALL" -eq 1 ] && echo '自动放行' || echo '跳过')"
  printf '  模式       : %s\n' "$([ "$DRY_RUN" -eq 1 ] && echo '预演（不修改）' || echo '正式执行')"
  printf '  socket激活 : %s\n' "$([ "$SOCKET_MODE" -eq 1 ] && echo '是（会一并修改）' || echo '否')"
  hr
  if ! ask_yn "确认执行?" y; then info "已取消。"; return 0; fi

  if [ "$DRY_RUN" -eq 1 ]; then
    title "🧪  预演模式：不改动任何配置"
    info "将要执行："
    info "  1) 备份 ssh 配置"
    info "  2) $([ "$DO_FIREWALL" -eq 1 ] && echo "放行防火墙 ${NEW_PORT}/tcp" || echo '跳过防火墙')"
    info "  3) $([ "$KEEP_OLD" -eq 1 ] && echo "追加 Port ${NEW_PORT}" || echo "替换为 Port ${NEW_PORT}")"
    info "  4) sshd -t 校验 + 重启 SSH + 验证监听"
    info "去掉预演即可正式执行。"
    return 0
  fi

  # ---- 正式执行 ----
  title "🚀  执行中"
  do_backup; info "备份: $BACKUP_DIR"

  [ "$DO_FIREWALL" -eq 1 ] && open_firewall
  apply_config     || { err "写入配置失败"; rollback_current; return 1; }
  validate_config  || { rollback_current; return 1; }
  restart_ssh      || { rollback_current; return 1; }
  verify           || { err "验证失败，自动回滚"; rollback_current; return 1; }

  title "✅  完成"
  printf '  %-12s %s\n' "新端口"   "$NEW_PORT"
  printf '  %-12s %s\n' "当前生效" "$(current_ports)"
  printf '  %-12s %s\n' "备份目录" "$BACKUP_DIR"
  echo
  warn "先别断开当前会话！请新开一个终端测试："
  printf '    %sssh -p %s <用户>@<主机>%s\n' "$B" "$NEW_PORT" "$R"
  [ "$KEEP_OLD" -eq 0 ] && info "确认能连上后，再考虑关闭旧端口和删除旧防火墙规则。"
}

# ============================ 主流程：回滚 ============================
flow_rollback() {
  title "↩️   从备份回滚"
  if [ ! -d "$BACKUP_ROOT" ] || [ -z "$(ls -1 "$BACKUP_ROOT" 2>/dev/null)" ]; then
    warn "没有可用备份。"; return 0
  fi
  local backups=() i
  while IFS= read -r b; do backups+=("$b"); done < <(ls -1 "$BACKUP_ROOT" | sort -r)
  for i in "${!backups[@]}"; do
    local when; when="$(stat -c '%y' "$BACKUP_ROOT/${backups[$i]}" 2>/dev/null | cut -d. -f1)"
    printf '  %2d) %s   %s\n' "$((i+1))" "${backups[$i]}" "$when"
  done
  echo
  printf '  请选择要回滚到的备份序号 (回车取消): '
  local sel; read -r sel || return 0
  [ -z "$sel" ] && { info "已取消。"; return 0; }
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#backups[@]}" ]; then
    err "无效序号"; return 1
  fi
  local chosen="$BACKUP_ROOT/${backups[$((sel-1))]}"
  ask_yn "确认用 $chosen 覆盖当前 SSH 配置?" n || return 0
  restore_from "$chosen" && ok "回滚完成，当前端口: $(current_ports)"
}

# ============================ 菜单 ============================
menu() {
  banner
  show_status
  printf '\n%s  请选择操作：%s\n' "$B" "$R"
  printf '    %s1)%s 设置 SSH 端口（放行防火墙 / 自动备份 / 失败回滚）\n' "$CYN" "$R"
  printf '    %s2)%s 查看当前状态\n' "$CYN" "$R"
  printf '    %s3)%s 从备份回滚\n' "$CYN" "$R"
  printf '    %s4)%s 退出\n' "$CYN" "$R"
  printf '\n  > '
}

main() {
  # 环境检查
  if [ "$(id -u)" -ne 0 ]; then
    err "需要 root 权限：sudo $0"
    exit 1
  fi
  if [ ! -t 0 ]; then
    err "交互模式需要终端输入。请勿用 'curl | bash' 运行。"
    info "请改用：bash <(curl -fsSL <URL>)   或先下载再执行。"
    exit 1
  fi
  if [ ! -r /etc/os-release ]; then err "无法识别系统"; exit 1; fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) warn "检测到 '${ID:-unknown}'，脚本仅适配 Debian/Ubuntu，继续请谨慎。" ;;
  esac
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    err "未找到 sshd，请先安装 openssh-server。"; exit 1
  fi
  SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

  while true; do
    menu
    local choice; read -r choice || exit 0
    case "$choice" in
      1) flow_set_port; pause ;;
      2) : ;;
      3) flow_rollback; pause ;;
      4|q|Q) echo "再见 👋"; exit 0 ;;
      *) warn "无效选择，请输入 1-4"; sleep 1 ;;
    esac
  done
}

main "$@"
