#!/usr/bin/env bash
set -euo pipefail

# 03. Configure passwordless sudo (Interactive + Safety checks)

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_GRAY="\033[90m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行：sudo $0"; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

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
  read -r -p "${prompt} (直接回车为: ${def}): " out || true
  out="${out:-$def}"
  echo "$out"
}

USER_NAME=""
COMMANDS=""
REVOKE="false"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:-}"; shift 2;;
    --commands) COMMANDS="${2:-}"; shift 2;;
    --revoke) REVOKE="true"; shift 1;;
    --help|-h) echo "Usage: sudo $0 --user <name>"; exit 0;;
    *) err "未知参数：$1"; exit 1;;
  esac
done

validate_with_visudo() {
  local f="$1"
  if have_cmd visudo; then
    visudo -cf "$f" >/dev/null 2>&1
  else
    warn "缺少 visudo，跳过语法校验。"
    return 0
  fi
}

main() {
  need_root

  # --- 1. 获取用户名 ---
  if [[ -z "$USER_NAME" ]]; then
    echo -e "${C_CYAN}未指定目标用户。${C_RESET}"
    USER_NAME=$(prompt_with_default "请输入要配置免密 sudo 的用户名" "$(whoami)")
  fi

  # 检查用户是否存在
  id "$USER_NAME" >/dev/null 2>&1 || { err "用户 '$USER_NAME' 不存在，请先创建用户。"; exit 1; }

  local sudoers_file="/etc/sudoers.d/90-${USER_NAME}-nopasswd"

  # --- 2. 撤销逻辑 ---
  if [[ "$REVOKE" == "true" ]]; then
    if [[ -f "$sudoers_file" ]]; then
      if confirm "确定要撤销用户 '$USER_NAME' 的免密配置吗？"; then
        rm -f "$sudoers_file"
        ok "已撤销并删除：$sudoers_file"
      fi
    else
      ok "未发现对应的配置文件，无需撤销。"
    fi
    exit 0
  fi

  # --- 3. 配置命令权限 ---
  if [[ -z "$COMMANDS" ]]; then
    echo -e "\n${C_CYAN}权限范围配置：${C_RESET}"
    echo "1. 全部命令 (ALL)"
    echo "2. 指定命令 (例如: /usr/bin/docker,/usr/bin/systemctl)"
    local choice
    choice=$(prompt_with_default "选择权限类型 [1/2]" "1")
    
    if [[ "$choice" == "2" ]]; then
      COMMANDS=$(prompt_with_default "输入命令列表 (逗号分隔全路径)" "/usr/bin/docker")
    fi
  fi

  # 构建规则字符串
  local rule
  if [[ -n "$COMMANDS" ]]; then
    local cmdlist
    cmdlist=$(echo "$COMMANDS" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF{printf "%s, ", $0}' | sed 's/, $//')
    rule="${USER_NAME} ALL=(ALL:ALL) NOPASSWD: ${cmdlist}"
  else
    rule="${USER_NAME} ALL=(ALL:ALL) NOPASSWD: ALL"
  fi

  # --- 4. 写入与校验 ---
  echo -e "\n即将应用规则: ${C_YELLOW}$rule${C_RESET}"
  if ! confirm "确认写入该配置到 sudoers.d？"; then
    warn "操作取消。"
    exit 0
  fi

  mkdir -p /etc/sudoers.d
  chmod 750 /etc/sudoers.d

  local tmp
  tmp=$(mktemp)
  echo "# Managed by script: passwordless sudo" > "$tmp"
  echo "$rule" >> "$tmp"
  chmod 440 "$tmp"

  if validate_with_visudo "$tmp"; then
    cp -f "$tmp" "$sudoers_file"
    chmod 440 "$sudoers_file"
    ok "配置已成功应用：$sudoers_file"
  else
    err "visudo 校验失败！配置语法可能有误，已拦截写入以防 sudo 损坏。"
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"

  echo -e "\n${C_GRAY}测试建议：${C_RESET}"
  echo "使用以下命令验证：su - ${USER_NAME} -c 'sudo -n true && echo 成功 || echo 失败'"
}

main