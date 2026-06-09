#!/bin/bash

# 检查是否为 Root 用户
if [ "$EUID" -ne 0 ]; then
    echo "错误: 请以 root 用户运行此脚本！"
    exit 1
fi

SCRIPT_PATH=$(readlink -f "$0")
SERVICE_NAME="vps-speed-limit"
CONF_FILE="/etc/vps_speed_limit.conf"

# 自动获取默认网卡
get_default_interface() {
    local iface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
    fi
    echo "$iface"
}

# 加载配置
load_config() {
    if [ -f "$CONF_FILE" ]; then
        source "$CONF_FILE"
    else
        IFACE=$(get_default_interface)
        LIMIT_IN=""
        LIMIT_OUT=""
    fi
}

# 保存配置
save_config() {
    echo "IFACE=\"$IFACE\"" > "$CONF_FILE"
    echo "LIMIT_IN=\"$LIMIT_IN\"" >> "$CONF_FILE"
    echo "LIMIT_OUT=\"$LIMIT_OUT\"" >> "$CONF_FILE"
}

# 清除限速规则
clear_limit() {
    load_config
    if [ -z "$IFACE" ]; then
        echo "未检测到有效网卡。"
        return
    fi
    
    # 删除入站和出站规则（忽略错误报错）
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc del dev "$IFACE" ingress 2>/dev/null
    # 移除可能存在的 ifb 虚拟网卡规则
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set dev ifb0 down 2>/dev/null
    modprobe -r ifb 2>/dev/null
    
    echo "========================================="
    echo " 网卡 $IFACE 的限速规则已成功清除！"
    echo "========================================="
}

# 应用限速规则（进程守护/自启核心逻辑）
apply_limit() {
    load_config
    
    if [ -z "$IFACE" ] || [ -z "$LIMIT_OUT" ] || [ -z "$LIMIT_IN" ]; then
        echo "配置不完整，无法应用限速。请先进行设置。"
        exit 1
    fi

    # 先清理旧规则
    tc qdisc del dev "$IFACE" root 2>/dev/null
    tc qdisc del dev "$IFACE" ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    ip link set dev ifb0 down 2>/dev/null

    # ---------------- 1. 出站限速 (Upload) ----------------
    tc qdisc add dev "$IFACE" root handle 1: htb default 11
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "${LIMIT_OUT}mbit"
    tc class add dev "$IFACE" parent 1:1 classid 1:11 htb rate "${LIMIT_OUT}mbit"
    tc qdisc add dev "$IFACE" parent 1:11 handle 11: fq_codel

    # ---------------- 2. 入站限速 (Download) ----------------
    # 借助 ifb 虚拟网卡实现入站限速
    modprobe ifb numifbs=1
    ip link set dev ifb0 up
    
    # 将网卡的入站流量重定向到 ifb0
    tc qdisc add dev "$IFACE" handle ffff: ingress
    tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0

    # 对 ifb0 进行限速（相当于对原生网卡入站限速）
    tc qdisc add dev ifb0 root handle 1: htb default 11
    tc class add dev ifb0 parent 1: classid 1:1 htb rate "${LIMIT_IN}mbit"
    tc class add dev ifb0 parent 1:1 classid 1:11 htb rate "${LIMIT_IN}mbit"
    tc qdisc add dev ifb0 parent 1:11 handle 11: fq_codel

    echo "限速已成功应用：网卡=$IFACE | 下载=${LIMIT_IN}Mbps | 上传=${LIMIT_OUT}Mbps"
}

# 设置限速参数
setup_limit() {
    load_config
    echo "--- 当前网卡配置 ---"
    echo "自动识别到的默认网卡: $(get_default_interface)"
    read -p "请输入要限速的网卡名称 (回车默认: $IFACE): " input_iface
    [ -n "$input_iface" ] && IFACE=$input_iface

    read -p "请输入下载限速值 (单位 Mbps, 例如 10): " input_in
    read -p "请输入上传限速值 (单位 Mbps, 例如 10): " input_out

    if [[ ! "$input_in" =~ ^[0-9]+$ ]] || [[ ! "$input_out" =~ ^[0-9]+$ ]]; then
        echo "错误：限速值必须为纯数字！"
        return
    fi

    LIMIT_IN=$input_in
    LIMIT_OUT=$input_out
    save_config

    # 立即应用
    apply_limit
    
    # 提示配置自启
    read -p "是否开启开机自启和进程守护？(y/n): " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        enable_daemon
    fi
}

# 开启自启和进程守护 (Systemd)
enable_daemon() {
    cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=VPS Traffic Control Daemon
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH --apply
ExecStop=$SCRIPT_PATH --clear

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.service
    systemctl start ${SERVICE_NAME}.service
    echo "========================================="
    echo " 开机自启与 Systemd 守护进程已成功开启！"
    echo "========================================="
}

# 关闭自启和守护
disable_daemon() {
    systemctl disable ${SERVICE_NAME}.service 2>/dev/null
    systemctl stop ${SERVICE_NAME}.service 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    echo "========================================="
    echo " 开机自启与进程守护已关闭。"
    echo "========================================="
}

# 查看当前状态
show_status() {
    load_config
    echo "================= 当前状态 ================="
    echo "当前保存的网卡: ${IFACE:-未设置}"
    echo "当前保存的下载: ${LIMIT_IN:-未设置} Mbps"
    echo "当前保存的上传: ${LIMIT_OUT:-未设置} Mbps"
    
    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        echo "自启守护状态: [已激活 / 运行中]"
    else
        echo "自启守护状态: [未激活]"
    fi
    echo "----------------------------------------"
    echo "--- 实时网卡 tc 规则 ---"
    if [ -n "$IFACE" ]; then
        tc qdisc show dev "$IFACE"
    fi
    echo "========================================="
}

# 命令行特殊参数支持（供 Systemd 调用）
if [ "$1" == "--apply" ]; then
    apply_limit
    exit 0
elif [ "$1" == "--clear" ]; then
    clear_limit
    exit 0
fi

# 交互菜单
while true; do
    echo "========================================="
    echo "       VPS 网卡智能限速管理脚本          "
    echo "========================================="
    echo " 1. 设置限速规则 (自动识别/手动修改)"
    echo " 2. 清除当前限速规则"
    echo " 3. 开启 开机自启与守护进程"
    echo " 4. 关闭 开机自启与守护进程"
    echo " 5. 查看 当前配置与运行状态"
    echo " 0. 退出脚本"
    echo "========================================="
    read -p "请选择操作 [0-5]: " num
    case "$num" in
        1) setup_limit ;;
        2) clear_limit ;;
        3) enable_daemon ;;
        4) disable_daemon ;;
        5) show_status ;;
        0) exit 0 ;;
        *) echo "输入错误，请输入 0-5 之间的数字！" ;;
    esac
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    clear
done
