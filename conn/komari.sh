#!/usr/bin/env bash
# =================================================================
# VPSKit Module: conn/komari.sh
# Description: 通用命令粘贴执行器 (用于安装 Komari 等)
# =================================================================
set -Eeuo pipefail

# 颜色定义
C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_RESET="\033[0m"; C_YELLOW="\033[1;33m"

main() {
    clear
    echo -e "${C_CYAN}=========================================="
    echo -e "       Komari 客户端通用安装器"
    echo -e "==========================================${C_RESET}"
    echo
    echo -e "${C_YELLOW}请在下方粘贴你的完整安装命令 (Shift+Insert 或 右键粘贴):${C_RESET}"
    echo -e "------------------------------------------------------"
    
    # 核心：读取用户粘贴的完整命令
    # 使用 -r 处理转义符，使用 /dev/tty 确保在复杂环境下也能捕获输入
    read -r -p "> " USER_CMD </dev/tty

    if [[ -z "$USER_CMD" ]]; then
        echo -e "\033[1;31m❌ 未检测到内容，操作取消。${C_RESET}"
        exit 1
    fi

    echo -e "------------------------------------------------------"
    echo -e "${C_GREEN}🚀 正在执行你粘贴的命令...${C_RESET}"
    echo

    # 执行粘贴的内容
    # 注意：这里直接 eval 执行，支持管道、换行符和多参数
    eval "$USER_CMD"

    echo
    echo -e "${C_GREEN}✅ 执行完毕。${C_RESET}"
}

main "$@"