#!/usr/bin/env bash
#
# ssh-port-manager.sh —— 交互式 SSH 端口管理
#   目标平台: Debian 13 (trixie) / Ubuntu 26.04 (及相近版本)
#
# 功能:
#   • 交互界面，自定义修改 SSH 端口
#   • 自动识别并放行防火墙 (ufw / firewalld / nftables / iptables)
#   • 关键: 同时适配 systemd 套接字激活 (ssh.socket) —— 新系统默认就是它
#   • 改前备份、sshd -t 校验、失败自动回滚
#
# 用法: sudo ./ssh-port-manager.sh
#
set -uo pipefail

# ======================== 常量 ========================
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="$SSHD_DROPIN_DIR/99-ssh-port.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN="$SOCKET_DROPIN_DIR/10-ssh-port.conf"
BACKUP_ROOT="/etc/ssh/.ssh-port-backup"
SSH_SERVICE="ssh.service"
SSH_SOCKET="ssh.socket"

# ======================== 配色 ========================
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; MAG=$'\033[35m'
else
  B=""; D=""; R=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""
fi

ok()   { printf '%s  ✓ %s%s\n' "$GRN" "$*" "$R"; }
warn() { printf '%s  ! %s%s\n' "$YEL" "$*" "$R"; }
err()  { printf '%s  ✗ %s%s\n' "$RED" "$*" "$R" >&2; }
info() { printf '    %s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$CYN" "$*" "$R"; }
line() { printf '%s%s%s\n' "$D" "────────────────────────────────────────────────────────" "$R"; }
pause(){ printf '\n%s按回车返回菜单...%s' "$D" "$R"; read -r _ || true; }

# ======================== 交互助手 ========================
ask_yn() { # ask_yn "提示" [y|n]
  local p="$1" def="${2:-y}" a hint
  [ "$def" = y ] && hint="Y/n" || hint="y/N"
  while true; do
    printf '  %s [%s] ' "$p" "$hint"
    read -r a || return 1
    a="${a:-$def}"
    case "$a" in y|Y|yes|YES) return 0;; n|N|no|NO) return 1;; *) warn "请输入 y 或 n";; esac
  done
}

ask_port() {
  local p
  while true; do
    printf '  请输入新端口 (1-65535) [默认 2222]: '
    read -r p || return 1
    p="${p:-2222}"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
      NEW_PORT="$p"; return 0
    fi
    warn "无效端口: $p"
  done
}

# ======================== 环境探测 ========================
detect_os() {
  OS_NAME="unknown"; OS_ID="unknown"; OS_VER=""
  if [ -r /etc/os-release ]; then
    OS_ID="$(. /etc/os-release; echo "${ID:-unknown}")"
    OS_VER="$(. /etc/os-release; echo "${VERSION_ID:-}")"
    OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
  fi
  case "$OS_ID" in
    debian) [ "$OS_VER" = "13" ] || warn "Debian $OS_VER（脚本按 13/trixie 适配，其他版本请谨慎）" ;;
    ubuntu) [ "$OS_VER" = "26.04" ] || warn "Ubuntu $OS_VER（脚本按 26.04 适配，其他版本请谨慎）" ;;
    *) warn "未识别的发行版 '$OS_ID'，仅适配 Debian 13 / Ubuntu 26.04" ;;
  esac
}

count_ports() { "$SSHD_BIN" -T 2>/dev/null | awk '/^port /{printf "%s ",$2}'; }

who_on_port() { ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $NF" "$4}' | tr '\n' ' '; }

# 关键: 判断是否 socket 激活
detect_ssh_mode() {
  SSH_MODE="service"
  if systemctl list-unit-files "$SSH_SOCKET" 2>/dev/null | grep -q "^${SSH_SOCKET}"; then
    if systemctl is-active --quiet "$SSH_SOCKET" 2>/dev/null \
       || systemctl is-enabled --quiet "$SSH_SOCKET" 2>/dev/null; then
      SSH_MODE="socket"
    fi
  fi
}

detect_firewall() {
  FW_BACKEND="none"; FW_DESC="未检测到启用的防火墙"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    FW_BACKEND="ufw"; FW_DESC="ufw (已启用)"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FW_BACKEND="firewalld"; FW_DESC="firewalld (已启用)"
  else
    local c; c="$(nft_input_chain)"
    if [ -n "$c" ]; then
      FW_BACKEND="nftables"; FW_DESC="nftables [$c]"
    elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q '^-A '; then
      FW_BACKEND="iptables"; FW_DESC="iptables (存在规则)"
    fi
  fi
}

nft_input_chain() {
  command -v nft >/dev/null 2>&1 || return 0
  nft list ruleset 2>/dev/null | awk '
    /^table /   { fam=$2; tbl=$3 }
    /chain /    { c=$2; gsub(/[{}]/,"",c); cur=c }
    /hook input/{ print fam" "tbl" "cur; exit }
  '
}

# ======================== 备份 / 回滚 ========================
do_backup() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [ -f "$SSHD_MAIN" ] && cp -a "$SSHD_MAIN" "$BACKUP_DIR/"
  if [ -d "$SSHD_DROPIN_DIR" ]; then
    mkdir -p "$BACKUP_DIR/sshd_config.d"
    cp -a "$SSHD_DROPIN_DIR/." "$BACKUP_DIR/sshd_config.d/" 2>/dev/null
  fi
  [ -f "$SOCKET_DROPIN" ] && { mkdir -p "$BACKUP_DIR/socket.d"; cp -a "$SOCKET_DROPIN" "$BACKUP_DIR/socket.d/"; }
  [ -f "$SSHD_DROPIN" ] && cp -a "$SSHD_DROPIN" "$BACKUP_DIR/" 2>/dev/null
  info "备份目录: $BACKUP_DIR"
}

restore_from() {
  local src="$1"
  [ -d "$src" ] || { err "备份不存在: $src"; return 1; }
  [ -f "$src/sshd_config" ] && cp -a "$src/sshd_config" "$SSHD_MAIN"
  if [ -d "$src/sshd_config.d" ] && [ -d "$SSHD_DROPIN_DIR" ]; then
    find "$SSHD_DROPIN_DIR" -maxdepth 1 -name '*.conf' -delete 2>/dev/null
    cp -a "$src/sshd_config.d/." "$SSHD_DROPIN_DIR/" 2>/dev/null
  fi
  rm -f "$SSHD_DROPIN" "$SOCKET_DROPIN"
  [ -f "$src/socket.d/10-ssh-port.conf" ] && { mkdir -p "$SOCKET_DROPIN_DIR"; cp -a "$src/socket.d/10-ssh-port.conf" "$SOCKET_DROPIN"; }
  systemctl daemon-reload 2>/dev/null
  detect_ssh_mode
  if [ "$SSH_MODE" = socket ]; then
    systemctl restart "$SSH_SOCKET" 2>/dev/null
    systemctl try-restart "$SSH_SERVICE" 2>/dev/null
  else
    systemctl restart "$SSH_SERVICE" 2>/dev/null
  fi
}

rollback_current() {
  [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ] || { err "无本轮备份"; return 1; }
  restore_from "$BACKUP_DIR" && ok "已回滚到修改前配置"
}

# ======================== 防火墙放行 ========================
open_firewall() {
  case "$FW_BACKEND" in
    ufw)
      ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1 && ok "ufw: 已放行 ${NEW_PORT}/tcp" || err "ufw 放行失败"
      ;;
    firewalld)
      firewall-cmd --permanent --add-port="${NEW_PORT}/tcp" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      ok "firewalld: 已放行 ${NEW_PORT}/tcp"
      ;;
    nftables)
      local c; c="$(nft_input_chain)"
      if [ -n "$c" ]; then
        # shellcheck disable=SC2086
        nft add rule $c tcp dport "$NEW_PORT" accept && ok "nftables: 已放行 ${NEW_PORT}/tcp"
        # 持久化
        if [ -f /etc/nftables.conf ] && systemctl is-enabled --quiet nftables 2>/dev/null; then
          if ask_yn "写入 /etc/nftables.conf 以便重启后仍生效?" y; then
            cp -a /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%Y%m%d-%H%M%S)"
            nft list ruleset > /etc/nftables.conf && ok "nftables: 已持久化（原文件已备份）"
          fi
        else
          warn "nftables 规则仅当前生效，重启后可能丢失"
        fi
      else
        warn "未找到 input 链，请手动放行: nft add rule inet filter input tcp dport $NEW_PORT accept"
      fi
      ;;
    iptables)
      if iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null; then
        info "iptables: 规则已存在"
      else
        iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT && ok "iptables: 已放行 ${NEW_PORT}/tcp"
      fi
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && ok "iptables: 已持久化"
      elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 && ok "iptables: 已保存到 rules.v4"
      else
        warn "iptables 规则重启后可能丢失，请自行持久化"
      fi
      ;;
    *)
      info "未检测到启用的防火墙，无需放行"
      ;;
  esac
}

# ======================== 写配置 ========================
comment_port_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE '^[[:space:]]*Port[[:space:]]+' "$f" || return 0
  sed -i -E 's@^([[:space:]]*Port[[:space:]]+.*)$@#&  # disabled by ssh-port-manager.sh@' "$f"
  info "已注释旧端口行: $f"
}

apply_config() {
  # 目标端口集合
  local targets="$NEW_PORT"
  if [ "$KEEP_OLD" -eq 1 ]; then
    local p
    for p in $(count_ports); do
      case " $targets " in *" $p "*) : ;; *) targets="$targets $p" ;; esac
    done
  fi

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

  # ---- sshd_config 侧 ----
  if [ -d "$SSHD_DROPIN_DIR" ] && grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSHD_MAIN"; then
    { printf '# managed by ssh-port-manager.sh (%s)\n' "$(date -Is)"
      for p in $targets; do printf 'Port %s\n' "$p"; done
    } > "$SSHD_DROPIN"
    chmod 600 "$SSHD_DROPIN"
    ok "已写入: $SSHD_DROPIN"
  else
    { printf '\n# managed by ssh-port-manager.sh (%s)\n' "$(date -Is)"
      for p in $targets; do printf 'Port %s\n' "$p"; done
    } >> "$SSHD_MAIN"
    ok "已追加: $SSHD_MAIN"
  fi

  # ---- socket 侧（Debian 13 / Ubuntu 26.04 关键一步）----
  if [ "$SSH_MODE" = socket ]; then
    mkdir -p "$SOCKET_DROPIN_DIR"
    { printf '# managed by ssh-port-manager.sh (%s)\n[Socket]\nListenStream=\n' "$(date -Is)"
      for p in $targets; do printf 'ListenStream=%s\n' "$p"; done
    } > "$SOCKET_DROPIN"
    ok "已写入: $SOCKET_DROPIN（socket 激活）"
  fi
}

validate_config() {
  if "$SSHD_BIN" -t 2>/tmp/sshd_t.err; then ok "配置校验通过"; return 0; fi
  err "配置校验失败:"; cat /tmp/sshd_t.err >&2; return 1
}

restart_ssh() {
  detect_ssh_mode
  if [ "$SSH_MODE" = socket ]; then
    systemctl daemon-reload
    systemctl restart "$SSH_SOCKET" || return 1
    systemctl try-restart "$SSH_SERVICE" 2>/dev/null
  else
    systemctl restart "$SSH_SERVICE" || return 1
  fi
  if systemctl is-active --quiet "$SSH_SOCKET" 2>/dev/null || systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
    ok "SSH 已重启"; return 0
  fi
  err "SSH 未处于 active"; return 1
}

verify() {
  local i who
  for i in 1 2 3 4 5; do who="$(who_on_port "$NEW_PORT")"; [ -n "$who" ] && break; sleep 1; done
  [ -n "$who" ] && { ok "已在 $NEW_PORT 监听: $who"; return 0; }
  err "未在 $NEW_PORT 检测到监听"; return 1
}

# ======================== 视图 ========================
show_status() {
  step "当前状态"
  detect_os; detect_ssh_mode; detect_firewall
  local svc; svc="$(systemctl is-active "$SSH_SERVICE" 2>/dev/null)"
  local sck; sck="$(systemctl is-active "$SSH_SOCKET"  2>/dev/null)"
  line
  printf '  %-12s %s\n' "系统"      "$OS_NAME"
  printf '  %-12s %s\n' "SSH 模式"  "$([ "$SSH_MODE" = socket ] && echo 'socket 激活 (改端口需同时改 socket)' || echo '常规 service')"
  printf '  %-12s %s\n' "服务状态"  "ssh.service=$svc  ssh.socket=$sck"
  printf '  %-12s %s\n' "当前端口"  "$(count_ports)"
  printf '  %-12s %s\n' "实际监听"  "$(ss -tlnH 'sport = :ssh' 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
  printf '  %-12s %s\n' "防火墙"    "$FW_DESC"
  printf '  %-12s %s\n' "备份数量"  "$(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l)"
  line
}

# ======================== 主流程 ========================
flow_set_port() {
  step "修改 SSH 端口"
  show_status
  detect_ssh_mode

  echo
  ask_port || return 1

  if printf ' %s ' "$(count_ports)" | grep -q " ${NEW_PORT} "; then
    warn "端口 $NEW_PORT 已是 SSH 当前端口，无需修改"; return 0
  fi
  local who; who="$(who_on_port "$NEW_PORT")"
  if [ -n "$who" ]; then err "端口 $NEW_PORT 已被占用: $who"; return 1; fi
  ok "端口 $NEW_PORT 可用"

  echo
  ask_yn "是否保留旧端口（新旧并存，更安全）?" n && KEEP_OLD=1 || KEEP_OLD=0
  ask_yn "是否自动放行防火墙?" y && DO_FW=1 || DO_FW=0
  ask_yn "是否先预演一次（不改动）?" y && DRY=1 || DRY=0

  echo; line
  printf '  目标端口   : %s%s%s\n' "$B" "$NEW_PORT" "$R"
  printf '  旧端口     : %s\n' "$([ "$KEEP_OLD" -eq 1 ] && echo '保留' || echo '替换')"
  printf '  防火墙     : %s\n' "$([ "$DO_FW" -eq 1 ] && echo "自动放行 ($FW_BACKEND)" || echo '跳过')"
  printf '  socket激活 : %s\n' "$([ "$SSH_MODE" = socket ] && echo '是（需同时改 ssh.socket，脚本已处理）' || echo '否')"
  printf '  模式       : %s\n' "$([ "$DRY" -eq 1 ] && echo '预演' || echo '正式执行')"
  line
  ask_yn "确认执行?" y || { info "已取消"; return 0; }

  if [ "$DRY" -eq 1 ]; then
    step "预演（未改动任何配置）"
    info "1) 备份 ssh 配置"
    info "2) $([ "$DO_FW" -eq 1 ] && echo "放行防火墙 ${NEW_PORT}/tcp" || echo '跳过防火墙')"
    info "3) $([ "$KEEP_OLD" -eq 1 ] && echo "追加 Port ${NEW_PORT}" || echo "替换为 Port ${NEW_PORT}")"
    [ "$SSH_MODE" = socket ] && info "4) 同步修改 ssh.socket 的 ListenStream"
    info "5) sshd -t 校验 → 重启 → 验证监听"
    return 0
  fi

  step "执行"
  do_backup
  [ "$DO_FW" -eq 1 ] && open_firewall
  apply_config    || { err "写配置失败"; rollback_current; return 1; }
  validate_config || { rollback_current; return 1; }
  restart_ssh     || { err "重启失败"; rollback_current; return 1; }
  verify          || { err "验证失败，自动回滚"; rollback_current; return 1; }

  step "完成"
  printf '  %-10s %s\n' "新端口"   "$NEW_PORT"
  printf '  %-10s %s\n' "生效端口" "$(count_ports)"
  printf '  %-10s %s\n' "备份目录" "$BACKUP_DIR"
  echo
  warn "先别断开当前会话！新开一个终端测试："
  printf '    %sssh -p %s <用户>@<主机>%s\n' "$B" "$NEW_PORT" "$R"
  [ "$KEEP_OLD" -eq 0 ] && info "确认能连上后，再关闭旧端口、清理旧防火墙规则"
}

flow_rollback() {
  step "回滚最近一次修改"
  [ -d "$BACKUP_ROOT" ] || { warn "没有备份"; return 0; }
  local last; last="$(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort | tail -1)"
  [ -n "$last" ] || { warn "没有备份"; return 0; }
  info "备份: $BACKUP_ROOT/$last"
  ask_yn "确认回滚到这个备份?" n || return 0
  restore_from "$BACKUP_ROOT/$last" && ok "回滚完成，当前端口: $(count_ports)"
}

menu() {
  clear 2>/dev/null || true
  printf '%s' "$MAG"
  cat <<'B'
  ╔══════════════════════════════════════════════════════╗
  ║      SSH 端口管理  (Debian 13 / Ubuntu 26.04)        ║
  ╚══════════════════════════════════════════════════════╝
B
  printf '%s' "$R"
  show_status
  printf '\n%s  请选择：%s\n' "$B" "$R"
  printf '    %s1)%s 修改 SSH 端口（自动放行防火墙）\n' "$CYN" "$R"
  printf '    %s2)%s 刷新状态\n' "$CYN" "$R"
  printf '    %s3)%s 回滚最近一次修改\n' "$CYN" "$R"
  printf '    %s4)%s 退出\n' "$CYN" "$R"
  printf '\n  > '
}

main() {
  [ "$(id -u)" -eq 0 ] || { err "需要 root 权限: sudo $0"; exit 1; }
  [ -t 0 ] || { err "需要终端交互，请勿用 'curl | bash'"; info "改用: bash <(curl -fsSL <URL>)"; exit 1; }
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    err "未找到 sshd，请先安装 openssh-server"; exit 1
  fi
  SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
  detect_os; detect_ssh_mode; detect_firewall

  while true; do
    menu
    read -r ch || exit 0
    case "$ch" in
      1) flow_set_port; pause ;;
      2) : ;;
      3) flow_rollback; pause ;;
      4|q|Q) echo "再见 👋"; exit 0 ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

main "$@"
