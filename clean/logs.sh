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

vacuum_journal(){
  have_cmd journalctl || return 0
  info "systemd-journald：vacuum（保留 7 天 或 200M，取更严格）"
  journalctl --vacuum-time=7d >/dev/null 2>&1 || true
  journalctl --vacuum-size=200M >/dev/null 2>&1 || true
  ok "journalctl vacuum 完成（best-effort）"
}

truncate_big_logs(){
  info "截断常见大日志（只截断，不删除文件）"
  # 截断 .log / .out / messages / syslog 等
  # 仅对“文件大小 > 20MB”进行截断，避免误伤小文件
  find /var/log -type f \
    \( -name "*.log" -o -name "*.out" -o -name "syslog" -o -name "messages" -o -name "kern.log" -o -name "auth.log" -o -name "daemon.log" \) \
    -size +20M -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        : > "$f" || true
      done
  ok "大日志截断完成（best-effort）"
}

clean_rotated_logs(){
  info "清理已轮转日志（/var/log 下的 *.gz *.1 *.old）"
  find /var/log -type f \
    \( -name "*.gz" -o -name "*.1" -o -name "*.old" -o -name "*.xz" -o -name "*.zst" \) \
    -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        rm -f "$f" >/dev/null 2>&1 || true
      done
  ok "轮转日志清理完成（best-effort）"
}

clean_tmp(){
  info "清理临时目录（仅删除 >3 天的文件）"
  find /tmp -mindepth 1 -mtime +3 -print0 2>/dev/null | xargs -0r rm -rf >/dev/null 2>&1 || true
  find /var/tmp -mindepth 1 -mtime +3 -print0 2>/dev/null | xargs -0r rm -rf >/dev/null 2>&1 || true
  ok "临时目录清理完成（best-effort）"
}

main(){
  need_root
  info "日志截断与空间回收"
  echo -e "${C_GRAY}前置空间：${C_RESET}"
  disk_report

  vacuum_journal
  truncate_big_logs
  clean_rotated_logs
  clean_tmp

  ok "日志与空间回收完成"
  echo -e "${C_GRAY}后置空间：${C_RESET}"
  disk_report

  echo
  echo "---------- /var/log Top (du -sh) ----------"
  du -sh /var/log/* 2>/dev/null | sort -h | tail -n 20 || true
  echo "------------------------------------------"
}

main