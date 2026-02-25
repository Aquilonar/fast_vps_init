#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET="\033[0m"
C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_GRAY="\033[90m"

info(){ echo -e "${C_CYAN}>>> $*${C_RESET}"; }
warn(){ echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
ok(){ echo -e "${C_GREEN}✅ $*${C_RESET}"; }
err(){ echo -e "${C_RED}❌ $*${C_RESET}"; }

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
safe(){ # safe run: safe "title" cmd...
  local title="$1"; shift
  echo -e "${C_GRAY}--- ${title} ---${C_RESET}"
  ("$@" 2>/dev/null || true)
  echo
}

kv(){ printf "%-22s %s\n" "$1" "$2"; }

detect_os() {
  local id="unknown" ver="unknown" pretty="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-unknown}"
    ver="${VERSION_ID:-unknown}"
    pretty="${PRETTY_NAME:-unknown}"
  fi
  echo "$id|$ver|$pretty"
}

detect_virt() {
  local virt="unknown"
  if have_cmd systemd-detect-virt; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    [[ -z "$virt" ]] && virt="none"
  else
    if [[ -f /proc/1/environ ]] && grep -qaE 'container=' /proc/1/environ; then
      virt="container"
    else
      virt="unknown"
    fi
  fi
  echo "$virt"
}

get_public_ip() {
  # best-effort; no failure if blocked
  if have_cmd curl; then
    curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true
  elif have_cmd wget; then
    wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true
  fi
}

sshd_effective() {
  if have_cmd sshd; then
    sshd -T 2>/dev/null | awk '
      $1=="port" || $1=="passwordauthentication" || $1=="permitrootlogin" || $1=="kbdinteractiveauthentication" || $1=="challengeresponseauthentication" {print}
    ' || true
  else
    echo "(no sshd command)"
  fi
}

fail2ban_status() {
  if have_cmd fail2ban-client; then
    fail2ban-client status 2>/dev/null || true
    echo
    fail2ban-client status sshd 2>/dev/null || true
  else
    echo "(fail2ban not installed)"
  fi
}

ufw_status() {
  if have_cmd ufw; then
    ufw status verbose 2>/dev/null || true
  else
    echo "(ufw not installed)"
  fi
}

docker_status() {
  if have_cmd docker; then
    docker version 2>/dev/null | sed -n '1,25p' || true
    echo
    (docker compose version 2>/dev/null || true)
    echo
    docker info 2>/dev/null | awk '
      /Server Version:/ || /Storage Driver:/ || /Cgroup Driver:/ || /Cgroup Version:/ || /Kernel Version:/ || /Operating System:/ || /CPUs:/ || /Total Memory:/ {print}
    ' || true
    echo
    docker network ls 2>/dev/null | head -n 20 || true
  else
    echo "(docker not installed)"
  fi
}

swap_zram_status() {
  safe "free -h" free -h
  safe "swapon --show" swapon --show --output=NAME,TYPE,SIZE,USED,PRIO
  if have_cmd zramctl; then
    safe "zramctl" zramctl
  fi
}

disk_status() {
  safe "df -h" df -h
  safe "lsblk" lsblk -o NAME,SIZE,FSTYPE,FSVER,TYPE,MOUNTPOINTS
  safe "Top dirs in /var (du -xhd1 /var)" bash -lc 'du -xhd1 /var 2>/dev/null | sort -h | tail -n 15'
}

net_status() {
  safe "ip addr (brief)" ip -br addr
  safe "ip route" ip route
  if have_cmd resolvectl; then
    safe "resolvectl status (brief)" bash -lc 'resolvectl status 2>/dev/null | sed -n "1,120p"'
  else
    safe "/etc/resolv.conf" bash -lc 'sed -n "1,120p" /etc/resolv.conf 2>/dev/null || true'
  fi
  if have_cmd ss; then
    safe "Listening ports (ss -lntup | head)" bash -lc 'ss -lntup 2>/dev/null | head -n 30'
  fi
}

time_status() {
  if have_cmd timedatectl; then
    safe "timedatectl" timedatectl
  else
    safe "date" date
  fi
}

service_status() {
  if have_cmd systemctl; then
    safe "Key services" bash -lc 'systemctl is-active ssh sshd docker fail2ban ufw tailscaled cloudflared 2>/dev/null | nl -ba'
    safe "Failed units (systemctl --failed)" systemctl --failed --no-pager
  else
    echo "(no systemctl)"
  fi
}

recent_errors() {
  if have_cmd journalctl; then
    safe "Recent journal errors (last boot, priority<=3)" bash -lc 'journalctl -b -p 3 --no-pager 2>/dev/null | tail -n 60'
  else
    echo "(no journalctl)"
  fi
}

recommendations() {
  echo -e "${C_CYAN}>>> 建议关注项（自动检查）${C_RESET}"
  local issues=0

  # Disk low
  local root_use
  root_use="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  if [[ -n "${root_use:-}" && "${root_use:-0}" -ge 90 ]]; then
    warn "/ 分区使用率 ${root_use}%（>=90%）"
    ((issues++)) || true
  fi

  # Swap missing
  if ! swapon --show 2>/dev/null | awk 'NR>1{exit 0} END{exit 1}'; then
    warn "当前没有启用任何 swap（可能会导致 Docker/编译等 OOM）"
    ((issues++)) || true
  fi

  # SSH password auth
  if have_cmd sshd; then
    local pa
    pa="$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}' | tail -n 1)"
    if [[ "$pa" == "yes" ]]; then
      warn "SSH PasswordAuthentication 仍为 yes（建议禁用，改用 key）"
      ((issues++)) || true
    fi
  fi

  # Time sync
  if have_cmd timedatectl; then
    local sync
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [[ "$sync" == "no" ]]; then
      warn "NTP 未同步（NTPSynchronized=no），建议检查时间同步"
      ((issues++)) || true
    fi
  fi

  if ((issues == 0)); then
    ok "未发现明显风险项"
  else
    warn "发现 ${issues} 个建议关注项"
  fi
  echo
}

main() {
  echo -e "${C_CYAN}=========================================${C_RESET}"
  echo -e "${C_CYAN}            VPSKit Summary               ${C_RESET}"
  echo -e "${C_CYAN}=========================================${C_RESET}"

  local os id ver pretty virt arch kernel host uptime pubip
  IFS='|' read -r id ver pretty <<<"$(detect_os)"
  virt="$(detect_virt)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  kernel="$(uname -r 2>/dev/null || echo unknown)"
  host="$(hostname 2>/dev/null || echo unknown)"
  uptime="$(uptime -p 2>/dev/null || true)"
  pubip="$(get_public_ip)"

  echo
  echo -e "${C_GRAY}--- System ---${C_RESET}"
  kv "Hostname" "$host"
  kv "OS" "$pretty"
  kv "Kernel" "$kernel"
  kv "Arch" "$arch"
  kv "Virt" "$virt"
  kv "Uptime" "${uptime:-unknown}"
  kv "Public IP" "${pubip:-unknown}"
  echo

  time_status
  safe "CPU (lscpu top)" bash -lc 'lscpu 2>/dev/null | sed -n "1,25p"'
  safe "Memory (meminfo top)" bash -lc 'grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree" /proc/meminfo 2>/dev/null || true'

  info "网络信息"
  net_status

  info "磁盘与空间"
  disk_status

  info "内存/Swap/ZRAM"
  swap_zram_status

  info "SSH 配置摘要（effective）"
  safe "sshd -T (port/auth/root)" bash -lc 'sshd_effective'  # in subshell? doesn't have func
  # fallback: call directly
  echo -e "${C_GRAY}--- sshd -T (port/auth/root) ---${C_RESET}"
  sshd_effective
  echo

  info "安全组件（UFW / Fail2ban）"
  safe "UFW status" bash -lc 'ufw_status'  # fallback
  echo -e "${C_GRAY}--- UFW status ---${C_RESET}"
  ufw_status
  echo
  echo -e "${C_GRAY}--- Fail2ban status ---${C_RESET}"
  fail2ban_status
  echo

  info "运行环境（Docker）"
  echo -e "${C_GRAY}--- Docker status ---${C_RESET}"
  docker_status
  echo

  info "服务状态与最近错误"
  service_status
  recent_errors

  recommendations
  ok "Summary 完成"
}

main