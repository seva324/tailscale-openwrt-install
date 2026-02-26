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

echo "下载 Tailscale $TAILSCALE_VERSION..."
curl -fsSL "https://pkgs.tailscale.com/stable/${DOWNLOAD_FILE}" -o /tmp/tailscale.tgz

echo "解压..."
cd /tmp
rm -rf tailscale_${TAILSCALE_VERSION}*
tar -xzf tailscale.tgz

echo "安装到 $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp tailscale_${TAILSCALE_VERSION}_*/tailscale "$INSTALL_DIR/"
cp tailscale_${TAILSCALE_VERSION}_*/tailscaled "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*

echo "启动 tailscaled..."
killall -9 tailscaled tailscale 2>/dev/null || true
mkdir -p "$INSTALL_DIR/state"

"$INSTALL_DIR/tailscaled" --tun=userspace-networking \
    --statedir="$INSTALL_DIR/state" \
    --socket="$INSTALL_DIR/tailscaled.sock" &

echo "等待启动..."
sleep 3

echo "登录 Tailscale..."
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
