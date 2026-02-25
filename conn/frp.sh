#!/usr/bin/env bash
# =================================================================
# VPSKit Module: conn/frp.sh
# Description: 自动化安装 Frp 客户端 (frpc) 并配置 Systemd 守护
# =================================================================
set -Eeuo pipefail

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*" >&2; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

# --- 变量定义 ---
FRP_VERSION="" # 留空则自动获取最新
INSTALL_DIR="/usr/local/frp"
BIN_PATH="/usr/local/bin/frpc"
CONF_PATH="/etc/frp/frpc.toml"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# --- 1. 架构识别与版本获取 ---
detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7*)  echo "arm"   ;;
        *)       err "不支持的架构: $arch"; exit 1 ;;
    esac
}

get_latest_version() {
    log "正在从 GitHub 获取最新版本号..."
    local ver; ver=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [[ -n "$ver" ]] || { err "获取版本号失败，请检查网络"; exit 1; }
    echo "$ver"
}

# --- 2. 安装逻辑 ---
install_frpc() {
    if have_cmd frpc; then
        ok "Frpc 已存在: $(frpc -v)"
        return 0
    fi

    local version; version=$(get_latest_version)
    local arch; arch=$(detect_arch)
    local filename="frp_${version}_linux_${arch}"
    local url="https://github.com/fatedier/frp/releases/download/v${version}/${filename}.tar.gz"

    log "准备安装 Frpc v${version} ($arch)..."
    
    local tmp_dir; tmp_dir=$(mktemp -d)
    curl -fSL "$url" -o "${tmp_dir}/frp.tar.gz"
    tar -xzf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir"
    
    # 安装二进制文件
    mv "${tmp_dir}/${filename}/frpc" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    
    # 准备配置目录
    mkdir -p /etc/frp
    if [[ ! -f "$CONF_PATH" ]]; then
        mv "${tmp_dir}/${filename}/frpc.toml" "$CONF_PATH"
        warn "已生成默认配置文件: $CONF_PATH"
    fi

    rm -rf "$tmp_dir"
    ok "Frpc 二进制文件安装完成"
}

# --- 3. 服务守护 (Systemd) ---
setup_systemd() {
    # 检查是否存在 systemctl 命令
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "检测到当前环境不支持 Systemd (可能是容器)，跳过服务配置。"
        return 0
    fi

    log "配置 Systemd 服务守护..."
    cat <<EOF > /etc/systemd/system/frpc.service
[Unit]
Description=Frp Client Service
After=network.target syslog.target

[Service]
Type=simple
User=root
ExecStart=$BIN_PATH -c $CONF_PATH
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable frpc >/dev/null 2>&1 || true
    ok "Systemd 服务已注册 (frpc.service)"
}

# --- 4. 交互式配置提示 ---
configure_prompt() {
    echo -e "\n${C_YELLOW}--- Frpc 配置提示 ---${C_RESET}"
    echo "1. 保持默认配置 (稍后手动编辑 /etc/frp/frpc.toml)"
    echo "2. 立即启动服务 (前提是已配置好服务器信息)"
    read -r -p "选择 [1/2]: " opt
    
    if [[ "$opt" == "2" ]]; then
        systemctl start frpc && ok "Frpc 服务已启动" || warn "启动失败，请检查配置文件"
    fi
}

# --- 主流程 ---
main() {
    need_root
    
    # 检查依赖
    have_cmd curl || { err "缺少 curl，请先运行常用软件包安装"; exit 1; }
    have_cmd tar || { err "缺少 tar"; exit 1; }

    install_frpc
    setup_systemd
    configure_prompt

    echo
    log "配置路径: $CONF_PATH"
    log "管理命令: systemctl [start|stop|restart|status] frpc"
    ok "Frp 穿透客户端安装任务完成"
}

main