#!/usr/bin/env bash
set -euo pipefail

# 01. Create user + SSH hardening (Full Robust Version with Y/N)

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行：sudo $0"; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_systemd() { [[ -d /run/systemd/system ]] && have_cmd systemctl; }

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

USER_NAME=""
USER_SHELL="/bin/bash"
WANT_SUDO="false"
DISABLE_ROOT_PW="false"

# 解析参数 (保持脚本仍支持命令行静默执行)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2;;
    --shell) USER_SHELL="${2:-}"; shift 2;;
    --sudo) WANT_SUDO="true"; shift 1;;
    --disable-root-password-login) DISABLE_ROOT_PW="true"; shift 1;;
    --help|-h) echo "Usage: sudo $0 --user <name>"; exit 0;;
    *) err "未知参数：$1"; exit 1;;
  esac
done

detect_sudo_group() {
  if getent group sudo >/dev/null 2>&1; then echo "sudo"
  elif getent group wheel >/dev/null 2>&1; then echo "wheel"
  else
    if have_cmd groupadd; then
      groupadd -f sudo >/dev/null 2>&1 || true
      getent group sudo >/dev/null 2>&1 && echo "sudo" || echo ""
    fi
  fi
}

create_user_if_needed() {
  local u="$1" sh="$2"
  if id "$u" >/dev/null 2>&1; then
    ok "用户已存在：$u"
    return 0
  fi

  if ! confirm "确定要创建用户 '$u' 吗？"; then
    warn "跳过用户创建。"
    return 1
  fi

  if have_cmd useradd; then
    useradd -m -s "$sh" "$u"
  elif have_cmd adduser; then
    if adduser --help 2>/dev/null | grep -q -- '--disabled-password'; then
      adduser --disabled-password --gecos "" --shell "$sh" "$u"
    else
      adduser "$u"
      usermod -s "$sh" "$u" >/dev/null 2>&1 || true
    fi
  else
    err "系统缺少 useradd/adduser"; return 1
  fi
  ok "已创建用户：$u"
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak.$(date +%s)"
}

ensure_sshd_root_pw_disabled() {
  warn "即将修改 SSH 配置：禁止 Root 密码登录 (prohibit-password)。"
  if ! confirm "确认继续？" "N"; then
    warn "已取消 SSH 加固。"
    return 0
  fi

  local dropdir="/etc/ssh/sshd_config.d"
  local dropfile="${dropdir}/99-hardening.conf"

  if [[ -d "$dropdir" || -w /etc/ssh ]]; then
    mkdir -p "$dropdir"
    backup_file "$dropfile"
    echo -e "# Managed by script\nPermitRootLogin prohibit-password\nPasswordAuthentication yes" > "$dropfile"
    ok "已写入 drop-in 配置：$dropfile"
  else
    local main="/etc/ssh/sshd_config"
    [[ -f "$main" ]] || { err "找不到 $main"; return 1; }
    backup_file "$main"
    sed -i -E '/^\s*#?\s*PermitRootLogin\s+/d' "$main"
    echo -e "\n# Managed by script\nPermitRootLogin prohibit-password" >> "$main"
    ok "已更新主配置：$main"
  fi

  # 鲁棒性：校验配置
  if have_cmd sshd && ! sshd -t; then
    err "SSH 配置校验失败！请检查配置或恢复备份。"
    return 1
  fi

  # 鲁棒性：多服务管理兼容
  if confirm "是否现在重启 SSH 服务以生效？"; then
    if have_systemd; then
      systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    elif have_cmd service; then
      service ssh reload >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1 || true
    fi
    ok "SSH 服务已尝试重载"
  fi
}

main() {
  need_root

  # 交互补全参数
  [[ -z "$USER_NAME" ]] && USER_NAME=$(prompt_with_default "请输入要创建/操作的用户名" "admin")
  
  # 执行用户创建
  create_user_if_needed "$USER_NAME" "$USER_SHELL"

  # 交互询问 Sudo
  if [[ "$WANT_SUDO" == "false" ]]; then
    confirm "是否赋予用户 '$USER_NAME' Sudo 权限？" && WANT_SUDO="true"
  fi

  if [[ "$WANT_SUDO" == "true" ]]; then
    local g=$(detect_sudo_group)
    if [[ -n "$g" ]]; then
      usermod -aG "$g" "$USER_NAME" && ok "已加入 $g 组"
    else
      warn "未找到 sudo/wheel 组，无法自动授权。"
    fi
  fi

  # 交互询问 Root 加固
  if [[ "$DISABLE_ROOT_PW" == "false" ]]; then
    confirm "是否禁止 Root 密码登录（推荐）？" "N" && DISABLE_ROOT_PW="true"
  fi

  [[ "$DISABLE_ROOT_PW" == "true" ]] && ensure_sshd_root_pw_disabled

  # 鲁棒性：展示最终状态
  echo -e "\n${C_CYAN}---------- 状态汇总 ----------${C_RESET}"
  id "$USER_NAME" || true
  [[ "$DISABLE_ROOT_PW" == "true" ]] && (sshd -T | grep -i "permitrootlogin") || true
  ok "全部流程执行完毕"
}

main