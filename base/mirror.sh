#!/usr/bin/env bash
# =================================================================
# VPSKit Module: base/mirror.sh
# Description: 智能识别发行版并更换最快的软件源 (支持备份与回滚)
# =================================================================
set -Eeuo pipefail

# --- 1. 基础环境检查 ---
[[ "$(id -u)" -eq 0 ]] || { echo "❌ 必须以 root 权限运行"; exit 1; }

# 定义颜色
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_RESET="\033[0m"

info() { echo -e "${C_GREEN}>>> $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
die()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; exit 1; }

# --- 2. 识别操作系统 ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    die "无法识别操作系统类型"
fi

# --- 3. 备份逻辑 (增强兼容性) ---
backup_sources() {
    local source_files=()
    
    # 针对 Debian/Ubuntu 的多种可能路径
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        [[ -f /etc/apt/sources.list ]] && source_files+=("/etc/apt/sources.list")
        [[ -d /etc/apt/sources.list.d ]] && source_files+=("/etc/apt/sources.list.d")
    elif [[ "$OS" =~ ^(centos|rocky|almalinux)$ ]]; then
        [[ -d /etc/yum.repos.d ]] && source_files+=("/etc/yum.repos.d")
    fi

    if [[ ${#source_files[@]} -eq 0 ]]; then
        warn "未发现任何已知的源文件，跳过备份。"
        return 0
    fi

    local ts; ts=$(date +%Y%m%d%H%M)
    for f in "${source_files[@]}"; do
        info "正在备份原始源: $f -> ${f}.bak.${ts}"
        cp -rf "$f" "${f}.bak.${ts}"
    done
}

# --- 4. 连通性测试 (智能选源) ---
# 测试延迟，选择最适合当前 VPS 的源 (境内/境外)
select_mirror() {
    info "正在检测网络环境..."
    # 尝试访问 Google 判定是否为中国境内服务器
    if curl -o /dev/null -s -m 3 --connect-timeout 2 http://www.google.com; then
        echo "global"
    else
        echo "china"
    fi
}

# --- 5. 执行更新逻辑 ---
update_apt_sources() {
    local region=$1
    info "正在为 $OS ($VER) 配置 $region 软件源..."

    # 定义要搜索和替换的域名
    local old_mirror="deb.debian.org"
    local new_mirror="mirrors.ustc.edu.cn"

    if [[ "$region" == "global" ]]; then
        # 如果是全球环境，反向替换回来
        local temp=$old_mirror
        old_mirror=$new_mirror
        new_mirror=$temp
    fi

    # 重点：同时处理 sources.list 文件和 sources.list.d 目录下的所有 .list 和 .sources 文件
    local targets=("/etc/apt/sources.list")
    [[ -d /etc/apt/sources.list.d ]] && targets+=("/etc/apt/sources.list.d/"*)

    for target in "${targets[@]}"; do
        if [[ -f "$target" ]]; then
            sed -i "s|$old_mirror|$new_mirror|g" "$target" || true
        fi
    done
}

# --- 主流程 ---
main() {
    backup_sources
    
    local env; env=$(select_mirror)
    
    case "$OS" in
        ubuntu|debian)
            update_apt_sources "$env"
            info "正在同步软件包索引..."
            apt-get update -y || warn "apt update 失败，请检查网络"
            ;;
        centos|rocky|almalinux)
            info "清理缓存..."
            yum clean all && yum makecache
            ;;
        *)
            die "暂不支持自动处理 $OS"
            ;;
    esac

    info "软件源更新任务完成！"
}

main