#!/usr/bin/env bash
# =================================================================
# VPSKit Module: base/system.sh
# Description: 智能设置时区与主机名 (兼容 VPS 与 Container)
# =================================================================
set -Eeuo pipefail

C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_RESET="\033[0m"

info() { echo -e "${C_GREEN}>>> $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }

# --- 1. 获取当前时区的健壮方法 ---
get_current_tz() {
    # 优先使用 timedatectl
    if command -v timedatectl >/dev/null 2>&1; then
        local tz
        tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
        [[ -n "$tz" ]] && { echo "$tz"; return; }
    fi

    # 其次尝试读取 /etc/timezone
    if [[ -f /etc/timezone ]]; then
        cat /etc/timezone
        return
    fi

    # 最后尝试解析 /etc/localtime 软链接
    if [[ -L /etc/localtime ]]; then
        readlink /etc/localtime | sed 's#^.*/zoneinfo/##'
        return
    fi

    echo "Etc/UTC" # 默认回退
}

# --- 2. 主机名检查与设置 ---
setup_hostname() {
    local current_hostname
    current_hostname=$(hostname)

    if [[ "$current_hostname" =~ ^[a-zA-Z0-9-]+$ ]] && [[ "$current_hostname" != "localhost" ]]; then
        info "当前主机名 [$current_hostname] 合规，无需修改。"
    else
        warn "检测到主机名异常或为默认值: $current_hostname"
        # 容器环境下 hostnamectl 必失败，我们只在有该命令且非容器时运行
        if command -v hostnamectl >/dev/null 2>&1 && [[ ! -f /.dockerenv ]]; then
            read -r -p "请输入新的主机名: " new_hostname </dev/tty
            if [[ -n "$new_hostname" ]]; then
                hostnamectl set-hostname "$new_hostname" || warn "hostnamectl 设置失败"
                sed -i "s/127.0.1.1.*/127.0.1.1 $new_hostname/g" /etc/hosts || true
                info "主机名已更新为: $new_hostname"
            fi
        else
            warn "当前环境不支持修改主机名 (可能是容器)，跳过。"
        fi
    fi
}

# --- 3. 时区检查与设置 ---
setup_timezone() {
    local target_tz="Asia/Shanghai"
    local current_tz
    current_tz=$(get_current_tz)

    if [[ "$current_tz" == "$target_tz" ]]; then
        info "当前时区已是 $target_tz，无需修改。"
    else
        info "正在调整时区: $current_tz -> $target_tz"
        
        # 兼容性设置方法
        if command -v timedatectl >/dev/null 2>&1; then
            timedatectl set-timezone "$target_tz" 2>/dev/null || true
        fi
        
        # 传统的软链接方法 (对容器最有效)
        if [[ -f "/usr/share/zoneinfo/$target_tz" ]]; then
            ln -sf "/usr/share/zoneinfo/$target_tz" /etc/localtime
            echo "$target_tz" > /etc/timezone
            info "时区设置完成: $(date)"
        else
            warn "未找到时区文件 /usr/share/zoneinfo/$target_tz，可能需要安装 tzdata"
        fi
    fi
}

# --- 4. 时间同步 ---
ensure_ntp() {
    if command -v timedatectl >/dev/null 2>&1 && [[ ! -f /.dockerenv ]]; then
        timedatectl set-ntp true || true
        info "已激活 NTP 自动时间同步。"
    else
        warn "当前环境不支持 timedatectl NTP 设置，跳过。"
    fi
}

main() {
    [[ "$(id -u)" -eq 0 ]] || { echo "❌ 必须以 root 权限运行"; exit 1; }
    setup_hostname
    setup_timezone
    ensure_ntp
    echo -e "\n${C_GREEN}系统环境配置检查完毕！${C_RESET}"
}

main