#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_GRAY="\033[90m"

ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
log()  { echo -e "\033[90m[$(date +'%H:%M:%S')]\033[0m $*"; }

# 子程序：安装并配置 CrowdSec
run_crowdsec_setup() {
    local install_script_url="https://install.crowdsec.net"
    local local_script="$(pwd)/crowdsec_install.sh"
    
    # 1. 环境依赖检查
    log "检查并安装基础依赖 (curl, gnupg2)..."
    apt-get update >/dev/null
    apt-get install -y curl gnupg2 >/dev/null || { err "基础依赖安装失败"; return 1; }

    # 2. 下载仓库配置脚本
    log "正在获取 CrowdSec 官方软件源..."
    if ! curl -sL --retry 5 --connect-timeout 10 "$install_script_url" -o "$local_script"; then
        err "下载仓库脚本失败，请检查网络"
        return 1
    fi

    # 3. 执行仓库配置
    if [[ -f "$local_script" ]]; then
        chmod +x "$local_script"
        log "配置 APT 仓库..."
        sh "$local_script" >/dev/null || { err "仓库配置失败"; rm -f "$local_script"; return 1; }
    fi

    # 4. 安装 CrowdSec 核心引擎
    log "正在安装 CrowdSec 核心引擎..."
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
    if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec; then
        ok "CrowdSec 核心引擎安装成功"
    else
        err "CrowdSec 安装失败"
        return 1
    fi

    # 5. 安装 Firewall Bouncer (自动封禁组件)
    # 这个组件负责将 CrowdSec 的决定下发到 iptables/nftables
    log "正在安装 Firewall Bouncer (iptables 联动)..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-firewall-bouncer-iptables; then
        ok "防火墙联动组件 (Bouncer) 安装成功"
    else
        warn "Bouncer 安装失败，CrowdSec 将只能记录日志而无法自动拦截"
    fi

    # 清理
    rm -f "$local_script"
    return 0
}

# 主程序
main() {
    [[ "$EUID" -ne 0 ]] && { err "必须使用 root 权限运行"; exit 1; }

    echo -e "${C_CYAN}开始部署 CrowdSec 全家桶 (Engine + Firewall Bouncer)...${C_RESET}"
    
    if run_crowdsec_setup; then
        echo -e "\n${C_GRAY}================================================${C_RESET}"
        ok "部署顺利完成！"
        log "常用命令清单："
        echo -e "  - 查看服务状态: ${C_YELLOW}cscli status${C_RESET}"
        echo -e "  - 查看被封禁IP: ${C_YELLOW}cscli decisions list${C_RESET}"
        echo -e "  - 手动封禁一个IP: ${C_YELLOW}cscli decisions add -i 1.2.3.4${C_RESET}"
        echo -e "  - 查看已安装插件: ${C_YELLOW}cscli hub list${C_RESET}"
        echo -e "${C_GRAY}================================================${C_RESET}"
    else
        err "部署过程中出现错误，请检查日志。"
        exit 1
    fi
}

main