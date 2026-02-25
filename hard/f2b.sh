#!/usr/bin/env bash
set -euo pipefail

# 04. Fail2ban install + configure (Enhanced with Y/N prompts)

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行：sudo $0"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }
have_systemd(){ [[ -d /run/systemd/system ]] && have_cmd systemctl; }

# 通用确认函数
confirm(){
  local msg="$1"
  local default="${2:-Y}"
  read -r -p "${msg} [Y/n] " ans || true
  ans="${ans:-$default}"
  [[ "${ans^^}" == "Y" ]]
}

SSH_PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-port) SSH_PORT="${2:-}"; shift 2;;
    --help|-h) echo "Usage: sudo $0 [--ssh-port 2222]"; exit 0;;
    *) err "未知参数：$1"; exit 1;;
  esac
done

install_fail2ban(){
  if have_cmd fail2ban-client; then
    ok "Fail2ban 已安装（跳过安装）"
    return 0
  fi
  
  if ! confirm "未检测到 Fail2ban，是否现在安装？"; then
    warn "跳过安装，脚本可能因缺少组件无法继续。"
    return 0
  fi

  warn "开始安装 Fail2ban..."
  if have_cmd apt-get; then
    apt-get update -y >/dev/null && apt-get install -y fail2ban >/dev/null
  elif have_cmd dnf; then
    dnf install -y fail2ban >/dev/null
  elif have_cmd yum; then
    yum install -y fail2ban >/dev/null
  else
    err "未知包管理器，请手动安装 fail2ban"
    exit 1
  fi
  ok "Fail2ban 已安装"
}

backup_file(){
  local f="$1"
  [[ -e "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%s)"
}

disable_old_configs_prompt(){
  echo -e "${C_CYAN}检查冲突的旧配置文件...${C_RESET}"
  local found="false"
  if [[ -f /etc/fail2ban/jail.local ]]; then found="true"; fi
  
  local others=""
  if [[ -d /etc/fail2ban/jail.d ]]; then
    others="$(find /etc/fail2ban/jail.d -maxdepth 1 -type f -name "*.local" 2>/dev/null | grep -v "/etc/fail2ban/jail.d/99-vpskit.local" || true)"
    [[ -n "$others" ]] && found="true"
  fi

  if [[ "$found" != "true" ]]; then
    ok "未发现冲突配置。"
    return 0
  fi

  warn "发现可能覆盖新策略的旧配置 (*.local)。"
  if confirm "是否屏蔽这些旧配置（改名为 *.disabled.TIMESTAMP）？"; then
    local ts="$(date +%s)"
    if [[ -f /etc/fail2ban/jail.local ]]; then
      mv -f /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.disabled.${ts}"
      ok "已屏蔽 jail.local"
    fi
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ "$f" == "/etc/fail2ban/jail.d/99-vpskit.local" ]] && continue
      mv -f "$f" "${f}.disabled.${ts}"
      ok "已屏蔽: $f"
    done <<< "$others"
  else
    warn "保留了旧配置，请注意可能的规则冲突。"
  fi
}

prompt_with_default(){
  local prompt="$1"
  local def="$2"
  local out
  read -r -p "${prompt} (默认: ${def}): " out || true
  out="${out:-$def}"
  echo "$out"
}

write_config(){
  if ! confirm "是否开始编写新配置文件 /etc/fail2ban/jail.d/99-vpskit.local？"; then
    warn "跳过配置编写。"
    return 0
  fi

  mkdir -p /etc/fail2ban/jail.d
  echo -e "${C_CYAN}--- 请输入配置参数 ---${C_RESET}"

  local bantime findtime maxretry backend ignoreip sshport mode
  bantime="$(prompt_with_default "bantime (封禁时长)" "1h")"
  findtime="$(prompt_with_default "findtime (统计窗口)" "10m")"
  maxretry="$(prompt_with_default "maxretry (重试次数)" "5")"
  backend="$(prompt_with_default "backend" "auto")"
  ignoreip="$(prompt_with_default "ignoreip (白名单)" "127.0.0.1/8 ::1")"
  sshport="${SSH_PORT:-$(prompt_with_default "SSH 端口" "22")}"
  
  local action="iptables-multiport"
  have_cmd nft && action="nftables-multiport"

  cat >"/etc/fail2ban/jail.d/99-vpskit.local" <<EOF
[DEFAULT]
backend = ${backend}
ignoreip = ${ignoreip}
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
banaction = ${action}

[sshd]
enabled = true
port = ${sshport}
EOF
  ok "配置文件已更新。"
}

enable_and_restart(){
  if ! confirm "是否现在重启 Fail2ban 服务以应用配置？"; then
    warn "请稍后手动重启服务。"
    return 0
  fi

  if have_systemd; then
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true
  else
    service fail2ban restart >/dev/null 2>&1 || true
  fi
  ok "服务已重启。"
}

main(){
  need_root
  install_fail2ban
  disable_old_configs_prompt
  write_config
  enable_and_restart
  
  echo -e "\n${C_CYAN}--- 当前状态 ---${C_RESET}"
  fail2ban-client status sshd || true
}

main