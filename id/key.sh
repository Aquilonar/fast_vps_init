#!/usr/bin/env bash
# =================================================================
# VPSKit Module: id/key.sh
# Description: 身份管理 - SSH 公钥注入 (支持交互式与静默模式)
# =================================================================
set -Eeuo pipefail

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

# --- 1. 基础工具 ---
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行"; exit 1; }; }

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    read -r -p "$(echo -e "${C_YELLOW}${prompt} [y/N] (默认 $default): ${C_RESET}")" input
    input="${input:-$default}"
    case "$input" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 2. 交互式获取参数 ---
USER_NAME=""
KEY_TEXT=""

parse_args_or_interact() {
    # 尝试解析命令行参数 (兼容原脚本逻辑)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) USER_NAME="${2:-}"; shift 2;;
            --key)  KEY_TEXT="${2:-}"; shift 2;;
            *) shift ;;
        esac
    done

    # 如果没有传参，开启交互模式
    if [[ -z "$USER_NAME" ]]; then
        echo -e "${C_CYAN}>>> SSH 公钥注入配置${C_RESET}"
        read -r -p "请输入要注入公钥的用户名 [默认: root]: " USER_NAME
        USER_NAME="${USER_NAME:-root}"
    fi

    if [[ "$USER_NAME" == "root" ]]; then
        warn "注意：你正在尝试为 root 用户注入公钥。"
        confirm "确定要继续吗？" "Y" || exit 0
    fi

    if [[ -z "$KEY_TEXT" ]]; then
        echo -e "${C_YELLOW}请输入你的公钥内容 (ssh-rsa/ssh-ed25519 ...):${C_RESET}"
        read -r KEY_TEXT
    fi

    [[ -n "$KEY_TEXT" ]] || { err "公钥不能为空"; exit 1; }
}

# --- 3. 逻辑处理 ---
ensure_user_exists() {
    id "$USER_NAME" >/dev/null 2>&1 || { err "系统中不存在用户: $USER_NAME"; exit 1; }
}

inject_key() {
    local home sshdir auth
    # 获取用户 Home 目录
    home=$(getent passwd "$USER_NAME" | cut -d: -f6)
    [[ -n "$home" && -d "$home" ]] || { err "无法找到用户 $USER_NAME 的家目录"; exit 1; }

    sshdir="$home/.ssh"
    read -r -p "请输入目标文件名 [默认: authorized_keys]: " custom_auth
    auth="$sshdir/${custom_auth:-authorized_keys}"

    # 权限与目录初始化
    mkdir -p "$sshdir"
    chmod 700 "$sshdir"
    touch "$auth"
    chmod 600 "$auth"

    # 去重校验：清理格式并对比
    local clean_key; clean_key=$(echo "$KEY_TEXT" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    if grep -qF "$clean_key" "$auth"; then
        ok "该公钥已存在于 $USER_NAME 的授权列表中，无需重复写入。"
    else
        if confirm "确认将该公钥写入 $USER_NAME 的 authorized_keys?"; then
            echo "$clean_key" >> "$auth"
            chown -R "$USER_NAME:$USER_NAME" "$sshdir"
            ok "注入成功！"
        else
            warn "操作取消。"
            exit 0
        fi
    fi
}

main() {
    need_root
    parse_args_or_interact "$@"
    ensure_user_exists
    inject_key

    # 最后状态展示
    echo -e "\n${C_CYAN}--- 当前 $USER_NAME 的公钥快照 (最后 2 行) ---${C_RESET}"
    tail -n 2 "$(getent passwd "$USER_NAME" | cut -d: -f6)/.ssh/authorized_keys" 2>/dev/null || true
    echo -e "${C_CYAN}---------------------------------------------${C_RESET}"
}

main "$@"