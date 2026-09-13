# Tailscale 一键安装脚本

适用于小米路由器 / OpenWrt 等嵌入式设备的 Tailscale 接入脚本。

提供两种方案，按设备空间情况选择：

| | 方案 A：独立 tailscale | 方案 B：ShellCrash + sing-box |
|---|---|---|
| 脚本 | `install-tailscale.sh` | `install-sc-tailscale.sh` |
| 原理 | 部署官方 tailscaled 二进制 | 用 sing-box 内置的 tailscale endpoint |
| 额外占用 | 约 70MB（tailscaled + CLI） | 约 28MB（压缩后替换现有内核） |
| 适用 | 空间充裕的设备 | **空间紧张、已装 ShellCrash 的路由器** |
| 子网路由 / 出口节点 | 支持 | 支持 |

> **不想跑脚本、想全用 ShellCrash 自带菜单装？** 看 [MANUAL-INSTALL.md](MANUAL-INSTALL.md) —— 一份逐步清单，
> 包含菜单路径、内核 URL、必须改的配置项和排错对照表。

---

## 方案 B：ShellCrash + sing-box（推荐给空间紧张的路由器）

不安装任何独立的 tailscale 二进制，改用 **sing-box 内核内置的 tailscale endpoint**，
由 ShellCrash 原生管理。适合装不下 70MB tailscaled 的设备。

### 前置条件

- 已安装 ShellCrash（本脚本会定位其安装目录）
- 有至少约 30MB 可用闪存余量（会替换掉现有内核）
- 如需子网路由：`net.ipv4.ip_forward=1`（多数路由器默认已开）

### 使用方法

脚本**默认只做预检，不改动任何东西**。必须先跑一次预检确认没问题，再加 `--apply` 真正安装。

**第一步：预检**（只读，会下载内核并预生成配置，但不切换）

```bash
curl -fsSL https://testingcf.jsdelivr.net/gh/seva324/tailscale-openwrt-install@main/install-sc-tailscale.sh -o /tmp/inst.sh && sh /tmp/inst.sh
```

**第二步：正式安装**

```bash
sh /tmp/inst.sh --apply --auth-key tskey-auth-xxxx --hostname mi-home --subnet 192.168.31.0/24
```

不加 `--auth-key` / `--hostname` 时会交互式询问。

### 参数

```
--auth-key KEY      Tailscale auth key (tskey-auth-...)
--hostname NAME     节点名，每台路由器必须唯一（如 mi-home / mi-office）
--subnet CIDR       要通告的网段，可逗号分隔（默认自动探测局域网）
--exit-node         同时通告为出口节点
--system-tun        使用内核态 TUN（更接近原生 tailscale，需 /dev/net/tun）
--apply             真正执行安装（默认只做预检）
--rollback          回滚到安装前状态
--status            查看当前状态
--core-url URL      自定义内核下载地址
--core-file PATH    使用本地已下载的内核压缩包
```

### auth key 怎么建

到 https://login.tailscale.com/admin/settings/keys 生成，建议：

- **Reusable** ✅ —— 多台路由器共用
- **Ephemeral** ❌ —— 否则重启后变成新节点，路由审批全丢
- **Pre-approved** ✅
- **Expiry** 设为 Never —— 默认 90 天，到期后所有路由器同时掉线

配了 tag + ACL 里的 `autoApprovers` 可以免去逐台批准子网路由。

### 安装之后

1. 到 https://login.tailscale.com/admin/machines 确认节点已出现
2. 该节点会显示**待批准的 Subnet routes / Exit node**，点批准
3. 客户端需要接受路由：Windows/macOS 默认接受；**Linux/Android 要手动打开 "Use Tailscale subnets"**

### 常见问题

- **GitHub 拉不下来**：用上面的 jsDelivr 地址。`github.com` 的 release 下载在国内常不通，
  但 `raw.githubusercontent.com` 和 `testingcf.jsdelivr.net` 通常可以。
- **配置生成失败**：脚本在预检阶段就会中止，不会改动现有配置。多半是订阅源被限流，稍后重试即可。
- **安装后代理没起来**：`sh /tmp/inst.sh --rollback` 回滚，然后看 `/tmp/ShellCrash/ShellCrash.log`。
- **同机已有的独立 tailscaled**：安装前请先停掉，否则两个 Tailscale 节点会互相抢路由。
  脚本会在预检时提示。

---

## 方案 A：独立 tailscale 二进制

适用空间充裕的设备。

```bash
curl -fsSL https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/install-tailscale.sh | sh -s -- 你的authkey
```

### 支持的架构

- aarch64 / arm64（大多数现代路由器）
- armv7l / armhf
- x86_64
- i386 / i686
