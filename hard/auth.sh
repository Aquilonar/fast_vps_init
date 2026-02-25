#!/usr/bin/env bash
# =================================================================
# VPSKit Module: hard/auth.sh
# Description: 安全加固 - 禁用 SSH 密码登录（带强提示与前置检查）
# =================================================================
set -Eeuo pipefail

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_GRAY="\033[90m"; C_CYAN="\033[1;36m"
log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

# --- 1. 基础检查函数 ---
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "请用 root 执行"; exit 1; }; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# 强健壮性：确认提示函数
confirm() {
    local prompt="$1"
    read -r -p "$(echo -e "${C_YELLOW}${prompt} [y/N]: ${C_RESET}")" input
    case "$input" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 2. SSH 环境预检 ---
check_ssh_env() {
    log "正在检查 SSH 环境..."
    
    # 检查是否安装了 SSH
    if ! have_cmd sshd; then
        err "未检测到 sshd 命令，系统可能未安装 SSH 服务。"
        exit 1
    fi

    # 核心安全检查：检查是否有已授权的 Key
    local auth_keys="$HOME/.ssh/authorized_keys"
    if [[ ! -f "$auth_keys" ]] || [[ ! -s "$auth_keys" ]]; then
        warn "检测到当前用户 ($USER) 似乎没有配置公钥 (authorized_keys 为空)。"
        warn "如果禁用密码登录，你可能会丢失连接！"
        if ! confirm "确定要继续吗？（建议先执行 SSH Key 注入）"; then
            ok "操作已取消。"
            exit 0
        fi
    fi
}

# --- 3. 写入配置 ---
write_dropin(){
    local dir="/etc/ssh/sshd_config.d"
    local file="${dir}/20-auth-hardening.conf"
    
    # 只有当用户确认后才操作
    if ! confirm "是否要创建 SSH 加固配置 (禁用密码登录)?"; then
        return 1
    fi

    mkdir -p "$dir"
    
    local config_content="PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes"

    if confirm "是否同时禁止 Root 用户通过密码登录 (PermitRootLogin prohibit-password)?"; then
        config_content="${config_content}\nPermitRootLogin prohibit-password"
    fi

    echo -e "# Managed by VPSKit: disable password auth\n${config_content}" > "$file"
    ok "配置文件已写入: $file"
}

# --- 4. 服务重载与验证 ---
test_and_reload(){
    log "正在校验 SSH 配置语法..."
    if ! sshd -t; then
        err "SSH 配置语法错误，正在撤销更改..."
        rm -f "/etc/ssh/sshd_config.d/20-auth-hardening.conf"
        exit 1
    fi

    if confirm "配置校验通过，是否立即重载 SSH 服务使设置生效?"; then
        if have_cmd systemctl; then
            systemctl reload ssh || systemctl reload sshd || systemctl restart sshd
        else
            service sshd reload || service sshd restart
        fi
        ok "SSH 服务已尝试重载。"
    else
        warn "已跳过服务重载，配置将在下次手动重启后生效。"
    fi
}

# --- 5. 状态展示 ---
show_status(){
    echo -e "\n${C_CYAN}--- SSH 当前生效参数 (sshd -T) ---${C_RESET}"
    sshd -T 2>/dev/null | grep -E 'passwordauthentication|permitrootlogin|kbdinteractiveauthentication' | sed 's/^/  /' || true
    echo -e "${C_CYAN}----------------------------------${C_RESET}"
}

# --- 主流程 ---
main(){
    need_root
    
    echo -e "${C_CYAN}==========================================${C_RESET}"
    echo -e "         SSH 安全加固: 禁用密码登录"
    echo -e "${C_CYAN}==========================================${C_RESET}"
    
    check_ssh_env
    
    if write_dropin; then
        test_and_reload
        show_status
        ok "任务执行完毕。"
        warn "⚠️  警告：请保持当前 SSH 会话不要关闭！"
        warn "⚠️  请务必另开一个终端尝试连接，确认 Key 登录正常后再退出当前窗口。"
    else
        ok "用户取消了操作。"
    fi
}

main