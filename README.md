# Tailscale 一键安装脚本

适用于小米路由器/OpenWrt 等嵌入式设备的 Tailscale 一键安装脚本。

## 支持的架构

- aarch64 / arm64 (大多数现代路由器)
- armv7l / armhf
- x86_64
- i386 / i686

## 安装方法

```bash
curl -fsSL https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/install-tailscale.sh | sh -s -- 你的authkey
```

**示例：**
```bash
curl -fsSL https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/install-tailscale.sh | sh -s -- tskey-auth-xxxxx
```

## 获取 Auth Key

1. 访问 https://login.tailscale.com/admin/settings/keys
2. 点击 "Generate new key"
3. 复制生成的 key

## 开机自启

安装完成后，脚本会显示自启命令。将其添加到路由器启动脚本中即可。

## 注意事项

- 脚本使用 `userspace-networking` 模式，不需要内核模块
- 安装目录：`/data/other/tailscale`
- 状态目录：`/data/other/tailscale/state`
