#!/usr/bin/env bash
set -euo pipefail

# 01. Docker + Compose + create a common network (Robust + Interactive)

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行：sudo $0"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# 通用确认函数
confirm(){
  local msg="$1"
  local default="${2:-Y}"
  read -r -p "${msg} [Y/n] " ans || true
  ans="${ans:-$default}"
  [[ "${ans^^}" == "Y" ]]
}

# 带有默认值的输入函数
prompt_with_default(){
  local prompt="$1"
  local def="$2"
  local out
  read -r -p "${prompt} (默认: ${def}): " out || true
  out="${out:-$def}"
  echo "$out"
}

NET_NAME="common"
SUBNET=""
GATEWAY=""

# 处理参数（保持命令行支持，方便脚本调用）
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NET_NAME="${2:-}"; shift 2;;
    --subnet) SUBNET="${2:-}"; shift 2;;
    --gateway) GATEWAY="${2:-}"; shift 2;;
    --help|-h) echo "Usage: sudo $0 --network common --subnet 172.30.0.0/16"; exit 0;;
    *) err "未知参数：$1"; exit 1;;
  esac
done

detect_pkg_mgr() {
  if have_cmd apt-get; then echo "apt"
  elif have_cmd dnf; then echo "dnf"
  elif have_cmd yum; then echo "yum"
  elif have_cmd pacman; then echo "pacman"
  else echo ""; fi
}

# --- 鲁棒性安装逻辑 (保留原版全部逻辑) ---
install_docker() {
  case "$(detect_pkg_mgr)" in
    apt)
      log "Debian/Ubuntu：正在配置官方 Docker 源..."
      apt-get update -y >/dev/null && apt-get install -y ca-certificates curl gnupg >/dev/null
      set +e
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
      local distro="$(. /etc/os-release; echo "$ID")"
      local arch="$(dpkg --print-architecture)"
      local codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
      if [[ -z "$codename" ]]; then rc=1; else
        echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -y >/dev/null && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
        rc=$?; fi
      set -e
      if [[ $rc -ne 0 ]]; then
        warn "官方源安装失败，回退到系统源 docker.io"
        apt-get install -y docker.io docker-compose >/dev/null; fi ;;
    dnf|yum)
      log "RHEL/CentOS：尝试安装 Docker..."
      local mgr=$(detect_pkg_mgr)
      $mgr install -y docker docker-compose-plugin >/dev/null 2>&1 || \
      $mgr install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 || true ;;
    pacman)
      log "Arch：安装 Docker..."
      pacman -Sy --noconfirm docker docker-compose >/dev/null ;;
    *) err "不支持的包管理器，请手动安装 Docker"; exit 1 ;;
  esac
}

ensure_docker_running() {
  log "启动 Docker 服务..."
  if have_cmd systemctl; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    service docker start >/dev/null 2>&1 || true
  fi
  docker info >/dev/null 2>&1 || { err "Docker 启动失败，请检查日志"; exit 1; }
  ok "Docker 运行正常"
}

main() {
  need_root

  # --- 1. Docker 安装确认 ---
  if have_cmd docker; then
    ok "Docker 已安装。"
  else
    if confirm "未检测到 Docker，是否现在开始安装？"; then
      install_docker
      ensure_docker_running
    else
      warn "跳过 Docker 安装，后续网络创建可能会失败。"
    fi
  fi

  # --- 2. 交互式网络配置 ---
  echo -e "\n${C_CYAN}Docker 容器网络配置：${C_RESET}"
  NET_NAME=$(prompt_with_default "请输入 Docker 网络名称" "$NET_NAME")
  
  if [[ -z "$SUBNET" ]]; then
    if confirm "是否需要为网络 '$NET_NAME' 指定固定子网 (Subnet)？" "N"; then
      SUBNET=$(prompt_with_default "请输入子网 CIDR" "172.30.0.0/16")
      GATEWAY=$(prompt_with_default "请输入网关 IP (可选，可直接回车)" "")
    fi
  fi

  # --- 3. 创建网络逻辑 (鲁棒性校验) ---
  if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
    ok "网络 '$NET_NAME' 已存在。"
  else
    log "正在创建 Docker 网络: $NET_NAME ..."
    local args=(network create "$NET_NAME" --driver bridge)
    [[ -n "$SUBNET" ]] && args+=(--subnet "$SUBNET")
    [[ -n "$GATEWAY" ]] && args+=(--gateway "$GATEWAY")
    
    if docker "${args[@]}" >/dev/null; then
      ok "网络创建成功。"
    else
      err "网络创建失败，请检查子网是否被占用。"
    fi
  fi

  # --- 4. 状态总结 ---
  echo -e "\n${C_CYAN}---------- Docker 状态汇总 ----------${C_RESET}"
  docker --version || true
  docker compose version 2>/dev/null || docker-compose version 2>/dev/null || warn "Compose 未安装"
  echo -e "网络详情:"
  docker network ls | grep "$NET_NAME" || true
  echo -e "${C_CYAN}------------------------------------${C_RESET}"
  
  ok "配置完成！"
}

main