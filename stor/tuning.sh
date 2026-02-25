#!/usr/bin/env bash
# =================================================================
# VPSKit Module: stor/tuning.sh
# Description: 交互式优化内核 Swappiness 参数 (含持久化逻辑)
# =================================================================
set -Eeuo pipefail

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_RESET="\033[0m"
C_CYAN="\033[1;36m"

info() { echo -e "${C_GREEN}>>> $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }

# --- 1. 获取当前状态 ---
get_current_swappiness() {
    cat /proc/sys/vm/swappiness
}

# --- 2. 应用并持久化配置 ---
apply_swappiness() {
    local val=$1
    info "正在将 Swappiness 设置为: $val"

    # 临时生效
    sysctl -w vm.swappiness="$val" >/dev/null

    # 持久化设置 (强健壮处理)
    local conf="/etc/sysctl.conf"
    local d_conf="/etc/sysctl.d/99-vpskit-tuning.conf"

    # 优先使用 sysctl.d 目录，如果不存在则使用 sysctl.conf
    if [[ -d "/etc/sysctl.d" ]]; then
        echo "vm.swappiness=$val" > "$d_conf"
        ok "配置已写入 $d_conf"
    else
        # 先删除旧行，再追加新行，防止配置冲突
        sed -i '/vm.swappiness/d' "$conf"
        echo "vm.swappiness=$val" >> "$conf"
        ok "配置已同步至 $conf"
    fi
}

# --- 3. 菜单逻辑 ---
show_menu() {
    local current
    current=$(get_current_swappiness)
    
    echo -e "${C_CYAN}--- Swappiness 性能优化 ---${C_RESET}"
    echo -e "当前内核参数: ${C_YELLOW}vm.swappiness = $current${C_RESET}"
    echo "--------------------------"
    echo "1) 极致响应 (10) - 尽量使用物理内存，适合大多数 VPS"
    echo "2) 平衡模式 (30) - 适度使用虚拟内存"
    echo "3) 默认模式 (60) - 恢复系统原始设置"
    echo "4) 手动输入 (0-100)"
    echo "q) 放弃修改并退出"
    read -r -p "请选择 [1-4/q]: " choice
}

# --- 主流程 ---
main() {
    [[ "$(id -u)" -eq 0 ]] || { echo "❌ 必须以 root 权限运行"; exit 1; }

    show_menu

    case "$choice" in
        1) apply_swappiness 10 ;;
        2) apply_swappiness 30 ;;
        3) apply_swappiness 60 ;;
        4) 
            read -r -p "请输入值 (0-100): " custom_val
            if [[ "$custom_val" =~ ^[0-9]+$ ]] && [ "$custom_val" -le 100 ]; then
                apply_swappiness "$custom_val"
            else
                warn "无效输入，请输入 0 到 100 之间的数字。"
                exit 1
            fi
            ;;
        q|*) info "未做任何修改，退出。"; exit 0 ;;
    esac

    ok "内核参数优化完成！"
}

main