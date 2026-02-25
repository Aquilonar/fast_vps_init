#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# VPSKit main.sh (Public-ready, commit-pinned)
# ==================================================

# ---------- Defaults ----------
BASE_URL_DEFAULT="https://raw.githubusercontent.com/Aquilonar/fast_vps_init/refs/heads/main"

CACHE_DIR_DEFAULT="/tmp/vpskit/cache"
LOG_DIR_DEFAULT="/tmp/vpskit"
LOG_FILE_DEFAULT="${LOG_DIR_DEFAULT}/vpskit.log"

USE_CACHE="true"
DRY_RUN="false"
BASE_URL="$BASE_URL_DEFAULT"
CACHE_DIR="$CACHE_DIR_DEFAULT"
LOG_FILE="$LOG_FILE_DEFAULT"

# 推荐流程脚本（仓库内路径）
RECOMMENDED_FLOW_REL_DEFAULT="flow/recommended.sh"

# ---------- Colors ----------
C_RESET="\033[0m"
C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_GRAY="\033[90m"

# ---------- Helpers ----------
die() {
	echo -e "${C_RED}❌ $*${C_RESET}" >&2
	exit 1
}
info() { echo -e "${C_CYAN}>>> $*${C_RESET}" >&2; }
warn() { echo -e "${C_YELLOW}⚠ $*${C_RESET}" >&2; }
ok() { echo -e "${C_GREEN}✅ $*${C_RESET}" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"; }

init_dirs() {
	mkdir -p "$(dirname "$LOG_FILE")" "$CACHE_DIR"
	touch "$LOG_FILE" 2>/dev/null || true
}

log() {
	local msg="$*"
	printf '[%s] %s\n' "$(date '+%F %T')" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

trap_err() {
	local code=$?
	warn "发生错误（exit=$code），详情见日志：$LOG_FILE"
	log "ERROR exit=$code file=${BASH_SOURCE[1]:-?} line=${BASH_LINENO[0]:-?} func=${FUNCNAME[1]:-?} cmd=${BASH_COMMAND}"
	exit "$code"
}
trap trap_err ERR
shopt -s inherit_errexit 2>/dev/null || true

prompt_enter() { read -r -p "按回车返回菜单..." _ </dev/tty || true; }

# ---------- Args ----------
usage() {
	cat <<'EOF'
Usage:
  bash main.sh [options]

Options:
  --base-url <url>     设置脚本源（GitHub raw 基础地址，建议固定到 commit）
  --cache-dir <dir>    设置缓存目录（默认 /var/lib/vpskit/cache）
  --no-cache           不使用缓存（每次都重新拉取）
  --dry-run            只演示，不执行远程脚本
  -h, --help           显示帮助

Menu:
  r  推荐流程（自动按顺序执行）
  u  更新缓存（清空缓存，下次执行自动重新拉取）
  q  返回/退出
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--base-url)
			BASE_URL="${2:-}"
			[[ -n "$BASE_URL" ]] || die "缺少 --base-url 参数"
			shift 2
			;;
		--cache-dir)
			CACHE_DIR="${2:-}"
			[[ -n "$CACHE_DIR" ]] || die "缺少 --cache-dir 参数"
			shift 2
			;;
		--no-cache)
			USE_CACHE="false"
			shift
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*) die "未知参数：$1（用 -h 查看帮助）" ;;
		esac
	done
}

normalize_base_url() {
	BASE_URL="${BASE_URL%/}"
	[[ -n "$BASE_URL" ]] || die "BASE_URL 不能为空"
}

normalize_rel() {
	local rel="$1"
	rel="${rel#/}"
	[[ "$rel" == *".."* ]] && die "非法脚本路径：$rel"
	printf '%s' "$rel"
}

# ==================================================
# 1) Menu Database
# 格式：TAG|NAME|TARGET|TYPE|LIMIT
# LIMIT: ALL / KVM_ONLY
# ==================================================
MENU_DATA="
MAIN|系统基准 (Baseline)|BASE_SUB|submenu|ALL
MAIN|存储与交换 (Storage)|STOR_SUB|submenu|ALL
MAIN|网络加速 (Network)|NET_SUB|submenu|ALL
MAIN|身份与权限 (Identity)|ID_SUB|submenu|ALL
MAIN|安全加固 (Hardening)|HARD_SUB|submenu|ALL
MAIN|运行环境 (Runtime)|RUN_SUB|submenu|ALL
MAIN|组网与穿透 (Connectivity)|CONN_SUB|submenu|ALL
MAIN|收尾清理 (Cleanup)|CLEAN_SUB|submenu|ALL
MAIN|信息快照 (Summary)|summary.sh|script|ALL

BASE_SUB|更新软件源 (Mirror)|base/mirror.sh|script|ALL
BASE_SUB|时区与主机名设置|base/system.sh|script|ALL
BASE_SUB|常用软件包安装 (git/vim/curl)|base/pkgs.sh|script|ALL
BASE_SUB|安装系统语言包|base/lang.sh|script|ALL

STOR_SUB|ZRAM/SWAP 配置|stor/swap.sh|script|ALL
STOR_SUB|自动磁盘挂载|stor/mount.sh|script|ALL
STOR_SUB|Swappiness 性能优化|stor/tuning.sh|script|ALL

NET_SUB|BBRv3 官方加速|net/bbr.sh|script|KVM_ONLY
NET_SUB|DNS 优化 (DoH/DoT)|net/dns.sh|script|ALL
NET_SUB|MTU 调整与 TCP FastOpen|net/tcp.sh|script|ALL

ID_SUB|创建新用户 (Sudoer)|id/user.sh|script|ALL
ID_SUB|SSH Key 注入|id/key.sh|script|ALL
ID_SUB|Sudo 免密权限配置|id/sudo.sh|script|ALL

HARD_SUB|SSH 端口修改|hard/port.sh|script|ALL
HARD_SUB|禁用密码登录|hard/auth.sh|script|ALL
HARD_SUB|UFW 防火墙配置|hard/ufw.sh|script|ALL
HARD_SUB|Fail2ban 防暴力破解|hard/f2b.sh|script|ALL

RUN_SUB|Docker & Compose 环境|run/docker.sh|script|ALL
RUN_SUB|Node.js (NVM版) 安装|run/node.sh|script|ALL
RUN_SUB|Python3 (Venv) 环境|run/py.sh|script|ALL

CONN_SUB|Tailscale 组网安装|conn/ts.sh|script|ALL
CONN_SUB|Cloudflare Warp 代理|conn/warp.sh|script|KVM_ONLY
CONN_SUB|Frp 穿透客户端|conn/frp.sh|script|ALL
CONN_SUB|Komari 探针客户端|conn/komari.sh|script|ALL

CLEAN_SUB|卸载系统 Snap 应用|clean/snap.sh|script|ALL
CLEAN_SUB|清理系统包缓存|clean/cache.sh|script|ALL
CLEAN_SUB|日志截断与空间回收|clean/logs.sh|script|ALL
"

# ==================================================
# 2) Pre-Flight
# ==================================================
IS_LXC="false"
VIRT="UNKNOWN"
OS_ARCH="$(uname -m)"

detect_virt() {
	if command -v systemd-detect-virt >/dev/null 2>&1; then
		local v
		v="$(systemd-detect-virt 2>/dev/null || true)"
		case "$v" in
		lxc | lxc-libvirt | docker | podman | container)
			IS_LXC="true"
			VIRT="$v"
			;;
		kvm | qemu)
			IS_LXC="false"
			VIRT="$v"
			;;
		none | "")
			IS_LXC="false"
			VIRT="physical/unknown"
			;;
		*)
			IS_LXC="false"
			VIRT="$v"
			;;
		esac
	else
		if [[ -f /proc/1/environ ]] && grep -qaE 'container=(lxc|docker|podman)' /proc/1/environ; then
			IS_LXC="true"
			VIRT="container"
		else
			IS_LXC="false"
			VIRT="kvm/physical"
		fi
	fi
}

pre_flight() {
	clear
	echo -e "${C_CYAN}>>> [0. Pre-Flight] 初始化环境...${C_RESET}"
	detect_virt
	echo -e "    架构: $OS_ARCH"
	echo -e "    类型: $VIRT"
	[[ "$IS_LXC" == "true" ]] && echo -e "${C_YELLOW}    提示: 容器环境，内核相关项已禁用${C_RESET}"
	echo -e "    源:   $BASE_URL"
	echo -e "    缓存: $CACHE_DIR (use_cache=$USE_CACHE)"
	echo -e "    日志: $LOG_FILE"
}

# ==================================================
# 3) Menu Data Preprocess
# ==================================================
GLOBAL_MENU_LINES=()

trim_line() {
	local s="$1"
	s="${s//$'\r'/}"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

init_menu_data() {
	GLOBAL_MENU_LINES=()
	while IFS= read -r line; do
		line="$(trim_line "$line")"
		[[ -z "$line" || "$line" == "#"* ]] && continue
		GLOBAL_MENU_LINES+=("$line")
	done <<<"$MENU_DATA"
}

# ==================================================
# 4) Fetch + Cache + Execute
# ==================================================
CURL_COMMON=(
	-fSL
	--proto '=https' --tlsv1.2
	--connect-timeout 5
	--max-time 30
	--retry 3
	--retry-delay 1
	--retry-all-errors
)

cache_path_of() { printf '%s/%s' "$CACHE_DIR" "$1"; }

fetch_script() {
	local rel url dst tmp
	rel="$(normalize_rel "$1")"
	url="${BASE_URL}/${rel}"
	dst="$(cache_path_of "$rel")"

	mkdir -p "$(dirname "$dst")"

	if [[ "$USE_CACHE" == "true" && -f "$dst" ]]; then
		printf '%s\n' "$dst"
		return 0
	fi

	info "拉取: $url"
	log "FETCH $url"

	tmp="$(mktemp)"
	trap 'rm -f "$tmp" 2>/dev/null || true' RETURN

	curl "${CURL_COMMON[@]}" -o "$tmp" "$url"
	chmod +x "$tmp"
	mv -f "$tmp" "$dst"

	trap - RETURN
	printf '%s\n' "$dst"
}

run_task() {
	local name="$1" rel="$2"

	echo
	echo -e "${C_YELLOW}[执行模块] ${name}${C_RESET}"
	echo "来源: ${BASE_URL}/${rel}"
	log "RUN name=${name} rel=${rel}"

	if [[ "$DRY_RUN" == "true" ]]; then
		warn "dry-run 模式：不执行"
		prompt_enter
		return 0
	fi

	local script_file
	script_file="$(fetch_script "$rel")"
	bash "$script_file"

	ok "完成：$name"
	prompt_enter
}

reset_cache() {
	warn "清空缓存：$CACHE_DIR"
	rm -rf "$CACHE_DIR"
	mkdir -p "$CACHE_DIR"
	log "CACHE_RESET dir=$CACHE_DIR"
	sleep 1
}

export_vpskit_bundle() {
	local src="/tmp/vpskit"
	[[ -d "$src" ]] || {
		warn "未找到 $src，无需导出"
		return 0
	}

	local ts out
	ts="$(date '+%Y%m%d_%H%M%S')"
	out="./vpskit_bundle_${ts}.tar.gz"
	touch "$out" 2>/dev/null || out="/tmp/vpskit_bundle_${ts}.tar.gz"

	info "正在打包：$src -> $out"
	log "EXPORT bundle=$out"

	if tar -czf "$out" -C "$(dirname "$src")" "$(basename "$src")" >/dev/null 2>&1; then
		ok "已导出：$out"
	else
		warn "打包失败（tar -czf），但不影响退出"
	fi
}

cleanup_all() {
	warn "即将清空脚本产生的内容："
	echo "  - cache: $CACHE_DIR" >&2
	echo "  - logs : $(dirname "$LOG_FILE")" >&2

	local cache_abs log_dir
	cache_abs="$CACHE_DIR"
	log_dir="$(dirname "$LOG_FILE")"

	for p in "$cache_abs" "$log_dir"; do
		[[ -z "$p" ]] && die "清理路径为空，已中止"
		[[ "$p" == "/" ]] && die "拒绝清理根目录 /"
		[[ "$p" == "/tmp" ]] && die "拒绝清理 /tmp（范围过大）"
		[[ "$p" == "/var" ]] && die "拒绝清理 /var（范围过大）"
	done

	rm -rf "$cache_abs" "$log_dir" 2>/dev/null || true

	if [[ "$cache_abs" == /tmp/vpskit/* && "$log_dir" == /tmp/vpskit* ]]; then
		rm -rf /tmp/vpskit 2>/dev/null || true
	fi

	ok "已清空脚本内容（cache/log/workdir）"
	log "CLEANUP_ALL cache=$cache_abs logdir=$log_dir"
}

run_recommended_flow() {
	local rel="${1:-$RECOMMENDED_FLOW_REL_DEFAULT}"

	echo
	info "启动推荐流程：$rel"
	log "FLOW_START rel=$rel"

	local flow_file
	flow_file="$(fetch_script "$rel")"

	# 作为子进程执行（失败会触发 trap_err）
	bash "$flow_file"

	ok "推荐流程完成"
}

# ==================================================
# 5) Menu Engine (固定列对齐版)
# ==================================================
term_cols() {
	local c
	c="$(tput cols 2>/dev/null || true)"
	[[ "$c" =~ ^[0-9]+$ ]] && printf '%s' "$c" || printf '0'
}

cursor_to_col() {
	local col="$1"
	tput hpa "$col" 2>/dev/null || printf '\033[%dG' "$col"
}

calc_status_col() {
	local status_col_default=52
	local cols
	cols="$(term_cols)"

	local col="$status_col_default"
	if [[ "$cols" =~ ^[0-9]+$ ]] && ((cols > 0)); then
		((col > cols - 10)) && col=$((cols - 10))
		((col < 20)) && col=20
	fi
	printf '%s' "$col"
}

print_menu_item() {
	local idx="$1" name="$2" type="$3" disabled="$4" reason="$5" status_col="$6"

	local status_label
	if [[ "$disabled" == "true" ]]; then
		status_label="${C_GRAY}[$reason]${C_RESET}"
		printf "  %2d. ${C_GRAY}%s${C_RESET}" "$idx" "$name"
		cursor_to_col "$status_col"
		printf " %b\n" "$status_label"
		return 0
	fi

	if [[ "$type" == "submenu" ]]; then
		status_label="${C_YELLOW}[进入]${C_RESET}"
	else
		status_label="${C_GREEN}[执行]${C_RESET}"
	fi

	printf "  %2d. %s" "$idx" "$name"
	cursor_to_col "$status_col"
	printf " %b\n" "$status_label"
}

render_menu() {
	local target_tag="$1"

	while true; do
		local -a display_indices=()
		local idx
		for idx in "${!GLOBAL_MENU_LINES[@]}"; do
			[[ "${GLOBAL_MENU_LINES[$idx]%%|*}" == "$target_tag" ]] && display_indices+=("$idx")
		done

		clear
		echo "=========================================="
		echo -e "${C_CYAN}   VPS 自动化全能部署 (Stage: $target_tag)${C_RESET}"
		echo "=========================================="

		local status_col
		status_col="$(calc_status_col)"

		local i=1
		local -a n_list=() t_list=() y_list=() d_list=() reason_list=()

		for idx in "${display_indices[@]}"; do
			local row tag name target type limit
			row="${GLOBAL_MENU_LINES[$idx]}"
			IFS='|' read -r tag name target type limit <<<"$row"

			local disabled="false" reason=""
			if [[ "$IS_LXC" == "true" && "$limit" == "KVM_ONLY" ]]; then
				disabled="true"
				reason="仅KVM"
			fi

			n_list[$i]="$name"
			t_list[$i]="$target"
			y_list[$i]="$type"
			d_list[$i]="$disabled"
			reason_list[$i]="$reason"

			print_menu_item "$i" "$name" "$type" "$disabled" "$reason" "$status_col"
			((i++))
		done

		echo "------------------------------------------"
		[[ "$target_tag" == "MAIN" ]] && echo "  r. 推荐流程（自动按顺序执行）"
		echo "  u. 更新缓存（清空并重新拉取）"
		echo "  q. 退出 / 返回上一级"
		echo "=========================================="
		read -r -p "请选择: " opt </dev/tty || opt="q"

		# 推荐流程（只在 MAIN）
		if [[ "$target_tag" == "MAIN" && "$opt" == "r" ]]; then
			run_recommended_flow
			prompt_enter
			continue
		fi

		if [[ "$opt" == "q" || -z "$opt" ]]; then
			if [[ "$target_tag" == "MAIN" ]]; then
				echo
				echo -e "${C_YELLOW}退出前提示：是否打包导出 /tmp/vpskit（包含缓存脚本与日志）？${C_RESET}"
				echo "  y. 导出为 tar.gz"
				echo "  d. 清空脚本产生的全部内容（cache/log/workdir）并退出"
				echo "  n. 不导出，直接退出"
				read -r -p "选择 [y/d/N]: " ex </dev/tty || true
				ex="${ex:-N}"

				case "${ex^^}" in
				Y) export_vpskit_bundle ;;
				D) cleanup_all ;;
				N | "") : ;;
				*) warn "未知选项：$ex，按 N 处理" ;;
				esac
			fi
			return
		fi

		[[ "$opt" == "u" ]] && {
			reset_cache
			continue
		}

		if [[ ! "$opt" =~ ^[0-9]+$ ]] || [[ -z "${n_list[$opt]:-}" ]]; then
			echo -e "${C_RED}无效输入${C_RESET}"
			sleep 0.4
			continue
		fi

		if [[ "${d_list[$opt]}" == "true" ]]; then
			echo -e "${C_RED}当前环境（$VIRT）不支持该功能：${reason_list[$opt]}${C_RESET}"
			sleep 0.8
			continue
		fi

		if [[ "${y_list[$opt]}" == "submenu" ]]; then
			render_menu "${t_list[$opt]}"
		else
			run_task "${n_list[$opt]}" "${t_list[$opt]}"
		fi
	done
}

# ==================================================
# 6) Main
# ==================================================
parse_args "$@"
normalize_base_url
need_cmd curl

init_dirs
init_menu_data
pre_flight
render_menu "MAIN"