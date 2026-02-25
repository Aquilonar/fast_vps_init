#!/usr/bin/env bash
# =================================================================
# VPSKit Module: base/pkgs.sh
# Description: 交互式安装常用工具 (支持多选与强健壮检查)
# =================================================================
set -Eeuo pipefail

C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_RESET="\033[0m"

info() { echo -e "${C_GREEN}>>> $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }

# --- 1. 环境准备 ---
detect_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"; INSTALL_CMD="apt-get install -y -qq"; UPDATE_CMD="apt-get update -qq"
        export DEBIAN_FRONTEND=noninteractive
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"; INSTALL_CMD="dnf install -y"; UPDATE_CMD="dnf makecache"
    else
        echo -e "${C_RED}❌ 不支持的包管理器${C_RESET}"; exit 1
    fi
}

# --- 2. 各个安装模块 ---
do_install_base() {
    info "检查基础工具 (curl, wget)..."
    for p in curl wget; do
        command -v "$p" >/dev/null 2>&1 && ok "$p 已存在" || $INSTALL_CMD "$p"
    done
}

do_install_fzf() {
    info "检查 fzf..."
    command -v fzf >/dev/null 2>&1 && ok "fzf 已存在" || ($INSTALL_CMD fzf || warn "源中未找到 fzf")
}

do_install_nginx() {
    info "检查 Nginx..."
    command -v nginx >/dev/null 2>&1 || $INSTALL_CMD nginx
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now nginx || warn "Nginx 启动失败，请检查端口占用"
    else
        service nginx start || true
    fi
    ok "Nginx 状态检查完成"
}

# --- 3. 菜单与逻辑控制 ---
show_menu() {
    echo -e "${C_CYAN}请选择要安装的软件包 (支持多选，如 '1 3'):${C_RESET}"
    echo "1) 基础工具 (curl, wget)"
    echo "2) 模糊搜索 (fzf)"
    echo "3) Web服务器 (nginx)"
    echo "4) 全部安装"
    echo "q) 取消并退出"
    read -r -p "选择 [1-4/q]: " choice
}

# --- 主流程 ---
main() {
    [[ "$(id -u)" -eq 0 ]] || { echo "❌ 必须以 root 权限运行"; exit 1; }
    detect_manager

    show_menu

    [[ "$choice" == "q" ]] && exit 0
    
    # 执行缓存更新
    info "正在更新包索引..."
    $UPDATE_CMD

    # 处理选择逻辑
    [[ "$choice" == *"4"* ]] && choice="1 2 3"

    for c in $choice; do
        case "$c" in
            1) do_install_base ;;
            2) do_install_fzf ;;
            3) do_install_nginx ;;
            *) warn "忽略无效选项: $c" ;;
        esac
    done

    ok "所选任务执行完毕"
}

main