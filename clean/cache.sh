#!/usr/bin/env bash
set -Eeuo pipefail

C_RESET="\033[0m"; C_CYAN="\033[1;36m"; C_YELLOW="\033[1;33m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_GRAY="\033[90m"
info(){ echo -e "${C_CYAN}>>> $*${C_RESET}"; }
warn(){ echo -e "${C_YELLOW}⚠ $*${C_RESET}"; }
ok(){ echo -e "${C_GREEN}✅ $*${C_RESET}"; }
die(){ echo -e "${C_RED}❌ $*${C_RESET}" >&2; exit 1; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || die "请用 root 执行"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

disk_report(){ df -h / /var 2>/dev/null || true; }

main(){
  need_root
  info "清理系统包缓存"
  echo -e "${C_GRAY}前置空间：${C_RESET}"
  disk_report

  if have_cmd apt-get; then
    info "APT: clean + autoclean + autoremove"
    apt-get clean -y >/dev/null 2>&1 || true
    apt-get autoclean -y >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    # 清理 lists（可选，节省 /var/lib/apt/lists）
    rm -rf /var/lib/apt/lists/* >/dev/null 2>&1 || true
    ok "APT 缓存清理完成"

  elif have_cmd dnf; then
    info "DNF: clean all + autoremove"
    dnf clean all >/dev/null 2>&1 || true
    dnf autoremove -y >/dev/null 2>&1 || true
    ok "DNF 缓存清理完成"

  elif have_cmd yum; then
    info "YUM: clean all"
    yum clean all >/dev/null 2>&1 || true
    ok "YUM 缓存清理完成"

  elif have_cmd pacman; then
    info "Pacman: 清理缓存（paccache 优先）"
    if have_cmd paccache; then
      paccache -r >/dev/null 2>&1 || true
    else
      warn "缺少 paccache（pacman-contrib），将仅做 pacman -Sc（可能交互）"
      yes | pacman -Sc >/dev/null 2>&1 || true
    fi
    ok "Pacman 缓存清理完成"

  elif have_cmd apk; then
    info "APK: 清理缓存"
    rm -rf /var/cache/apk/* >/dev/null 2>&1 || true
    ok "APK 缓存清理完成"

  else
    warn "未识别到常见包管理器，跳过"
  fi

  ok "系统包缓存清理完成"
  echo -e "${C_GRAY}后置空间：${C_RESET}"
  disk_report
}

main