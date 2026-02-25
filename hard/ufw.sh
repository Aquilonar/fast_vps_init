#!/usr/bin/env bash
# =================================================================
# VPSKit Module: hard/ufw.sh
# Description: 安全加固 - UFW 防火墙配置 (带端口预检与 YN 确认)
# =================================================================
set -Eeuo pipefail

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

# --- 1. 基础工具 ---
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

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

# 自动探测当前 SSH 监听端口
detect_ssh_port() {
    local port
    port=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -n1)
    echo "${port:-22}"
}

# --- 2. 安装逻辑 ---
install_ufw(){
    if have_cmd ufw; then 
        return 0 
    fi
    
    # 智能提示：如果没装，询问是否安装，默认设为 Y
    warn "系统未检测到 UFW (Uncomplicated Firewall)。"
    if confirm "是否现在安装 UFW 以增强系统安全性？" "Y"; then
        log "正在识别包管理器并安装..."
        if have_cmd apt-get; then
            apt-get update -qq && apt-get install -y ufw >/dev/null
        elif have_cmd dnf; then
            dnf install -y ufw >/dev/null
        elif have_cmd yum; then
            yum install -y fail2ban >/dev/null # 兼容旧版系统
        else
            err "无法识别的包管理器，请手动执行安装命令 (如 apt install ufw)"
            exit 1
        fi
        ok "UFW 安装完成。"
    else
        warn "用户拒绝安装防火墙，脚本无法继续执行配置任务。"
        exit 0
    fi
}

# --- 3. 规则配置逻辑 ---
setup_ufw() {
    local current_ssh; current_ssh=$(detect_ssh_port)
    
    echo -e "\n${C_CYAN}>>> 防火墙安全预检${C_RESET}"
    echo -e "检测到当前 SSH 端口为: ${C_GREEN}${current_ssh}${C_RESET}"
    
    if ! confirm "是否确认放行端口 ${current_ssh} 并启用防火墙？(失败将导致断开连接)"; then
        warn "配置已终止。"
        return 1
    fi

    # 初始化默认策略
    log "设置默认策略: 拒绝入站 / 允许出站..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    # 核心：必须放行 SSH
    ufw allow "${current_ssh}/tcp" >/dev/null
    ok "核心规则：已放行 SSH (${current_ssh}/tcp)"

    # 扩展：常用端口放行
    if confirm "是否顺便放行常用的 Web 端口 (80/443)?"; then
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ok "已放行 80, 443"
    fi

    # 启用 UFW
    echo -e "\n${C_RED}即将正式启用防火墙！${C_RESET}"
    if confirm "确定要激活并使规则生效吗？"; then
        echo "y" | ufw enable >/dev/null
        ok "UFW 已成功启动并激活。"
    else
        warn "配置已写入，但 UFW 仍处于关闭状态。"
    fi
}

# --- 4. 状态展示 ---
show_status(){
    echo -e "\n${C_CYAN}--- UFW 当前状态 ---${C_RESET}"
    ufw status verbose || true
    echo -e "${C_CYAN}-------------------${C_RESET}"
}

# --- 主流程 ---
main(){
    need_root
    
    echo -e "${C_CYAN}==========================================${C_RESET}"
    echo -e "         UFW 安全防火墙配置"
    echo -e "${C_CYAN}==========================================${C_RESET}"

    install_ufw
    
    if setup_ufw; then
        show_status
        ok "防火墙配置任务完成。"
        warn "重要：请保持当前会话，另开终端测试 SSH 是否能正常连接！"
    else
        ok "退出脚本。"
    fi
}

main