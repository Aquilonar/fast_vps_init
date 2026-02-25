#!/usr/bin/env bash
set -euo pipefail

# 01. Change SSH port (Interactive + Y/N prompts)

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

# 带有默认值的输入函数
prompt_with_default(){
  local prompt="$1"
  local def="$2"
  local out
  read -r -p "${prompt} (默认: ${def}): " out || true
  out="${out:-$def}"
  echo "$out"
}

NEW_PORT=""
ALLOW_UFW="false"
KEEP_OLD="false"

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) NEW_PORT="${2:-}"; shift 2;;
    --also-allow-ufw) ALLOW_UFW="true"; shift 1;;
    --keep-old-port) KEEP_OLD="true"; shift 1;;
    --help|-h) echo "Usage: sudo $0 --port 2222"; exit 0;;
    *) err "未知参数：$1"; exit 1;;
  esac
done

validate_port(){
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

backup_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.$(date +%s)"
}

main(){
  need_root

  # --- 交互提示阶段 ---
  
  # 1. 如果没指定端口，则询问
  if [[ -z "$NEW_PORT" ]]; then
    echo -e "${C_CYAN}未指定端口参数。${C_RESET}"
    NEW_PORT=$(prompt_with_default "请输入新的 SSH 端口" "2222")
  fi

  if ! validate_port "$NEW_PORT"; then
    err "端口非法：$NEW_PORT (必须是 1-65535)"; exit 1
  fi

  # 2. 确认是否放行 UFW
  if [[ "$ALLOW_UFW" == "false" ]] && have_cmd ufw; then
    if confirm "检测到系统安装了 UFW，是否自动放行新端口 $NEW_PORT？"; then
      ALLOW_UFW="true"
    fi
  fi

  # 3. 确认是否移除旧端口
  if [[ "$KEEP_OLD" == "false" ]]; then
    if ! confirm "是否从主配置文件移除旧端口配置（推荐，防止端口冲突）？"; then
      KEEP_OLD="true"
    fi
  fi

  # --- 执行阶段 ---

  local mainf="/etc/ssh/sshd_config"
  [[ -f "$mainf" ]] || { err "找不到 $mainf"; exit 1; }

  # 移除旧端口配置
  if [[ "$KEEP_OLD" == "false" ]]; then
    backup_file "$mainf"
    sed -i -E '/^\s*#?\s*Port\s+[0-9]+\s*$/d' "$mainf"
    ok "已清理主配置中的旧 Port 行"
  fi

  # 写入新配置 (Drop-in 模式)
  local dropin_dir="/etc/ssh/sshd_config.d"
  mkdir -p "$dropin_dir"
  local dropin_file="${dropin_dir}/10-port.conf"
  backup_file "$dropin_file"
  echo "Port $NEW_PORT" > "$dropin_file"
  ok "新端口 $NEW_PORT 已写入 $dropin_file"

  # 校验配置
  if have_cmd sshd && ! sshd -t; then
    err "sshd -t 校验失败！配置有误，正在尝试回滚..."
    # 简单的回滚逻辑
    rm -f "$dropin_file"
    exit 1
  fi

  # 防火墙
  if [[ "$ALLOW_UFW" == "true" ]] && have_cmd ufw; then
    ufw allow "${NEW_PORT}/tcp" >/dev/null
    ok "UFW 已放行端口 $NEW_PORT"
  fi

  # 重启服务
  if confirm "配置校验通过。是否现在重载 SSH 服务生效？"; then
    if have_systemd; then
      systemctl reload ssh || systemctl restart ssh || true
    else
      service ssh restart || true
    fi
    ok "服务已重载"
  else
    warn "已跳过服务重载，配置尚未生效。"
  fi

  # 状态展示
  echo -e "\n${C_CYAN}--- SSH 当前生效端口 ---${C_RESET}"
  sshd -T | grep -i "port" || true
  
  warn "\n重要：请保持当前连接，新开终端测试：ssh -p $NEW_PORT user@host"
}

main