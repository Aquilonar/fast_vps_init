#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET="\033[0m"; C_CYAN="\033[1;36m"; C_YELLOW="\033[1;33m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_GRAY="\033[90m"
info(){ echo -e "${C_CYAN}>>> $*${C_RESET}"; }
warn(){ echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
ok(){ echo -e "${C_GREEN}✅ $*${C_RESET}"; }
die(){ echo -e "${C_RED}❌ $*${C_RESET}" >&2; exit 1; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "请用 root 执行"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

is_debian_like(){
  [[ -r /etc/os-release ]] || return 1
  . /etc/os-release
  [[ "${ID_LIKE:-}" == *debian* || "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" ]]
}

disk_report(){
  df -h / /var 2>/dev/null || true
}

main(){
  need_root
  info "卸载 Snap 应用（如果存在）"
  echo -e "${C_GRAY}前置空间：${C_RESET}"
  disk_report

  if ! is_debian_like; then
    warn "当前系统非 Debian/Ubuntu 系，通常没有 snapd；跳过"
    exit 0
  fi

  if ! have_cmd snap && ! dpkg -s snapd >/dev/null 2>&1; then
    ok "未检测到 snap/snapd（跳过）"
    exit 0
  fi

  # 尽量先停服务
  if have_cmd systemctl; then
    systemctl stop snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
    systemctl disable snapd.service snapd.socket snapd.seeded.service >/dev/null 2>&1 || true
  fi

  # 卸载 snap 包（尽量卸干净；core 系列有时需要先删其它）
  if have_cmd snap; then
    info "检测到 snap：尝试移除已安装的 snap 包"
    # 列出非基础包优先删
    mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1{print $1}' || true)

    # 删除顺序：先删非 core/base/snapd 再删基础
    for s in "${snaps[@]}"; do
      [[ "$s" =~ ^(core|core18|core20|core22|core24|base|snapd)$ ]] && continue
      snap remove --purge "$s" >/dev/null 2>&1 || true
    done
    for s in "${snaps[@]}"; do
      [[ "$s" =~ ^(core|core18|core20|core22|core24|base|snapd)$ ]] || continue
      snap remove --purge "$s" >/dev/null 2>&1 || true
    done
  fi

  info "卸载 snapd（apt purge）"
  if have_cmd apt-get; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get purge -y snapd >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  else
    warn "没有 apt-get，无法自动 purge snapd（请手动卸载）"
  fi

  # 清理残留目录（best-effort）
  info "清理 snap 残留目录（best-effort）"
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd >/dev/null 2>&1 || true
  # 用户家目录下的 ~/snap
  for d in /home/*/snap; do
    [[ -d "$d" ]] && rm -rf "$d" >/dev/null 2>&1 || true
  done
  [[ -d /root/snap ]] && rm -rf /root/snap >/dev/null 2>&1 || true

  ok "Snap 清理完成"
  echo -e "${C_GRAY}后置空间：${C_RESET}"
  disk_report
}

main