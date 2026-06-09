#!/bin/bash
# ============================================
# 网口限速管理工具
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 自动检测网卡（排除 lo 回环）
detect_ifaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo | grep -v "^$"
}

# 默认选中第一个非 lo 网卡
IFACE=$(detect_ifaces | head -1)
[ -z "$IFACE" ] && IFACE="eth0"

RATE_NUM=""
UNIT="mbit"

get_rate() {
    echo "${RATE_NUM}${UNIT}"
}

get_status() {
    local info
    info=$(tc -s qdisc show dev $IFACE 2>/dev/null | grep -o "htb 1:" | head -1)
    if [ -n "$info" ]; then
        local current_rate=$(tc class show dev $IFACE 2>/dev/null | grep "parent 1:1 classid 1:1" | grep -oP 'rate \K\S+')
        echo -e "${GREEN}[已限速]${NC} 当前速率: ${YELLOW}${current_rate}${NC}"
    else
        echo -e "${RED}[未限速]${NC}"
    fi
}

clear_limit() {
    tc qdisc del dev $IFACE root 2>/dev/null && {
        echo -e "${GREEN}[✓]${NC} 已清除 $IFACE 的限速规则"
    } || {
        echo -e "${YELLOW}[!]${NC} $IFACE 没有限速规则"
    }
}

apply_limit() {
    local rate="$(get_rate)"
    clear_limit 2>/dev/null
    tc qdisc add dev $IFACE root handle 1: htb default 10
    tc class add dev $IFACE parent 1: classid 1:1 htb rate $rate ceil $rate
    tc class add dev $IFACE parent 1:1 classid 1:10 htb rate $rate ceil $rate
    tc qdisc add dev $IFACE parent 1:10 handle 10: sfq perturb 10
    echo -e "${GREEN}[✓]${NC} $IFACE → ${YELLOW}${RATE_NUM}Mbps${NC}"
}

select_iface() {
    echo ""
    local ifaces=()
    while IFS= read -r line; do
        ifaces+=("$line")
    done < <(detect_ifaces)
    
    if [ ${#ifaces[@]} -eq 0 ]; then
        echo -e "${RED}[!]${NC} 未检测到网卡"
        return
    fi
    
    echo -e "  检测到以下网卡:"
    echo ""
    for i in "${!ifaces[@]}"; do
        local idx=$((i+1))
        local mark=""
        [ "${ifaces[$i]}" == "$IFACE" ] && mark=" ← 当前"
        echo "    $idx. ${ifaces[$i]}$mark"
    done
    echo ""
    read -p "  请选择网卡 [1-${#ifaces[@]}]: " iface_choice
    
    if [[ "$iface_choice" =~ ^[0-9]+$ ]] && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#ifaces[@]}" ]; then
        IFACE="${ifaces[$((iface_choice-1))]}"
        echo -e "${GREEN}[✓]${NC} 网卡已切换为 $IFACE"
    else
        echo -e "${RED}[!]${NC} 无效选择"
    fi
}

while true; do
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}        网口限速管理工具${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo -e "  当前网卡: ${YELLOW}$IFACE${NC}"
    if [ -n "$RATE_NUM" ]; then
        echo -e "  当前设置: ${YELLOW}${RATE_NUM}Mbps${NC}"
    else
        echo -e "  当前设置: ${YELLOW}未设置${NC}"
    fi
    echo -n "  状态: "
    get_status
    echo ""
    echo "  1. 修改网卡 (自动检测)"
    echo "  2. 设置限速速率 (输数字，自动应用)"
    echo "  3. 应用限速"
    echo "  4. 清除限速"
    echo "  5. 查看状态"
    echo "  0. 退出"
    echo ""
    read -p "  请选择 [0-5]: " choice

    case $choice in
        1)
            echo ""
            select_iface
            ;;
        2)
            echo ""
            read -p "  输入速率 Mbps (如 100, 300, 500, 1000): " new_rate
            if [ -n "$new_rate" ] && [[ "$new_rate" =~ ^[0-9]+$ ]]; then
                RATE_NUM="$new_rate"
                echo -e "${GREEN}[✓]${NC} 速率已设为 ${RATE_NUM}Mbps，正在自动应用..."
                apply_limit
            else
                echo -e "${RED}[!]${NC} 请输入有效数字"
            fi
            ;;
        3)
            if [ -z "$RATE_NUM" ]; then
                echo -e "${RED}[!]${NC} 请先用选项2设置速率"
            else
                echo ""
                apply_limit
            fi
            ;;
        4)
            echo ""
            clear_limit
            ;;
        5)
            echo ""
            echo -e "  网卡: ${YELLOW}$IFACE${NC}"
            if [ -n "$RATE_NUM" ]; then
                echo -e "  速率: ${YELLOW}${RATE_NUM}Mbps${NC}"
            else
                echo -e "  速率: ${YELLOW}未设置${NC}"
            fi
            echo -n "  状态: "; get_status
            echo ""
            tc -s class show dev $IFACE 2>/dev/null | head -20
            ;;
        0)
            echo ""
            echo -e "${GREEN}退出${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
done
