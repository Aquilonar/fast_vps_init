#!/usr/bin/env bash
set -euo pipefail

# 02. Tailscale install + optional tailscale up
# Usage:
#   sudo ./02_tailscale_install.sh
#   sudo ./02_tailscale_install.sh --auto-up --authkey "tskey-xxxxx" --hostname myvps --ssh

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行：sudo $0"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
have_systemd(){ [[ -d /run/systemd/system ]] && have_cmd systemctl; }

AUTO_UP="false"
AUTHKEY=""
HOSTNAME=""
ENABLE_SSH="false"

usage() {
  cat <<'EOF'
Usage:
  (no args)                      只安装 tailscale
  --auto-up                      安装后自动 tailscale up（非交互）
  --authkey <tskey-...>          (与 --auto-up 配合) 使用 authkey 自动登录
  --hostname <name>              (可选) 设置 tailscale hostname
  --ssh                          (可选) tailscale up --ssh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-up) AUTO_UP="true"; shift 1;;
    --authkey) AUTHKEY="${2:-}"; shift 2;;
    --hostname) HOSTNAME="${2:-}"; shift 2;;
    --ssh) ENABLE_SSH="true"; shift 1;;
    --help|-h) usage; exit 0;;
    *) err "未知参数：$1"; usage; exit 1;;
  esac
done

detect_pkg_mgr() {
  if have_cmd apt-get; then echo "apt"
  elif have_cmd dnf; then echo "dnf"
  elif have_cmd yum; then echo "yum"
  elif have_cmd pacman; then echo "pacman"
  else echo ""
  fi
}

install_tailscale() {
  if have_cmd tailscale; then
    ok "Tailscale 已安装（跳过安装）"
    return 0
  fi

  warn "开始安装 Tailscale..."
  case "$(detect_pkg_mgr)" in
    apt)
      apt-get update -y >/dev/null
      apt-get install -y curl ca-certificates >/dev/null
      curl -fsSL https://tailscale.com/install.sh | sh
      ;;
    dnf|yum)
      curl -fsSL https://tailscale.com/install.sh | sh
      ;;
    pacman)
      pacman -Sy --noconfirm tailscale >/dev/null
      ;;
    *)
      err "无法识别包管理器，无法自动安装 Tailscale"
      exit 1
      ;;
  esac

  ok "Tailscale 安装完成"
}

enable_service() {
  if have_systemd && systemctl status >/dev/null 2>&1; then
    systemctl enable --now tailscaled >/dev/null 2>&1 || true
    ok "tailscaled 已通过 systemd 启动"
  else
    log "检测到容器或非 systemd 环境，正在手动后台启动 tailscaled..."
    # 容器内必须使用 userspace 模式，否则没有网卡权限会报错
    nohup tailscaled --tun=userspace-networking >/dev/null 2>&1 &
    sleep 3 # 给守护进程一点启动时间
    ok "tailscaled 已在后台运行"
  fi
}

do_up() {
  local args=(tailscale up)
  [[ -n "$AUTHKEY" ]] && args+=(--authkey "$AUTHKEY")
  [[ -n "$HOSTNAME" ]] && args+=(--hostname "$HOSTNAME")
  [[ "$ENABLE_SSH" == "true" ]] && args+=(--ssh)

  log "执行：${args[*]}"
  "${args[@]}"
}

show_status() {
  echo -e "\n${C_YELLOW}---------- Tailscale 运行状态 ----------${C_RESET}"
  
  # 获取登录链接并加颜色
  # 如果没登录，tailscale status 会输出登录 URL
  local status_output; status_output=$(tailscale status 2>&1 || true)
  
  if echo "$status_output" | grep -q "http"; then
    warn "检测到尚未登录，请点击下方链接授权："
    # 使用正则把 URL 找出来并加上高亮颜色
    echo -e "$status_output" | sed "s|https://[^ ]*|${C_GREEN}&${C_RESET}|g"
  else
    echo "$status_output"
  fi

  echo -e "${C_YELLOW}---------- Tailscale IP 地址 ----------${C_RESET}"
  local ts_ip; ts_ip=$(tailscale ip -4 2>/dev/null || echo "未分配 IP")
  echo -e "Internal IP: ${C_GREEN}$ts_ip${C_RESET}"
  echo -e "${C_YELLOW}---------------------------------------${C_RESET}"
}

main() {
  need_root
  install_tailscale
  enable_service

  if [[ "$AUTO_UP" == "true" ]]; then
    [[ -n "$AUTHKEY" ]] || { err "--auto-up 需要提供 --authkey"; exit 1; }
    do_up
  else
    echo -e "\n${C_CYAN}正在请求登录链接...${C_RESET}"
    # 核心：即使不带参数，执行一次 up 也会触发链接生成
    tailscale up --accept-dns=false >/tmp/ts_up.log 2>&1 & 
    sleep 2
  fi

  # 放在最后重复显示
  show_status
  
  echo -e "\n${C_GREEN}✅ 部署任务已完成！${C_RESET}"
  if [[ ! -f /.dockerenv ]]; then
     log "管理命令: systemctl status tailscaled"
  fi
}

main