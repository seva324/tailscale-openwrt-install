#!/bin/sh
# Tailscale 一键安装脚本 - 小米路由器/OpenWrt
# 使用方法: curl -fsSL https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/install-tailscale.sh | sh -s -- 你的authkey

set -e

AUTHKEY="${1:-}"
TAILSCALE_VERSION="1.94.2"
INSTALL_DIR="/data/other/tailscale"

echo "=== Tailscale 一键安装脚本 ==="
echo ""

# 检查参数
if [ -z "$AUTHKEY" ]; then
    echo "用法: curl -fsSL https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/install-tailscale.sh | sh -s -- 你的authkey"
    echo ""
    echo "获取 authkey: https://login.tailscale.com/admin/settings/keys"
    exit 1
fi

# 获取架构
ARCH=$(uname -m)
echo "检测到架构: $ARCH"

# 根据架构选择版本
case "$ARCH" in
    aarch64|arm64)
        DOWNLOAD_FILE="tailscale_${TAILSCALE_VERSION}_arm64.tgz"
        ;;
    armv7l|armhf)
        DOWNLOAD_FILE="tailscale_${TAILSCALE_VERSION}_arm.tgz"
        ;;
    x86_64)
        DOWNLOAD_FILE="tailscale_${TAILSCALE_VERSION}_amd64.tgz"
        ;;
    i386|i686)
        DOWNLOAD_FILE="tailscale_${TAILSCALE_VERSION}_386.tgz"
        ;;
    *)
        echo "不支持的架构: $ARCH"
        exit 1
        ;;
esac

echo ""
echo "[1/5] 下载 Tailscale ${TAILSCALE_VERSION}..."
echo "      文件: ${DOWNLOAD_FILE}"
echo "      大小: 约 32MB"
echo ""

# 下载函数
download_tailscale() {
    local url="https://pkgs.tailscale.com/stable/${DOWNLOAD_FILE}"
    local output="/tmp/tailscale.tgz"

    # 方式1: wget (推荐)
    echo "  尝试 wget..."
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=60 -O "$output" "$url" && return 0
    fi

    # 方式2: wget 不验证 SSL
    echo "  尝试 wget 不验证 SSL..."
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q --timeout=60 -O "$output" "$url" && return 0
    fi

    # 方式3: curl
    echo "  尝试 curl..."
    if command -v curl >/dev/null 2>&1; then
        curl -sL --connect-timeout 30 --max-time 300 -o "$output" "$url" && return 0
    fi

    # 方式4: curl 不验证 SSL
    echo "  尝试 curl 不验证 SSL..."
    if command -v curl >/dev/null 2>&1; then
        curl -ksL --connect-timeout 30 --max-time 300 -o "$output" "$url" && return 0
    fi

    # 方式5: 从 GitHub 下载
    echo "  尝试从 GitHub 下载..."
    local github_url="https://github.com/tailscale/tailscale/releases/download/v${TAILSCALE_VERSION}/${DOWNLOAD_FILE}"
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q --timeout=60 -O "$output" "$github_url" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -ksL --connect-timeout 30 --max-time 300 -o "$output" "$github_url" && return 0
    fi

    return 1
}

# 执行下载
download_tailscale

if [ $? -ne 0 ] || [ ! -s /tmp/tailscale.tgz ]; then
    echo "下载失败!"
    echo "尝试从第一台路由器复制..."
    if command -v scp >/dev/null 2>&1; then
        scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@192.168.31.1:/tmp/tailscale*.tgz /tmp/ 2>/dev/null && echo "  复制成功!" || echo "  复制失败"
    fi
    if [ ! -s /tmp/tailscale.tgz ]; then
        echo "无法下载 Tailscale，请检查网络"
        exit 1
    fi
fi

echo "  下载完成!"
echo ""
echo "[2/5] 解压..."
cd /tmp
rm -rf tailscale_${TAILSCALE_VERSION}*
tar -xzf tailscale.tgz
echo "      解压完成"

echo "[3/5] 安装到 $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp tailscale_${TAILSCALE_VERSION}_*/tailscale "$INSTALL_DIR/"
cp tailscale_${TAILSCALE_VERSION}_*/tailscaled "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*
echo "      安装完成"

echo "[4/5] 启动 tailscaled..."
killall -9 tailscaled tailscale 2>/dev/null || true
mkdir -p "$INSTALL_DIR/state"

"$INSTALL_DIR/tailscaled" --tun=userspace-networking \
    --statedir="$INSTALL_DIR/state" \
    --socket="$INSTALL_DIR/tailscaled.sock" > /tmp/tailscaled.log 2>&1 &

echo "      等待服务启动 (3秒)..."
sleep 3

# 检查是否启动成功
if ! "$INSTALL_DIR/tailscale" --socket="$INSTALL_DIR/tailscaled.sock" status >/dev/null 2>&1; then
    echo "      警告: tailscaled 可能未正常启动，尝试继续..."
fi

echo "[5/5] 登录 Tailscale..."
"$INSTALL_DIR/tailscale" --socket="$INSTALL_DIR/tailscaled.sock" up \
    --authkey="$AUTHKEY" \
    --operator=root

echo ""
echo "=== 安装完成 ==="
echo ""
"$INSTALL_DIR/tailscale" --socket="$INSTALL_DIR/tailscaled.sock" status

echo ""
echo "如需开机自启，将以下内容添加到路由器启动脚本:"
echo ""
echo "  $INSTALL_DIR/tailscaled --tun=userspace-networking --statedir=$INSTALL_DIR/state --socket=$INSTALL_DIR/tailscaled.sock &"
echo "  sleep 3"
echo "  $INSTALL_DIR/tailscale --socket=$INSTALL_DIR/tailscaled.sock up --authkey=$AUTHKEY --operator=root"
