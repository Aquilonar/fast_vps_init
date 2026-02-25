#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# VPSKit Bootstrap
# ==================================================

# 你的仓库 raw 地址
BASE_URL="https://raw.githubusercontent.com/Aquilonar/fast_vps_init/main"

# 主脚本路径（仓库里的）
MAIN_PATH="main.sh"

# 安装目录（建议固定）
INSTALL_DIR="/tmp/vpskit"

# ==================================================
# 检查 root
# ==================================================
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❌ 请使用 root 运行：sudo bash install.sh"
  exit 1
fi

# ==================================================
# 创建目录
# ==================================================
echo ">>> 初始化目录: $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ==================================================
# 下载主脚本
# ==================================================
echo ">>> 下载主程序..."

curl -fSL \
  --proto '=https' \
  --tlsv1.2 \
  -o main.sh \
  "${BASE_URL}/${MAIN_PATH}"

chmod +x main.sh

# ==================================================
# 标记来源（可选）
# ==================================================
cat > .meta <<EOF
install_time=$(date '+%F %T')
source=${BASE_URL}/${MAIN_PATH}
EOF

# ==================================================
# 进入运行
# ==================================================
echo ">>> 启动 VPSKit..."
echo

exec bash ./main.sh