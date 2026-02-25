#!/usr/bin/env bash
# =================================================================
# VPSKit Module: base/lang.sh
# Description: 安装中文/英文语言包并可选配置默认 Locale
# =================================================================
set -Eeuo pipefail

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_RESET="\033[0m"

info() { echo -e "${C_GREEN}>>> $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }

# --- 1. 安装语言包 ---
install_lang_pkgs() {
    info "正在安装核心语言支持包 (zh_CN & en_US)..."
    
    if command -v apt-get >/dev/null 2>&1; then
        # 预设前端为非交互模式，防止弹窗
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq locales language-pack-zh-hans language-pack-en >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y langpacks-zh_CN langpacks-en >/dev/null
    else
        warn "未识别的包管理器，尝试通过 localedef 强制生成..."
    fi
}

# --- 2. 生成 Locale ---
generate_locales() {
    info "正在生成系统 Locale 配置..."
    
    # 尝试生成常用 Locale，忽略已存在的错误
    if command -v locale-gen >/dev/null 2>&1; then
        locale-gen en_US.UTF-8 zh_CN.UTF-8 >/dev/null
    else
        localedef -v -c -i zh_CN -f UTF-8 zh_CN.UTF-8 || true
        localedef -v -c -i en_US -f UTF-8 en_US.UTF-8 || true
    fi
}

# --- 3. 修改默认语言 (可选) ---
configure_default_lang() {
    echo -e "\n${C_YELLOW}语言包安装已完成。${C_RESET}"
    echo "1. 保持当前设置 (推荐)"
    echo "2. 设置系统默认语言为 [中文 UTF-8]"
    echo "3. 设置系统默认语言为 [英文 UTF-8]"
    read -r -p "请选择 (默认 1): " choice

    case "$choice" in
        2)
            local target="zh_CN.UTF-8"
            local lang_env="zh_CN.UTF-8"
            ;;
        3)
            local target="en_US.UTF-8"
            local lang_env="en_US.UTF-8"
            ;;
        *)
            info "跳过默认语言修改。"
            return 0
            ;;
    esac

    info "正在应用语言设置: $target"
    if command -v localectl >/dev/null 2>&1; then
        localectl set-locale LANG=$target
    else
        echo "LANG=$target" > /etc/default/locale
        export LANG=$target
    fi
    ok "设置成功！部分更改可能在下次登录后生效。"
}

# --- 主流程 ---
main() {
    [[ "$(id -u)" -eq 0 ]] || { echo "❌ 必须以 root 权限运行"; exit 1; }
    
    install_lang_pkgs
    generate_locales
    configure_default_lang
}

main