#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_GRAY="\033[90m"

ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }

# 子程序：下载并执行 BBR3 脚本
run_bbr3_setup() {
    local script_url="https://raw.githubusercontent.com/kejilion/sh/main/kejilion.sh"
    local local_script="$(pwd)/kejilion_setup.sh"
    
    log "正在检查环境依赖 (curl)..."
    if ! command -v curl >/dev/null 2>&1; then
        warn "未发现 curl，尝试安装..."
        (apt-get update && apt-get install -y curl) || (yum install -y curl) || { err "无法安装 curl，请手动处理"; return 1; }
    fi

    log "开始下载脚本 (带重试机制)..."
    # --retry 5: 重试5次; --connect-timeout 10: 连接超时10秒
    if ! curl -sL --retry 5 --connect-timeout 10 "$script_url" -o "$local_script"; then
        # 如果从 GitHub 下载失败，尝试 kejilion.sh 备用域名
        warn "主地址下载失败，尝试备用地址..."
        if ! curl -sL --retry 3 "http://kejilion.sh" -o "$local_script"; then
            err "脚本下载失败，请检查网络连接"
            return 1
        fi
    fi

    log "下载完成，准备执行 BBR3 配置..."
    
    # 鲁棒性关键：不直接使用 <(curl)，而是下载后本地执行
    # 这样即使网络在执行中途断开，脚本逻辑依然完整
    if [[ -f "$local_script" ]]; then
        chmod +x "$local_script"
        
        # 使用 bash 执行并传入 bbr3 参数
        # 这里使用 try-catch 逻辑
        if bash "$local_script" bbr3; then
            ok "BBR3 脚本执行成功"
        else
            err "BBR3 脚本执行过程中出现错误"
            rm -f "$local_script"
            return 1
        fi
    else
        err "脚本文件丢失"
        return 1
    fi

    # 清理现场
    rm -f "$local_script"
    return 0
}

log() {
    echo -e "\033[90m[$(date +'%H:%M:%S')]\033[0m $*"
}

# 主程序逻辑
main() {
    # 权限检查
    [[ "$EUID" -ne 0 ]] && { err "请使用 root 权限运行"; exit 1; }

    echo -e "${C_CYAN}即将开始配置 BBR3 加速...${C_RESET}"
    
    # 执行子程序
    if run_bbr3_setup; then
        ok "所有操作已完成。"
    else
        err "程序异常退出。"
        exit 1
    fi
}

main