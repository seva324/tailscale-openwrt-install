# 手工安装清单：ShellCrash + sing-box Tailscale（不用脚本）

适用于已装 ShellCrash、空间紧张的路由器。全程用 ShellCrash 自带菜单，**不需要跑任何安装脚本**。

---

## 0. 前置：确认平台

```sh
uname -m                          # aarch64 -> 用 arm64 版
ls /lib/ld-musl-* 2>/dev/null     # 有输出 = musl
```

本清单的内核是 **musl + arm64**。glibc 版在这些机器上跑不起来。

---

## 1. 装内核

**菜单路径：**

```
主菜单 → 9（更新/升级）
      → 2) 内核
      → 6) 自定义内核
      → 9) 自定义链接
      → 粘贴下面的 URL
      → 弹出内核类型菜单，选  3) Singbox     ← 关键，别选错
```

**URL（按架构选）：**

| 架构 | URL |
|---|---|
| arm64 / aarch64 | `https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/core/sing-box-min-arm64.gz` |

> **为什么必须选 `3) Singbox`**：ShellCrash 用 `crashcore` 是否含 `singbox` 来决定启动命令。
> 选错的话会把 sing-box 二进制套上 mihomo 的参数（`-d ... -f config.yaml`）启动，直接崩。

> **URL 后缀必须是 `.gz` / `.tar.gz` / `.upx`** —— ShellCrash 靠后缀判断解压方式。
> 这条限制也意味着：**任何自编译的内核只要后缀对，都能这样挂进来。**

---

## 2. 改 DNS 模式（不改必挂）

```sh
sed -i 's/^dns_mod=.*/dns_mod=fake-ip/' /data/other_vol/ShellCrash/configs/ShellCrash.cfg
```

路径按实际安装目录调整（常见：`/data/other_vol/ShellCrash`、`/data/ShellCrash`、`/data/other/ShellCrash`）。

> **为什么**：`dns_mod=mix` 时 ShellCrash 会生成一个远程 rule_set，其 `http_client` 指向一个空配置的
> DIRECT 出站，**sing-box 1.14 会直接拒绝启动**（`http_client detour not found`）。
> 这个坑我们踩过两次。

---

## 3. 配 Tailscale

**菜单路径：** `主菜单 → 7) 访问与控制 → 6) 配置Tailscale内网穿透`

依次设置：

| 菜单项 | 填什么 |
|---|---|
| 设置密钥（Auth Key） | `tskey-auth-...` |
| 设置设备名称 | **每台唯一**，如 `mi-wenzhou`、`mi-home` |
| 通告路由内网地址（Subnet） | 开 —— 让 tailnet 能访问这台后面的局域网 |
| 通告路由全部流量（EXIT-NODE） | 按需 —— 想让它当出口就开 |

**auth key 建议**：Reusable ✅ / Ephemeral ❌ / Pre-approved ✅ / Expiry 设为 Never。
配了 tag + ACL 里的 `autoApprovers` 可以免去后台逐台批准。

> **两个开关别同时开**：sing-box 不允许既"通告 exit node"又"使用 exit node"，会直接报错。

---

## 4. 补一条路由规则（推荐）

ShellCrash 生成的配置里**没有**这条，缺了它，从 tailnet 访问局域网设备会被丢给代理兜底：

```sh
GW=/data/other_vol/ShellCrash/jsons/route.json
mkdir -p "$(dirname "$GW")"
cat > "$GW" <<'EOF'
{
  "route": {
    "rules": [
      { "inbound": ["ts-ep"], "ip_is_private": true, "outbound": "DIRECT" }
    ]
  }
}
EOF
```

作用：**私有 IP（局域网设备）本地直达，其余全部落进 ShellCrash 的规则链**（也就是你要的"tailnet 流量走 ShellCrash 规则"）。

---

## 5. 重启并验证

```sh
/etc/init.d/shellcrash restart
```

```sh
pidof CrashCore
```

```sh
df -h /data
```

```sh
curl -s -o /dev/null -w 'HTTP=%{http_code}\n' --max-time 15 -x http://127.0.0.1:7890 https://www.google.com/generate_204
```

期望：`pidof` 有输出、代理自检返回 **HTTP=204**。

---

## 6. 后台批准

https://login.tailscale.com/admin/machines → 找到新节点 → 批准 **Subnet routes** 和 **Exit node**。

> 不批准的话，子网访问和出口都不可用。这也是为什么未批准的节点在别人的
> `tailscale status` 里看不到 "offers exit node" —— **未批准的路由不会出现在其他节点的视图里**。

---

## 注意事项汇总

| # | 事项 | 说明 |
|---|---|---|
| 1 | `crashcore` 必须是 `singbox` | 否则启动参数是 mihomo 形式 |
| 2 | `dns_mod` 必须是 `fake-ip` | 否则 sing-box 1.14 拒绝启动 |
| 3 | URL 后缀必须 `.gz`/`.tar.gz`/`.upx` | 决定解压方式 |
| 4 | 设备名每台唯一 | 重名会被自动改成 `xxx-1` |
| 5 | 同机别跑两个 Tailscale 节点 | 有独立 `tailscaled` 就先停掉并禁自启 |
| 6 | 空间要够 | 压缩包 ~19MB + 解压到 /tmp 峰值 ~71MB |
| 7 | 用户态 vs 内核态 | 见下 |

### 关于用户态 / 内核态

ShellCrash 生成的端点是**用户态**（没有 `system_interface`），含义：

- ✅ **从 tailnet 连进这台**：正常（SSH、访问局域网设备都可以）
- ❌ **这台路由器的 shell / 局域网设备主动访问 tailnet**：不行 —— 路由器 OS 没有 `100.64.0.0/10` 的路由

想让局域网设备也能主动访问 tailnet，需要在 `jsons/endpoints.json` 里加 `"system_interface": true`（内核态 TUN，需要 `/dev/net/tun`）。

### ⚠️ 一个容易踩的冲突

ShellCrash 的生成逻辑有个守卫：

```sh
[ "$ts_service" = ON ] && ! grep -q '"tailscale"' "$CRASHDIR"/jsons/endpoints.json && {
    ... 生成 tailscale.json ...
}
```

**只要 `$CRASHDIR/jsons/endpoints.json` 存在且含 `"tailscale"`，ShellCrash 就跳过生成**，
菜单 7-6 里改的 auth key / 节点名 / 子网**全部不生效**。

- 想继续用 7-6 菜单管 → `rm $CRASHDIR/jsons/endpoints.json`
- 想自己控制（能用 `system_interface` 等高级字段）→ 继续手改这个文件

---

## 排错

```sh
pidof CrashCore                                          # 内核活着吗
df -h /data                                              # 空间
```

```sh
tail -30 /tmp/ShellCrash/ShellCrash.log
```

```sh
cat /data/other_vol/ShellCrash/configs/ShellCrash.cfg | grep -E 'crashcore|dns_mod|ts_service'
```

```sh
cat /data/other_vol/ShellCrash/jsons/endpoints.json      # 端点配置
```

```sh
ls -l /data/other_vol/ShellCrash/CrashCore.*             # 内核文件
```

常见症状对照：

| 症状 | 原因 |
|---|---|
| `Tailscale is not included in this build` | 内核没编 `with_tailscale`，换本清单的内核 |
| `legacy tun address fields are deprecated` | 用的订阅转换器输出了老格式（inbounds 会被 ShellCrash 重建，一般无害） |
| `initialize rule_set: http_client detour not found` | `dns_mod` 不是 `fake-ip` |
| 服务"已启动"但上不了网 | 内核实际已退出，防火墙劫持形成黑洞 —— 先 `/etc/init.d/shellcrash stop` 恢复 |
| 节点不出现在 tailnet | 状态目录权限/路径问题，看 `$CRASHDIR/tailscale/tailscaled.state` 是否生成 |

---

## 内核是怎么编的

`.github/workflows/build-minimal-singbox.yml`，从 `SagerNet/sing-box` 源码编译：

```
with_gvisor,with_quic,with_utls,with_wireguard,with_clash_api,with_tailscale
```

砍掉了官方版里体积最大的一批：`with_naive_outbound`（要 CGO + cronet）、`with_openvpn`、
`with_openconnect`、`with_usbip`、`with_cloudflared`、`with_ccm`、`with_ocm`。

结果：**18.96MB(gz) / 54.7MB(裸)**，对比官方 arm64 的 28.4MB / 85.9MB。
官方版塞不进 40MB 的 `/data`，这个可以。

改了 tag 或版本后重新触发 workflow，产物会自动提交到 `core/`。
