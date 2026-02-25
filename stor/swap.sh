#!/usr/bin/env bash
set -euo pipefail

# =========================
# ZRAM / SWAP Robust Setup
# =========================

C_RESET="\033[0m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_GRAY="\033[90m"

log()  { echo -e "${C_GRAY}[$(date +'%F %T')]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✅ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { echo -e "${C_RED}❌ $*${C_RESET}" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "请用 root 执行：sudo $0"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Return RAM MiB
get_ram_mib() {
  awk '/MemTotal:/ {printf "%.0f\n", $2/1024}' /proc/meminfo
}

# Convert MiB -> human-ish (MiB/GiB)
mib_to_human() {
  local mib="$1"
  if (( mib >= 1024 )); then
    # GiB with 1 decimal when needed
    awk -v m="$mib" 'BEGIN{
      g=m/1024;
      if (g==int(g)) printf "%dG", g;
      else printf "%.1fG", g;
    }'
  else
    echo "${mib}M"
  fi
}

# Parse human (e.g. 512M/2G/1.5G) -> MiB
human_to_mib() {
  local s="${1^^}"
  if [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)G$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f\n", v*1024}'
  elif [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)M$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.0f\n", v}'
  elif [[ "$s" =~ ^[0-9]+$ ]]; then
    # assume MiB
    echo "$s"
  else
    err "无法解析大小：$1（支持 512M / 2G / 1.5G）"
    return 1
  fi
}

# =========================
# Recommendations (by RAM)
# =========================
# You can tune these, but they’re sane defaults.
recommend_zram_mib() {
  local ram_mib="$1"
  # Buckets:
  # <=2G: 100% RAM
  # <=4G: 75% RAM
  # <=8G: 50% RAM
  # <=16G: 25% RAM
  # >16G: 4096 MiB
  if (( ram_mib <= 2048 )); then
    echo "$ram_mib"
  elif (( ram_mib <= 4096 )); then
    awk -v r="$ram_mib" 'BEGIN{printf "%.0f\n", r*0.75}'
  elif (( ram_mib <= 8192 )); then
    awk -v r="$ram_mib" 'BEGIN{printf "%.0f\n", r*0.50}'
  elif (( ram_mib <= 16384 )); then
    awk -v r="$ram_mib" 'BEGIN{printf "%.0f\n", r*0.25}'
  else
    echo "4096"
  fi
}

recommend_swap_mib() {
  local ram_mib="$1"
  # Disk swap (non-hibernate) conservative defaults:
  # <=2G: 2G
  # <=4G: 1x RAM (cap 4G)
  # <=8G: 4G
  # <=16G: 4G
  # >16G: 8G
  if (( ram_mib <= 2048 )); then
    echo "2048"
  elif (( ram_mib <= 4096 )); then
    # 1x RAM but cap 4096
    if (( ram_mib > 4096 )); then echo "4096"; else echo "$ram_mib"; fi
  elif (( ram_mib <= 8192 )); then
    echo "4096"
  elif (( ram_mib <= 16384 )); then
    echo "4096"
  else
    echo "8192"
  fi
}

print_recommendations() {
  local ram_mib
  ram_mib="$(get_ram_mib)"
  local zram_mib swap_mib
  zram_mib="$(recommend_zram_mib "$ram_mib")"
  swap_mib="$(recommend_swap_mib "$ram_mib")"

  echo -e "${C_CYAN}内存检测：$(mib_to_human "$ram_mib")${C_RESET}"
  echo -e "  - 推荐 ZRAM：$(mib_to_human "$zram_mib")"
  echo -e "  - 推荐 磁盘SWAP：$(mib_to_human "$swap_mib")"
}

# =========================
# Detect systemd generator
# =========================
zram_generator_available() {
  # generator binary can be in these places depending on distro/package
  [[ -x /usr/lib/systemd/system-generators/zram-generator ]] && return 0
  [[ -x /usr/lib/systemd/system-generators/systemd-zram-generator ]] && return 0
  [[ -x /usr/lib/systemd/system-generators/zram-generator.conf ]] && return 0
  # Just in case: config dir existence isn't enough; we need systemd + generator path
  return 1
}

have_systemd() {
  [[ -d /run/systemd/system ]] && have_cmd systemctl
}

# =========================
# Clean existing swaps/zram
# =========================
disable_existing_zram_swaps() {
  # Turn off zram swaps if any
  if [[ -r /proc/swaps ]]; then
    while read -r dev _; do
      [[ "$dev" =~ ^/dev/zram[0-9]+$ ]] || continue
      if swapon --show=NAME | grep -q "^$dev$"; then
        log "swapoff $dev"
        swapoff "$dev" || true
      fi
    done < <(awk 'NR>1 {print $1}' /proc/swaps)
  fi
}

disable_swapfile_if_matches() {
  local path="$1"
  if swapon --show=NAME | grep -q "^$path$"; then
    log "swapoff $path"
    swapoff "$path" || true
  fi
}

# =========================
# ZRAM (generator mode)
# =========================
apply_zram_generator() {
  local zram_size_h="$1"   # e.g. 2G
  local algo="$2"          # zstd/lz4
  local prio="$3"          # e.g. 100

  if ! have_systemd; then
    err "系统似乎不是 systemd，无法用 generator。"
    return 1
  fi

  # Write config
  mkdir -p /etc/systemd
  cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${zram_size_h}
compression-algorithm = ${algo}
swap-priority = ${prio}
EOF

  ok "已写入 /etc/systemd/zram-generator.conf（generator 模式）"

  # Restart relevant units: systemd-zram-setup@zram0.service is typical
  # We try a few safe options.
  systemctl daemon-reload || true

  # Stop any old instance to ensure fresh apply
  systemctl stop "systemd-zram-setup@zram0.service" >/dev/null 2>&1 || true
  systemctl stop "zram-swap.service" >/dev/null 2>&1 || true

  # Try to start
  if systemctl start "systemd-zram-setup@zram0.service" >/dev/null 2>&1; then
    systemctl enable "systemd-zram-setup@zram0.service" >/dev/null 2>&1 || true
    ok "已启动 systemd-zram-setup@zram0.service"
    return 0
  fi

  # Some distros name differs
  if systemctl start "systemd-zram-setup@.service" >/dev/null 2>&1; then
    ok "已启动 systemd-zram-setup@.service"
    return 0
  fi

  # If generator exists but unit naming differs, try reboot-free workaround: tools path
  warn "generator 存在，但未能启动 systemd-zram-setup 单元（可能发行版命名不同）。将自动回退 tools 方案。"
  return 2
}

# =========================
# ZRAM (tools mode)
# =========================
install_zram_service_tools() {
  local zram_mib="$1"
  local algo="$2"
  local prio="$3"

  have_cmd modprobe || { err "缺少 modprobe，无法加载 zram 模块"; return 1; }
  have_cmd mkswap  || { err "缺少 mkswap（通常在 util-linux），无法创建 swap"; return 1; }
  have_cmd swapon  || { err "缺少 swapon，无法启用 swap"; return 1; }

  # Try load module
  if ! modprobe zram 2>/dev/null; then
    err "modprobe zram 失败（容器/LXC 常见：内核不允许模块）。"
    return 1
  fi

  # Create persistent systemd service for zram swap
  if have_systemd; then
    cat > /etc/systemd/system/zram-swap.service <<EOF
[Unit]
Description=ZRAM swap (tools mode)
After=local-fs.target
ConditionPathExists=/dev/zram0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap-start.sh
ExecStop=/usr/local/sbin/zram-swap-stop.sh

[Install]
WantedBy=multi-user.target
EOF

    install -m 0755 /dev/stdin /usr/local/sbin/zram-swap-start.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ZRAM_MIB="__ZRAM_MIB__"
ALGO="__ALGO__"
PRIO="__PRIO__"

modprobe zram >/dev/null 2>&1 || true

# If already active, do nothing
if swapon --show=NAME 2>/dev/null | grep -q '^/dev/zram0$'; then
  exit 0
fi

# Configure zram0
echo 1 > /sys/class/zram-control/hot_add || true
# ensure /dev/zram0 exists; some kernels create it automatically
if [[ ! -e /dev/zram0 ]]; then
  # best effort
  mknod /dev/zram0 b 252 0 2>/dev/null || true
fi

# set algorithm if available
if [[ -w /sys/block/zram0/comp_algorithm ]]; then
  # pick if supported
  if grep -qw "$ALGO" /sys/block/zram0/comp_algorithm; then
    echo "$ALGO" > /sys/block/zram0/comp_algorithm
  fi
fi

# set size (bytes)
bytes=$((ZRAM_MIB * 1024 * 1024))
echo "$bytes" > /sys/block/zram0/disksize

mkswap -f /dev/zram0 >/dev/null
swapon -p "$PRIO" /dev/zram0
EOF

    install -m 0755 /dev/stdin /usr/local/sbin/zram-swap-stop.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if swapon --show=NAME 2>/dev/null | grep -q '^/dev/zram0$'; then
  swapoff /dev/zram0 || true
fi
EOF

    # inject variables
    sed -i "s/__ZRAM_MIB__/${zram_mib}/g; s/__ALGO__/${algo}/g; s/__PRIO__/${prio}/g" /usr/local/sbin/zram-swap-start.sh

    systemctl daemon-reload
    systemctl enable --now zram-swap.service
    ok "已启用 zram-swap.service（tools 模式）"
  else
    # No systemd: just do it once
    warn "非 systemd 环境：将仅本次启用（重启后不会自动生效）。"
    # Configure now
    if [[ -w /sys/block/zram0/comp_algorithm ]]; then
      if grep -qw "$algo" /sys/block/zram0/comp_algorithm; then
        echo "$algo" > /sys/block/zram0/comp_algorithm
      fi
    fi
    echo $((zram_mib * 1024 * 1024)) > /sys/block/zram0/disksize
    mkswap -f /dev/zram0 >/dev/null
    swapon -p "$prio" /dev/zram0
    ok "已启用 /dev/zram0 swap（tools 模式，本次）"
  fi

  return 0
}

cleanup_zram_tools_if_present() {
  local removed="false"

  # stop/disable tools-mode service if exists
  if have_systemd && systemctl list-unit-files 2>/dev/null | grep -qE '^zram-swap\.service'; then
    log "检测到 tools 模式的 zram-swap.service，准备移除..."
    systemctl stop zram-swap.service >/dev/null 2>&1 || true
    systemctl disable zram-swap.service >/dev/null 2>&1 || true
    removed="true"
  fi

  # turn off active zram swaps (just in case)
  disable_existing_zram_swaps

  # remove unit + scripts if exist
  if [[ -f /etc/systemd/system/zram-swap.service ]]; then
    rm -f /etc/systemd/system/zram-swap.service
    removed="true"
  fi

  if [[ -f /usr/local/sbin/zram-swap-start.sh ]]; then
    rm -f /usr/local/sbin/zram-swap-start.sh
    removed="true"
  fi

  if [[ -f /usr/local/sbin/zram-swap-stop.sh ]]; then
    rm -f /usr/local/sbin/zram-swap-stop.sh
    removed="true"
  fi

  # optional: unload module (not required; may fail on some systems)
  if have_cmd modprobe; then
    modprobe -r zram >/dev/null 2>&1 || true
  fi

  if [[ "$removed" == "true" ]]; then
    if have_systemd; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    ok "已移除 tools 模式的 ZRAM 配置（service/scripts）"
    return 0
  fi

  return 1
}


configure_zram() {
  local ram_mib zram_mib zram_h algo prio
  ram_mib="$(get_ram_mib)"
  zram_mib="$(recommend_zram_mib "$ram_mib")"
  zram_h="$(mib_to_human "$zram_mib")"

  algo="zstd"   # good default; will fallback silently if kernel doesn't support
  prio="100"

  echo -e "${C_CYAN}ZRAM 推荐值：${zram_h}（内存：$(mib_to_human "$ram_mib")）${C_RESET}"
  read -r -p "使用推荐值？[Y/n] " ans || true
  ans="${ans:-Y}"
  if [[ "${ans^^}" != "Y" ]]; then
    read -r -p "输入 ZRAM 大小（例如 1024M / 2G / 1.5G）： " custom
    zram_mib="$(human_to_mib "$custom")"
    zram_h="$(mib_to_human "$zram_mib")"
  fi

  read -r -p "ZRAM 压缩算法（zstd/lz4，默认 zstd）： " algo_in || true
  algo_in="${algo_in:-zstd}"
  algo="${algo_in}"

  read -r -p "ZRAM swap 优先级 priority（默认 100）： " prio_in || true
  prio_in="${prio_in:-100}"
  prio="${prio_in}"

  # clean existing
  disable_existing_zram_swaps

  # generator first if possible
  if have_systemd && zram_generator_available; then
    cleanup_zram_tools_if_present || true

    log "检测到 zram generator：尝试 generator 模式..."
    set +e
    apply_zram_generator "$zram_h" "$algo" "$prio"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      ok "ZRAM 已用 generator 模式配置完成"
      return 0
    elif [[ $rc -eq 2 ]]; then
      log "回退到 tools 模式..."
    else
      warn "generator 模式不可用/失败，回退到 tools 模式..."
    fi
  else
    warn "未检测到可用 generator（或非 systemd），将使用 tools 模式。"
  fi

  install_zram_service_tools "$zram_mib" "$algo" "$prio"
  ok "ZRAM 已用 tools 模式配置完成"
}

# =========================
# SWAPFILE (disk swap)
# =========================
configure_swapfile() {
  local ram_mib swap_mib swap_h prio path
  ram_mib="$(get_ram_mib)"
  swap_mib="$(recommend_swap_mib "$ram_mib")"
  swap_h="$(mib_to_human "$swap_mib")"

  prio="10"
  path="/swapfile"

  echo -e "${C_CYAN}磁盘 SWAP 推荐值：${swap_h}（内存：$(mib_to_human "$ram_mib")）${C_RESET}"
  read -r -p "使用推荐值？[Y/n] " ans || true
  ans="${ans:-Y}"
  if [[ "${ans^^}" != "Y" ]]; then
    read -r -p "输入 SWAP 大小（例如 2048M / 4G / 8G）： " custom
    swap_mib="$(human_to_mib "$custom")"
    swap_h="$(mib_to_human "$swap_mib")"
  fi

  read -r -p "SWAPFILE 路径（默认 /swapfile）： " path_in || true
  path_in="${path_in:-/swapfile}"
  path="$path_in"

  read -r -p "磁盘 SWAP 优先级 priority（默认 10）： " prio_in || true
  prio_in="${prio_in:-10}"
  prio="${prio_in}"

  # turn off current same path swap
  disable_swapfile_if_matches "$path"

  # if exists and is used by other config, we recreate safely
  if [[ -e "$path" ]]; then
    warn "检测到已存在 $path，将备份为 ${path}.bak.$(date +%s)"
    mv -f "$path" "${path}.bak.$(date +%s)"
  fi

  # allocate swapfile
  log "创建 swapfile：$path 大小：$swap_h"
  if have_cmd fallocate; then
    fallocate -l "$swap_h" "$path"
  else
    # dd fallback
    dd if=/dev/zero of="$path" bs=1M count="$swap_mib" status=progress
  fi

  chmod 600 "$path"
  mkswap "$path" >/dev/null
  swapon -p "$prio" "$path"

  # persist in /etc/fstab
  if ! grep -qE "^[^#]*\s+$path\s+swap\s" /etc/fstab 2>/dev/null; then
    echo "$path none swap sw,pri=$prio 0 0" >> /etc/fstab
    ok "已写入 /etc/fstab 持久化"
  else
    # ensure pri matches (best effort)
    sed -i -E "s|^[^#]*\s+${path}\s+swap\s+.*|${path} none swap sw,pri=${prio} 0 0|g" /etc/fstab || true
    ok "已更新 /etc/fstab priority"
  fi

  ok "磁盘 SWAP 配置完成"
}

# =========================
# Sysctl tuning (optional)
# =========================
apply_sysctl_defaults() {
  # Reasonable defaults; you can tune later
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-vpskit-swap.conf <<'EOF'
# VPSKit swap defaults
vm.swappiness=80
vm.vfs_cache_pressure=100
EOF
  sysctl --system >/dev/null 2>&1 || true
  ok "已应用 sysctl 默认值（/etc/sysctl.d/99-vpskit-swap.conf）"
}

# =========================
# Output status
# =========================
show_status() {
  echo
  echo -e "${C_CYAN}========== 当前内存 / swap 状态 ==========${C_RESET}"
  free -h || true
  echo
  echo -e "${C_CYAN}---------- swapon --show ----------${C_RESET}"
  swapon --show --output=NAME,TYPE,SIZE,USED,PRIO || true
  echo
  if have_cmd zramctl; then
    echo -e "${C_CYAN}---------- zramctl ----------${C_RESET}"
    zramctl || true
  else
    warn "未安装 zramctl（util-linux），跳过 zramctl 输出"
  fi
  echo -e "${C_CYAN}=========================================${C_RESET}"
}

# =========================
# Main menu
# =========================
main() {
  need_root
  echo -e "${C_CYAN}ZRAM / SWAP 配置器${C_RESET}"
  print_recommendations
  echo
  echo "请选择："
  echo "  1) 配置 ZRAM（优先 generator，失败则 tools）"
  echo "  2) 配置 磁盘 SWAP（swapfile）"
  echo "  3) 同时配置 ZRAM + 磁盘 SWAP"
  echo "  0) 退出"
  echo
  read -r -p "输入选项 [0-3]： " choice

  case "${choice:-}" in
    1)
      configure_zram
      apply_sysctl_defaults
      show_status
      ;;
    2)
      configure_swapfile
      apply_sysctl_defaults
      show_status
      ;;
    3)
      configure_zram
      configure_swapfile
      apply_sysctl_defaults
      show_status
      ;;
    0)
      ok "已退出"
      ;;
    *)
      err "无效选项：$choice"
      exit 1
      ;;
  esac
}

main "$@"