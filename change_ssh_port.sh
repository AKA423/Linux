#!/usr/bin/env bash
#
# ssh-port-prompt.sh —— 运行后弹出界面，输入端口即自动修改 SSH 端口
#   目标平台: Debian 13 (trixie) / Ubuntu 26.04（兼容相近版本）
#
# 用法:
#   sudo ./ssh-port-prompt.sh                # 弹出输入框，让你填端口
#   sudo ./ssh-port-prompt.sh --keep-old     # 保留旧端口（新旧并存）
#   sudo ./ssh-port-prompt.sh --no-firewall  # 不动防火墙
#   sudo ./ssh-port-prompt.sh 2222           # 也可以直接带上端口，跳过输入
#
# 只需输入端口，其余全自动：查占用 → 放行防火墙 → 备份 → 写配置
#                          → sshd -t 校验 → 重启 → 验证 → 打印结果
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
DEFAULT_PORT="2222"

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

# ======================== 输入（支持管道运行） ========================
# 优先用终端读入；若 stdin 是管道（curl | bash），改从 /dev/tty 读，避免吃掉脚本
read_input() { # read_input <变量名> ; 提示由调用方先打印
  local __v="$1" __x
  if [ -t 0 ]; then
    read -r __x || return 1
  elif [ -r /dev/tty ] && [ -t 1 ]; then
    read -r __x < /dev/tty || return 1
  else
    return 1
  fi
  printf -v "$__v" '%s' "$__x"
}

# ======================== 参数 ========================
KEEP_OLD=0; DO_FW=1; ARG_PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-old)    KEEP_OLD=1; shift ;;
    --no-firewall) DO_FW=0; shift ;;
    -h|--help)     sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)            err "未知选项: $1"; exit 2 ;;
    *)             ARG_PORT="$1"; shift ;;
  esac
done

# ======================== 前置检查 ========================
[ "$(id -u)" -eq 0 ] || { err "需要 root 权限，请用: sudo $0"; exit 1; }
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  err "未找到 sshd，请先安装 openssh-server"; exit 1
fi
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

# ======================== 探测 ========================
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
  FW_BACKEND="none"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    FW_BACKEND="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FW_BACKEND="firewalld"
  elif [ -n "$(nft_input_chain)" ]; then
    FW_BACKEND="nftables"
  elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q '^-A '; then
    FW_BACKEND="iptables"
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

count_ports()  { "$SSHD_BIN" -T 2>/dev/null | awk '/^port /{printf "%s ",$2}'; }
who_on_port()  { ss -tlnH "sport = :$1" 2>/dev/null | awk '{print $NF" "$4}' | tr '\n' ' '; }

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
  info "备份目录: $BACKUP_DIR"
}

rollback() {
  [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ] || { err "无备份，无法回滚"; return 1; }
  [ -f "$BACKUP_DIR/sshd_config" ] && cp -a "$BACKUP_DIR/sshd_config" "$SSHD_MAIN"
  if [ -d "$BACKUP_DIR/sshd_config.d" ] && [ -d "$SSHD_DROPIN_DIR" ]; then
    rm -f "$SSHD_DROPIN" 2>/dev/null
    cp -a "$BACKUP_DIR/sshd_config.d/." "$SSHD_DROPIN_DIR/" 2>/dev/null
  fi
  if [ -f "$BACKUP_DIR/socket.d/10-ssh-port.conf" ]; then
    mkdir -p "$SOCKET_DROPIN_DIR"; cp -a "$BACKUP_DIR/socket.d/10-ssh-port.conf" "$SOCKET_DROPIN"
  else
    rm -f "$SOCKET_DROPIN" 2>/dev/null
  fi
  systemctl daemon-reload 2>/dev/null
  detect_ssh_mode
  if [ "$SSH_MODE" = socket ]; then
    systemctl restart "$SSH_SOCKET" 2>/dev/null
    systemctl try-restart "$SSH_SERVICE" 2>/dev/null
  else
    systemctl restart "$SSH_SERVICE" 2>/dev/null
  fi
  warn "已回滚到修改前配置"
}

# ======================== 防火墙放行 ========================
open_firewall() {
  step "放行防火墙 ${NEW_PORT}/tcp (后端: $FW_BACKEND)"
  case "$FW_BACKEND" in
    ufw)
      ufw allow "${NEW_PORT}/tcp" >/dev/null 2>&1 && ok "ufw: 已放行" || { err "ufw 放行失败"; return 1; } ;;
    firewalld)
      firewall-cmd --permanent --add-port="${NEW_PORT}/tcp" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
      ok "firewalld: 已放行" ;;
    nftables)
      local c; c="$(nft_input_chain)"
      # shellcheck disable=SC2086
      nft add rule $c tcp dport "$NEW_PORT" accept && ok "nftables: 已放行 [$c]"
      if [ -f /etc/nftables.conf ] && systemctl is-enabled --quiet nftables 2>/dev/null; then
        cp -a /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%Y%m%d-%H%M%S)"
        nft list ruleset > /etc/nftables.conf && ok "nftables: 已写入 /etc/nftables.conf（原文件已备份）"
      else
        warn "nftables 规则仅当前生效（重启后可能丢失），请自行写入 /etc/nftables.conf"
      fi ;;
    iptables)
      if iptables -C INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT 2>/dev/null; then
        info "iptables: 规则已存在"
      else
        iptables -I INPUT -p tcp --dport "$NEW_PORT" -j ACCEPT && ok "iptables: 已放行"
      fi
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && ok "iptables: 已持久化"
      elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 && ok "iptables: 已保存 rules.v4"
      else
        warn "iptables 规则重启后可能丢失"
      fi ;;
    *)
      info "未检测到启用的防火墙，无需放行" ;;
  esac
  return 0
}

# ======================== 写配置 ========================
comment_port_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -qE '^[[:space:]]*Port[[:space:]]+' "$f" || return 0
  sed -i -E 's@^([[:space:]]*Port[[:space:]]+.*)$@#&  # disabled by ssh-port-prompt.sh@' "$f"
  info "已注释旧端口行: $f"
}

apply_config() {
  local targets="$NEW_PORT" p
  if [ "$KEEP_OLD" -eq 1 ]; then
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

  if [ -d "$SSHD_DROPIN_DIR" ] && grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSHD_MAIN"; then
    { printf '# managed by ssh-port-prompt.sh (%s)\n' "$(date -Is)"
      for p in $targets; do printf 'Port %s\n' "$p"; done
    } > "$SSHD_DROPIN"
    chmod 600 "$SSHD_DROPIN"
    ok "已写入: $SSHD_DROPIN"
  else
    { printf '\n# managed by ssh-port-prompt.sh (%s)\n' "$(date -Is)"
      for p in $targets; do printf 'Port %s\n' "$p"; done
    } >> "$SSHD_MAIN"
    ok "已追加: $SSHD_MAIN"
  fi

  # socket 侧 —— Debian 13 / Ubuntu 26.04 关键
  if [ "$SSH_MODE" = socket ]; then
    mkdir -p "$SOCKET_DROPIN_DIR"
    { printf '# managed by ssh-port-prompt.sh (%s)\n[Socket]\nListenStream=\n' "$(date -Is)"
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

# ======================== 弹窗输入 ========================
draw_box() {
  # draw_box <标题> <行1> <行2> ...
  local title="$1"; shift
  local w=56 line=""
  printf '%s╔═%s═╗%s\n' "$MAG$B" "$(printf '═%.0s' $(seq 1 $((w-6))))" "$R"
  printf '%s║%s %-*s %s║%s\n' "$MAG$B" "$R" $((w-4)) "$title" "$MAG$B" "$R"
  printf '%s╠═%s═╣%s\n' "$MAG$B" "$(printf '═%.0s' $(seq 1 $((w-6))))" "$R"
  local l
  for l in "$@"; do
    printf '%s║%s %-*s %s║%s\n' "$MAG$B" "$R" $((w-4)) "$l" "$MAG$B" "$R"
  done
  printf '%s╚═%s═╝%s\n' "$MAG$B" "$(printf '═%.0s' $(seq 1 $((w-6))))" "$R"
}

ask_port_box() {
  detect_ssh_mode; detect_firewall
  clear 2>/dev/null || true
  draw_box "修改 SSH 端口" \
    "系统     : ${OS_NAME:-unknown}" \
    "SSH 模式 : $([ "$SSH_MODE" = socket ] && echo 'socket 激活' || echo '常规 service')" \
    "当前端口 : $(count_ports)" \
    "防火墙   : $FW_BACKEND"
  echo

  local p
  while true; do
    printf '  %s请输入新的 SSH 端口%s (1-65535) [回车默认 %s，q 退出]: ' "$B" "$R" "$DEFAULT_PORT"
    if ! read_input p; then
      err "无法读取输入（没有可用终端）"; exit 1
    fi
    p="${p:-$DEFAULT_PORT}"
    case "$p" in q|Q) echo "已取消"; exit 0 ;; esac
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
      NEW_PORT="$p"; return 0
    fi
    warn "端口无效：$p（必须是 1-65535 的整数）"
  done
}

# ======================== 主流程 ========================
main() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${PRETTY_NAME:-unknown}"
  else
    OS_NAME="unknown"
  fi

  NEW_PORT="$ARG_PORT"
  if [ -n "$NEW_PORT" ]; then
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
      err "端口无效: $NEW_PORT （需 1-65535）"; exit 2
    fi
  else
    ask_port_box
    echo
  fi

  step "目标：SSH 端口 -> $NEW_PORT"
  info "当前端口 : $(count_ports)"
  info "旧端口   : $([ "$KEEP_OLD" -eq 1 ] && echo '保留' || echo '替换')"
  info "防火墙   : $([ "$DO_FW" -eq 1 ] && echo "自动放行 ($FW_BACKEND)" || echo '跳过')"

  if printf ' %s ' "$(count_ports)" | grep -q " ${NEW_PORT} "; then
    warn "端口 $NEW_PORT 已是 SSH 当前端口，无需修改"; exit 0
  fi
  local who; who="$(who_on_port "$NEW_PORT")"
  if [ -n "$who" ]; then err "端口 $NEW_PORT 已被占用: $who"; exit 1; fi
  ok "端口 $NEW_PORT 可用"

  do_backup
  [ "$DO_FW" -eq 1 ] && { open_firewall || { rollback; exit 1; }; }
  apply_config    || { err "写配置失败"; rollback; exit 1; }
  validate_config || { rollback; exit 1; }
  restart_ssh     || { rollback; exit 1; }
  verify          || { rollback; exit 1; }

  step "完成"
  printf '  %-10s %s\n' "新端口"   "$NEW_PORT"
  printf '  %-10s %s\n' "生效端口" "$(count_ports)"
  printf '  %-10s %s\n' "备份目录" "$BACKUP_DIR"
  echo
  warn "先别断开当前会话！新开终端测试:"
  printf '    %sssh -p %s <用户>@<主机>%s\n' "$B" "$NEW_PORT" "$R"
}

main "$@"
