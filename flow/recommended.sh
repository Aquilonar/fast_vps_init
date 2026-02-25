#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# VPSKit Module: summary.sh (Recommended Flow)
# Description: 自动化执行推荐流程，增加交互确认
# ==================================================

FLOW_NAME="Recommended Flow v1"

# 补充颜色定义（防止 main.sh 变量未导出）
C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RESET="\033[0m"

# 通用询问函数
confirm_step() {
    local name="$1"
    local ans
    # 使用 /dev/tty 确保在管道执行时也能正确读取输入
    echo -ne "${C_YELLOW}❓ 是否执行模块 [${name}]? [Y/n]: ${C_RESET}"
    read -r ans </dev/tty || ans="n"
    ans="${ans:-y}"
    [[ "${ans^^}" == "Y" ]]
}

run_one() {
    local name="$1"
    local rel="$2"
    local limit="${3:-ALL}"

    # 1. 容器环境自动跳过 KVM_ONLY (鲁棒性：前置检查)
    if [[ "${IS_LXC:-false}" == "true" && "$limit" == "KVM_ONLY" ]]; then
        warn "跳过：$name（仅KVM，当前=$VIRT）"
        log "FLOW_SKIP name=$name rel=$rel reason=KVM_ONLY virt=$VIRT"
        return 0
    fi

    # 2. 交互确认 (YN 逻辑)
    if ! confirm_step "$name"; then
        echo -e "${C_GRAY}>> 已跳过模块: $name${C_RESET}"
        return 0
    fi

    # 3. 执行逻辑
    echo "------------------------------------------"
    echo -e "  🚀 正在启动: ${C_GREEN}${name}${C_RESET}"
    echo -e "  路径: ${rel}"
    echo "------------------------------------------"
    log "FLOW_RUN name=$name rel=$rel"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        warn "dry-run：不执行"
        return 0
    fi

    # 鲁棒性：尝试捕获脚本拉取错误
    local f
    if f="$(fetch_script "$rel")"; then
        bash "$f"
        ok "完成：$name"
    else
        err "下载脚本失败: $rel"
        return 1
    fi
}

main() {
    clear
    echo -e "${C_CYAN}=========================================="
    echo -e "      $FLOW_NAME "
    echo -e "==========================================${C_RESET}"
    echo -e "  环境: ${VIRT:-unknown} (LXC=${IS_LXC:-?}) | 源: ${BASE_URL:-?}"
    echo -e "  日志: ${LOG_FILE:-?}"
    echo

    # --- 流程开始 ---
    # 0) Baseline
    run_one "更新软件源 (Mirror)"           "base/mirror.sh" "ALL"
    run_one "时区与主机名设置"               "base/system.sh" "ALL"
    run_one "常用软件包安装 (git/vim/curl)" "base/pkgs.sh"   "ALL"
    run_one "安装系统语言包"                 "base/lang.sh"   "ALL"

    # 1) Storage
    run_one "ZRAM/SWAP 配置"                "stor/swap.sh"   "ALL"
    run_one "Swappiness 性能优化"           "stor/tuning.sh" "ALL"
    run_one "自动磁盘挂载"                   "stor/mount.sh"  "ALL"

    # 2) Network
    run_one "DNS 优化 (DoH/DoT)"            "net/dns.sh"     "ALL"
    run_one "MTU 调整与 TCP FastOpen"       "net/tcp.sh"     "ALL"
    run_one "BBRv3 官方加速"                "net/bbr.sh"     "KVM_ONLY"

    # 3) Identity
    run_one "创建新用户 (Sudoer)"           "id/user.sh"     "ALL"
    run_one "SSH Key 注入"                  "id/key.sh"      "ALL"
    run_one "Sudo 免密权限配置"             "id/sudo.sh"     "ALL"

    # 4) Hardening
    run_one "SSH 端口修改"                  "hard/port.sh"   "ALL"
    run_one "禁用密码登录"                  "hard/auth.sh"   "ALL"
    run_one "UFW 防火墙配置"                "hard/ufw.sh"    "ALL"
    run_one "Fail2ban 防暴力破解"           "hard/f2b.sh"    "ALL"

    # 5) Runtime
    run_one "Docker & Compose 环境"         "run/docker.sh"  "ALL"
    run_one "Node.js (NVM版) 安装"          "run/node.sh"    "ALL"
    run_one "Python3 (Venv) 环境"           "run/py.sh"      "ALL"

    # 6) Connectivity
    run_one "Tailscale 组网安装"            "conn/ts.sh"     "ALL"
    run_one "Cloudflare Warp 代理"          "conn/warp.sh"   "KVM_ONLY"
    run_one "Frp 穿透客户端"                "conn/frp.sh"    "ALL"
    run_one "Komari 探针客户端"             "conn/komari.sh"    "ALL"

    # 7) Cleanup
    run_one "清理系统包缓存"                "clean/cache.sh" "ALL"
    run_one "日志截断与空间回收"            "clean/logs.sh"  "ALL"

    echo
    ok "推荐流程执行完毕"
}

main "$@"