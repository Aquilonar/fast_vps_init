#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

# 定义 info 函数，修复之前的 command not found
info() { echo -e "${C_CYAN}>>> $*${C_RESET}"; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# --- 1. 安装 cloudflared ---
install_cloudflared() {
    if have_cmd cloudflared; then
        ok "cloudflared 已安装，跳过。"
        return 0
    fi

    info "开始安装 cloudflared..."
    
    if have_cmd apt-get; then
        log "检测到 Debian/Ubuntu 系统，正在配置..."
        # 彻底清理可能导致报错的旧源
        rm -f /etc/apt/sources.list.d/cloudflared.list
        
        # 1. 添加 GPG key (去掉 sudo)
        mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
        
        # 2. 添加仓库 (使用 any)
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
        
        # 3. 安装
        apt-get update && apt-get install -y cloudflared
        
    elif have_cmd yum || have_cmd dnf; then
        log "检测到 RedHat/CentOS 系统，正在配置..."
        # 1. 添加 repo
        curl -fsSl https://pkg.cloudflare.com/cloudflared.repo | tee /etc/yum.repos.d/cloudflared.repo
        # 2. 更新并安装
        yum update -y && yum install -y cloudflared
    else
        err "不支持的包管理器。"
        exit 1
    fi

    if have_cmd cloudflared; then
        ok "cloudflared 安装成功！"
    else
        err "安装失败，请检查网络。"
        exit 1
    fi
}

# --- 2. 配置 Zero Trust (Token 交互) ---
setup_zero_trust() {
    echo -e "\n${C_YELLOW}--- Cloudflare Zero Trust 隧道配置 ---${C_RESET}"
    info "请在 CF 页面复制指令 (例如: cloudflared service install eyJhIjoi...)"
    
    # 强制等待输入
    read -r -p "请输入完整 Token 指令: " cf_cmd </dev/tty

    if [[ "$cf_cmd" == *"cloudflared service install"* ]]; then
        info "正在配置并检查反馈..."
        
        # 提取 Token
        local token=$(echo "$cf_cmd" | awk '{print $NF}')

        # 容器环境兼容处理 (不使用 service install，因为没有 systemd)
        if [[ -f /.dockerenv ]]; then
            warn "检测到 Docker 环境，正在以后台模式启动隧道..."
            nohup cloudflared tunnel --no-autoupdate run --token "$token" > /tmp/cloudflared.log 2>&1 &
            sleep 3
            
            if pgrep -x "cloudflared" >/dev/null; then
                ok "Cloudflared 隧道已在后台成功启动！"
                log "查看日志: tail -f /tmp/cloudflared.log"
            else
                err "启动失败，日志反馈："
                tail -n 5 /tmp/cloudflared.log
            fi
        else
            # VPS 正常环境 (去掉 sudo 执行)
            local clean_cmd=$(echo "$cf_cmd" | sed 's/sudo //g')
            if eval "$clean_cmd"; then
                ok "Cloudflared 服务已成功安装并启动！"
            else
                err "指令运行失败。"
            fi
        fi
    else
        err "无效指令，请确保包含了 Token。"
    fi
}

# --- 主入口 ---
main() {
    need_root
    
    echo -e "${C_CYAN}Cloudflare Connector 管理助手${C_RESET}"
    echo "1) 安装 cloudflared"
    echo "2) 配置 Zero Trust 隧道 (Token)"
    echo "3) 全部执行 (安装 + 配置)"
    echo "q) 退出"
    read -r -p "请选择 [1-3/q]: " opt </dev/tty

    case "$opt" in
        1) install_cloudflared ;;
        2) setup_zero_trust ;;
        3) 
            install_cloudflared
            setup_zero_trust
            ;;
        q) exit 0 ;;
        *) main ;;
    esac
}

main