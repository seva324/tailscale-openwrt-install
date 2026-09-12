#!/bin/sh
# ============================================================
# ShellCrash + sing-box Tailscale 一键安装
# 适用于小米路由器 / OpenWrt 等空间紧张的嵌入式设备
#
# 思路：不装独立的 tailscale 二进制，改用 sing-box 内核自带的
#       tailscale endpoint（tsnet），由 ShellCrash 原生管理。
#
# 用法：
#   curl -fsSL <url> -o /tmp/x.sh && sh /tmp/x.sh --auth-key tskey-xxx --hostname mi-home
#   sh /tmp/x.sh --apply          # 确认无误后真正执行
#   sh /tmp/x.sh --rollback       # 回滚
#   sh /tmp/x.sh --status         # 查看状态
#
# 作者注释：默认不做任何破坏性操作，必须显式 --apply。
# ============================================================

set -u

# ---------------- 常量 ----------------
SB_VERSION="1.14.0"
BACKUP_ROOT="/tmp/sc-ts-backup"
WORKDIR="/tmp/sc-ts-install"
# 仓库里预编译的最小版内核（由 .github/workflows/build-minimal-singbox.yml 产出）
MINIMAL_BASE="https://raw.githubusercontent.com/seva324/tailscale-openwrt-install/main/core"

# ---------------- 参数 ----------------
AUTH_KEY=""
HOSTNAME_ARG=""
SUBNETS=""
EXIT_NODE=0
SYSTEM_TUN=0
MODE="preflight"      # preflight | apply | rollback | status
CORE_URL=""
CORE_FILE=""

usage() {
    cat <<'EOF'
用法: sh install-sc-tailscale.sh [选项]

  --auth-key KEY      Tailscale auth key (tskey-auth-...)
  --hostname NAME     节点名，每台路由器必须唯一 (如 mi-home / mi-office)
  --subnet CIDR       要通告的网段，可逗号分隔 (默认自动探测局域网)
  --exit-node         同时通告为出口节点
  --system-tun        使用内核态 TUN (更接近原生 tailscale；需 /dev/net/tun)
  --apply             真正执行安装 (默认只做 preflight 检查)
  --rollback          回滚到安装前状态
  --status            查看当前状态
  --core-url URL      自定义内核下载地址
  --core-file PATH    使用本地已下载的内核压缩包
  -h, --help          显示帮助

不传 --auth-key / --hostname 时会交互式询问。
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --auth-key)   AUTH_KEY="$2"; shift 2 ;;
        --hostname)   HOSTNAME_ARG="$2"; shift 2 ;;
        --subnet)     SUBNETS="$2"; shift 2 ;;
        --exit-node)  EXIT_NODE=1; shift ;;
        --system-tun) SYSTEM_TUN=1; shift ;;
        --apply)      MODE="apply"; shift ;;
        --rollback)   MODE="rollback"; shift ;;
        --status)     MODE="status"; shift ;;
        --core-url)   CORE_URL="$2"; shift 2 ;;
        --core-file)  CORE_FILE="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

# ---------------- 输出helpers ----------------
say()  { printf '%s\n' "$*"; }
info() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*"; }
die()  { err "$*"; exit 1; }

# ---------------- 定位 ShellCrash ----------------
find_crashdir() {
    for d in /data/other_vol/ShellCrash /data/other/ShellCrash /data/ShellCrash \
             /etc/ShellCrash /usr/share/ShellCrash /root/.config/ShellCrash \
             /extdisks/sda1/ShellCrash /mnt/sda1/ShellCrash; do
        if [ -f "$d/configs/ShellCrash.cfg" ]; then
            printf '%s\n' "$d"; return 0
        fi
    done
    # 兜底：全盘找一个 configs/ShellCrash.cfg
    _hit=$(find /data /tmp /etc /usr/share -maxdepth 4 -name ShellCrash.cfg -path '*/configs/*' 2>/dev/null | head -1)
    if [ -n "$_hit" ]; then
        printf '%s\n' "$(dirname "$(dirname "$_hit")")"; return 0
    fi
    return 1
}

[ "$(id -u)" = "0" ] || die "需要 root 运行"

CRASHDIR=$(find_crashdir) || die "找不到 ShellCrash 安装目录"
BINDIR=$(sed -n 's/^BINDIR=//p' "$CRASHDIR/configs/command.env" 2>/dev/null)
TMPDIR_SC=$(sed -n 's/^TMPDIR=//p' "$CRASHDIR/configs/command.env" 2>/dev/null)
[ -z "$BINDIR" ] && BINDIR="$CRASHDIR"
[ -z "$TMPDIR_SC" ] && TMPDIR_SC="/tmp/ShellCrash"
CFG="$CRASHDIR/configs/ShellCrash.cfg"

getcfg() { sed -n "s/^$1=//p" "$CFG" 2>/dev/null | head -1 | sed "s/^'//; s/'$//" ; }
crashcore=$(getcfg crashcore)
core_v=$(getcfg core_v)
mix_port=$(getcfg mix_port); [ -z "$mix_port" ] && mix_port=7890

# ---------------- status ----------------
if [ "$MODE" = "status" ]; then
    say "=== ShellCrash / Tailscale 状态 ==="
    say "安装目录   : $CRASHDIR"
    say "内核目录   : $BINDIR"
    say "当前内核   : ${crashcore:-未知}  ${core_v:-}"
    say "tailscale  : $(getcfg ts_service 2>/dev/null || echo '(未设置)')"
    say ""
    say "--- 配置中的 Tailscale 参数 ---"
    if [ -f "$CRASHDIR/configs/gateway.cfg" ]; then
        grep -E '^ts_' "$CRASHDIR/configs/gateway.cfg" | sed 's/\(ts_auth_key=.\{0,12\}\).*/\1...(隐藏)/'
    else
        say "(无 gateway.cfg)"
    fi
    say ""
    say "--- 内核文件 ---"
    ls -l "$BINDIR"/CrashCore.* 2>/dev/null || say "(无)"
    say ""
    say "--- 自定义 JSON 覆盖 ---"
    ls -l "$CRASHDIR/jsons/"*.json 2>/dev/null || say "(无)"
    say ""
    say "--- 进程 ---"
    ps 2>/dev/null | grep '[C]rashCore' | head -3 || say "(CrashCore 未运行)"
    exit 0
fi

# ---------------- rollback ----------------
if [ "$MODE" = "rollback" ]; then
    [ -d "$BACKUP_ROOT" ] || die "没有找到备份目录 $BACKUP_ROOT（可能未执行过安装，或已重启过路由器）"
    info "从 $BACKUP_ROOT 回滚..."
    /etc/init.d/shellcrash stop 2>/dev/null || "$CRASHDIR"/start.sh stop 2>/dev/null
    [ -f "$BACKUP_ROOT/ShellCrash.cfg" ] && cp -f "$BACKUP_ROOT/ShellCrash.cfg" "$CFG"
    [ -f "$BACKUP_ROOT/gateway.cfg" ] && cp -f "$BACKUP_ROOT/gateway.cfg" "$CRASHDIR/configs/gateway.cfg"
    [ -d "$BACKUP_ROOT/ys" ] && rm -rf "$CRASHDIR/jsons" && cp -rf "$BACKUP_ROOT/ys" "$CRASHDIR/jsons"
    [ -f "$BACKUP_ROOT/command.env" ] && cp -f "$BACKUP_ROOT/command.env" "$CRASHDIR/configs/command.env"
    [ -f "$BACKUP_ROOT/core" ] && { rm -f "$BINDIR"/CrashCore.*; cp -f "$BACKUP_ROOT/core" "$BINDIR/$(basename "$BACKUP_ROOT/core")"; }
    /etc/init.d/shellcrash start 2>/dev/null || "$CRASHDIR"/start.sh start 2>/dev/null
    ok "回滚完成。建议手动确认：sh $0 --status"
    exit 0
fi

# ============================================================
#  以下为 preflight / apply 共用的检查
# ============================================================

say ""
say "============================================"
say " ShellCrash + sing-box Tailscale 安装程序"
say "============================================"
say ""

# ---- 1. 平台检查 ----
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)   SB_ARCH="arm64" ;;
    armv7l|armv7|armhf) SB_ARCH="armv7" ;;
    x86_64|amd64)    SB_ARCH="amd64" ;;
    i386|i686)       SB_ARCH="386" ;;
    *) die "暂不支持的架构: $ARCH" ;;
esac

LIBC="gnu"
[ -e /lib/ld-musl-*.so.1 ] && LIBC="musl"
if [ "$LIBC" = "musl" ]; then SB_FLAVOR="musl"; else SB_FLAVOR="glibc"; fi

info "架构: $ARCH  ->  sing-box linux-$SB_ARCH-$SB_FLAVOR"

# ---- 2. 空间检查 ----
# 峰值占用：下载包 + 解压后的裸二进制（最小版 .gz 约 18MB→45MB；官方 tar.gz 28MB→86MB）
need_kb=102400     # 100MB：够最小版流程；官方 tar.gz 流程会在解压前再精确校验一次
tmp_avail=$(df -P "$TMPDIR_SC" 2>/dev/null | awk 'NR==2{print $4}')
case "$tmp_avail" in ''|*[!0-9]*) tmp_avail=$(df -P /tmp 2>/dev/null | awk 'NR==2{print $4}') ;; esac
case "$tmp_avail" in ''|*[!0-9]*) tmp_avail=0 ;; esac
[ "$tmp_avail" -lt "$need_kb" ] && die "临时目录空间不足：需要约 $((need_kb/1024))MB，实际 $((tmp_avail/1024))MB（可清理 $TMPDIR_SC 下的旧文件）"

bindir_avail=$(df -P "$BINDIR" 2>/dev/null | awk 'NR==2{print $4}')
case "$bindir_avail" in ''|*[!0-9]*) bindir_avail=0 ;; esac
old_core_size=0
[ -f "$BINDIR/CrashCore.raw" ] && old_core_size=$(wc -c < "$BINDIR/CrashCore.raw")
info "临时空间: $((tmp_avail/1024))MB 可用 | 内核目录: $((bindir_avail/1024))MB 可用（旧内核占 $((old_core_size/1024/1024))MB）"

# ---- 3. 提示现有独立 tailscale ----
if [ -n "$(pidof tailscaled 2>/dev/null)" ]; then
    warn "检测到独立的 tailscaled 正在运行。"
    warn "同一台机器跑两个 Tailscale 节点会互相抢路由，apply 前请先停掉："
    warn "    /etc/init.d/tailscale disable 2>/dev/null; killall tailscaled"
    warn "    crontab -l | grep -v bootstrap.sh | crontab -   # 若有每分钟拉起它的任务"
    say ""
fi

# ---- 4. 参数收集（交互式） ----
if [ "$MODE" = "apply" ] || [ "$MODE" = "preflight" ]; then
    # 升级场景：优先复用 gateway.cfg 里已有的值，没有再交互询问
    _gw="$CRASHDIR/configs/gateway.cfg"
    if [ -z "$AUTH_KEY" ] && [ -f "$_gw" ]; then
        AUTH_KEY=$(sed -n 's/^ts_auth_key=//p' "$_gw" 2>/dev/null | head -1)
        [ -n "$AUTH_KEY" ] && info "复用 gateway.cfg 中已有的 auth key"
    fi
    if [ -z "$HOSTNAME_ARG" ] && [ -f "$_gw" ]; then
        HOSTNAME_ARG=$(sed -n 's/^ts_hostname=//p' "$_gw" 2>/dev/null | head -1)
        [ -n "$HOSTNAME_ARG" ] && info "复用 gateway.cfg 中已有的节点名: $HOSTNAME_ARG"
    fi

    if [ -z "$AUTH_KEY" ] && [ "$MODE" = "apply" ]; then
        say "获取 auth key: https://login.tailscale.com/admin/settings/keys"
        say "（建议 Reusable + 关闭 Ephemeral + Expiry 设为 Never）"
        printf '请输入 Tailscale auth key: '
        read -r AUTH_KEY
    fi
    if [ -z "$HOSTNAME_ARG" ] && [ "$MODE" = "apply" ]; then
        printf '请输入本机节点名（每台唯一，如 mi-home）: '
        read -r HOSTNAME_ARG
        [ -z "$HOSTNAME_ARG" ] && die "节点名不能为空"
    fi
    if [ "$MODE" = "apply" ]; then
        case "$AUTH_KEY" in
            tskey-auth-*) ;;
            *) die "auth key 格式不对，应以 tskey-auth- 开头" ;;
        esac
        case "$HOSTNAME_ARG" in
            *[!a-zA-Z0-9-]*) die "节点名只能包含字母、数字和连字符" ;;
        esac
    fi
fi

# ---- 5. 自动探测局域网网段 ----
if [ -z "$SUBNETS" ]; then
    SUBNETS=$(ip route show scope link 2>/dev/null \
        | grep -Ev 'default|wan|utun|iot|peer|docker|podman|virbr|vnet|ovs|veth|tailscale|multicast|anycast' \
        | awk '{print $1}' | grep '/' | sort -u | tr '\n' ',' | sed 's/,$//')
fi
[ -z "$SUBNETS" ] && warn "未能自动探测局域网网段，将不通告子网路由（可稍后用 --subnet 指定）"
[ -n "$SUBNETS" ] && info "将通告的网段: $SUBNETS"

# ---- 6. 准备内核 ----
mkdir -p "$WORKDIR"
SB_TGZ="$WORKDIR/sb.tgz"
TARBALL="sing-box-${SB_VERSION}-linux-${SB_ARCH}-${SB_FLAVOR}.tar.gz"

if [ -n "$CORE_FILE" ]; then
    [ -f "$CORE_FILE" ] || die "指定的内核文件不存在: $CORE_FILE"
    cp -f "$CORE_FILE" "$SB_TGZ"
    case "$CORE_FILE" in
        *.tar.gz|*.tgz) SRC_KIND="tar.gz" ;;
        *.gz)           SRC_KIND="gz" ;;
        *)              SRC_KIND="tar.gz" ;;
    esac
    printf '%s\n' "$SRC_KIND" > "$WORKDIR/.srckind"
    info "使用本地内核包: $CORE_FILE（格式: $SRC_KIND）"
elif [ -s "$SB_TGZ" ]; then
    SRC_KIND=$(cat "$WORKDIR/.srckind" 2>/dev/null || echo tar.gz)
    info "复用已下载的内核包（格式: $SRC_KIND）"
else
    # 候选地址：优先仓库里预编译的最小版（约为官方版 2/3 体积，省闪存也省内存），
    # 拉不到再退回官方 release。
    MIN_URL="$MINIMAL_BASE/sing-box-min-${SB_ARCH}.gz"
    OFFICIAL_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${TARBALL}"
    if [ -n "$CORE_URL" ]; then
        CANDIDATES="$CORE_URL"
    else
        CANDIDATES="$MIN_URL $OFFICIAL_URL"
    fi
    info "下载内核 ..."
    dl_ok=0
    for URL in $CANDIDATES; do
        # 包格式必须按「源地址」判断，不能按本地临时文件名（本地固定叫 sb.tgz）
        case "$URL" in
            *.tar.gz|*.tgz) SRC_KIND="tar.gz" ;;
            *.gz)           SRC_KIND="gz" ;;
            *)              SRC_KIND="tar.gz" ;;
        esac
        info "  尝试: $URL"
        if command -v curl >/dev/null 2>&1; then
            # 方式1: 走本机代理（ShellCrash 自身代理，国内最可靠）
            curl -sL --max-time 240 -x "http://127.0.0.1:${mix_port}" -o "$SB_TGZ" "$URL" 2>/dev/null
            _sz=$(wc -c "$SB_TGZ" 2>/dev/null | awk '{print $1}')
            if [ "${_sz:-0}" -gt 5000000 ]; then dl_ok=1; ok "  经本机代理下载成功"; break; fi
            # 方式2: 直连
            curl -sL --max-time 300 -o "$SB_TGZ" "$URL" 2>/dev/null
            _sz=$(wc -c "$SB_TGZ" 2>/dev/null | awk '{print $1}')
            if [ "${_sz:-0}" -gt 5000000 ]; then dl_ok=1; ok "  直连下载成功"; break; fi
        fi
        if command -v wget >/dev/null 2>&1; then
            wget -q --timeout=240 -O "$SB_TGZ" "$URL" 2>/dev/null
            _sz=$(wc -c "$SB_TGZ" 2>/dev/null | awk '{print $1}')
            if [ "${_sz:-0}" -gt 5000000 ]; then dl_ok=1; ok "  wget 下载成功"; break; fi
        fi
        warn "  该地址失败或返回内容过小"
    done
    [ "$dl_ok" = 1 ] || die "内核下载失败。可手动下载后放入路由器，再用 --core-file 指定"
    printf '%s\n' "$SRC_KIND" > "$WORKDIR/.srckind"
fi

[ -s "$SB_TGZ" ] || die "内核包为空或不存在"

info "解压并校验..."
_src_kb=$(( $(wc -c "$SB_TGZ" 2>/dev/null | awk '{print $1}') / 1024 ))
_need_kb=$(( _src_kb * 4 ))          # 实测最小版 19MB->55MB；保留 4 倍余量
_have_kb=$(df -P "$TMPDIR_SC" 2>/dev/null | awk 'NR==2{print $4}')
case "$_have_kb" in ''|*[!0-9]*) _have_kb=0 ;; esac
[ "$_have_kb" -lt "$_need_kb" ] && die "解压空间不足：需要约 $((_need_kb/1024))MB，实际 $((_have_kb/1024))MB"
rm -rf "$WORKDIR/x" && mkdir -p "$WORKDIR/x"
SRC_IS_GZ=0
case "$SRC_KIND" in
    tar.gz) tar -xzf "$SB_TGZ" -C "$WORKDIR/x" || die "解压失败（文件可能损坏）" ;;
    gz)     gunzip -c "$SB_TGZ" > "$WORKDIR/x/sing-box" || die "解压失败（文件可能损坏）"; SRC_IS_GZ=1 ;;
    *)      die "无法识别的内核包格式: ${SRC_KIND:-未知}（需 .tar.gz 或 .gz）" ;;
esac
SB_BIN=$(find "$WORKDIR/x" -name sing-box -type f 2>/dev/null | head -1)
[ -n "$SB_BIN" ] || die "解压后找不到 sing-box 二进制"

chmod +x "$SB_BIN" 2>/dev/null
VER_OUT=$("$SB_BIN" version 2>&1)
echo "$VER_OUT" | grep -q 'with_tailscale' || die "该内核没有编译 Tailscale 支持（with_tailscale）！$VER_OUT"
echo "$VER_OUT" | grep -q 'sing-box' || die "二进制无法在本机运行：$VER_OUT"
computed_ver=$(echo "$VER_OUT" | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -1)
[ -z "$computed_ver" ] && computed_ver="$SB_VERSION"
ok "内核可用：sing-box $computed_ver（含 with_tailscale）"

# ---- 7. 压缩 ----
SB_GZ="$WORKDIR/CrashCore.gz"
if [ "$SRC_IS_GZ" = 1 ]; then
    # 源文件本身就是 gzip 过的二进制，直接复用，省一次压缩
    info "复用已压缩的内核（源包即 .gz）"
    cp -f "$SB_TGZ" "$SB_GZ" || die "复制内核失败"
elif [ -s "$SB_GZ" ] && [ "$SB_GZ" -nt "$SB_TGZ" ]; then
    info "复用已压缩的内核"
else
    info "压缩内核（视 CPU 需 10-60 秒）..."
    gzip -c "$SB_BIN" > "$SB_GZ" || die "压缩失败"
fi
new_gz_size=$(wc -c < "$SB_GZ")
info "压缩后大小: $((new_gz_size/1024/1024))MB"

# ---- 闪存装不下就降级到"小闪存模式" ----
# ShellCrash 的小闪存模式：BINDIR=TMPDIR，核心归档放内存，完全不占闪存。
# 代价：每次重启后 ShellCrash 找不到归档，会重新下载内核。
need_kb=$(( new_gz_size / 1024 + 2048 ))          # 归档大小 + 2MB 余量
freed_kb=$(( old_core_size / 1024 / 2 ))          # ubifs 有透明压缩，保守按 2:1 估
avail_after=$(( bindir_avail + freed_kb ))

if [ "$avail_after" -lt "$need_kb" ]; then
    warn "内核目录空间不足：删掉旧内核后预计可用 ${avail_after}KB，需要 ${need_kb}KB"
    warn "将启用【小闪存模式】：核心归档改放 $TMPDIR_SC（内存），不占闪存"
    warn "代价：每次重启后需重新下载内核（约 $((new_gz_size/1024/1024))MB）"
    SMALL_FLASH=1
    BINDIR="$TMPDIR_SC"
    mkdir -p "$BINDIR"
    info "内核目录已改为: $BINDIR"
else
    SMALL_FLASH=0
fi

# ---- 8. 生成 sing-box 配置（不切换内核，仅预生成并校验）----
SINGBOX_CFG="$CRASHDIR/jsons/config.json"
if [ -s "$SINGBOX_CFG" ]; then
    ok "已存在 sing-box 配置，跳过生成"
else
    info "预生成 sing-box 配置（从订阅源转换）..."
    (
        # ShellCrash 的库没有为 set -u 编写，必须先关掉 nounset
        set +u
        cd "$CRASHDIR" || exit 1
        . ./libs/get_config.sh
        . ./libs/set_config.sh 2>/dev/null
        . ./libs/logger.sh 2>/dev/null
        . ./libs/compare.sh 2>/dev/null
        . ./libs/web_get.sh 2>/dev/null
        . ./libs/web_get_bin.sh 2>/dev/null
        . ./libs/urlencode.sh 2>/dev/null
        . ./libs/i18n.sh 2>/dev/null
        . ./libs/check_cmd.sh 2>/dev/null
        . ./libs/check_target.sh
        crashcore=singbox
        core_v="$computed_ver"
        target=singbox; format=json
        core_config="$CRASHDIR/jsons/config.json"
        . ./starts/core_config.sh
        mkdir -p "$CRASHDIR/jsons"
        get_core_config
    )
    if [ ! -s "$SINGBOX_CFG" ]; then
        err "sing-box 配置生成失败。"
        err "通常是订阅源不可用或被限流（当前订阅: ${Url:-未知}）。"
        die "已中止，未改动任何现有配置。可稍后重试，或在 ShellCrash 菜单 6 里手动生成后再跑本脚本。"
    fi
    ok "sing-box 配置已生成: $SINGBOX_CFG"
fi

info "校验配置（ShellCrash 会用 format 归一化，inbounds 稍后由它自己重建）..."
# 注意：不能直接用 check 校验这份原始配置。订阅转换器输出的是老格式
# （tun 用 inet4_address 等已在 sing-box 1.12 移除的字段），而 ShellCrash 的
# extract_base_jsons 只抽取 outbounds/providers/route，inbounds 会被 gen_inbounds 整个重建。
# 所以这里用 format 能否解析作为判据。
if "$SB_BIN" format -c "$SINGBOX_CFG" > "$WORKDIR/format.json" 2>"$WORKDIR/format.err"; then
    node_count=$(grep -o '"type":"[a-z0-9]*"' "$SINGBOX_CFG" 2>/dev/null | wc -l)
    ok "内核可成功解析并归一化该配置（$(( $(wc -c < "$SINGBOX_CFG") / 1024 ))KB，约 ${node_count} 个条目）"
else
    err "内核无法解析该订阅配置："
    head -5 "$WORKDIR/format.err"
    die "订阅源生成的 sing-box 配置与本内核不兼容，已中止（未改动任何东西）。"
fi

# ============================================================
#  preflight 到此为止
# ============================================================
if [ "$MODE" = "preflight" ]; then
    say ""
    ok "预检全部通过，尚未改动任何东西。"
    say ""
    say "将要执行的操作（apply）："
    say "  1. 备份 ShellCrash.cfg / gateway.cfg / jsons/ 到 $BACKUP_ROOT"
    say "  2. 替换内核为 sing-box $computed_ver（压缩存放，运行时解压到 $TMPDIR_SC）"
    say "  3. 设 crashcore=singbox、ts_service=ON"
    say "  4. 写 Tailscale 参数（节点名 / 密钥 / 通告网段）"
    say "  5. 重启 ShellCrash 服务"
    say ""
    say "正式执行（把下面的 auth key 和节点名换成你自己的）："
    say ""
    say "  sh $0 --apply --auth-key tskey-auth-xxxx --hostname <唯一节点名>${EXIT_NODE:+ --exit-node}"
    say ""
    exit 0
fi

# ============================================================
#  apply
# ============================================================
say ""
info "开始安装..."

# ---- 备份 ----
mkdir -p "$BACKUP_ROOT"
cp -f "$CFG" "$BACKUP_ROOT/ShellCrash.cfg"
[ -f "$CRASHDIR/configs/gateway.cfg" ] && cp -f "$CRASHDIR/configs/gateway.cfg" "$BACKUP_ROOT/gateway.cfg"
[ -d "$CRASHDIR/jsons" ] && rm -rf "$BACKUP_ROOT/ys" && cp -rf "$CRASHDIR/jsons" "$BACKUP_ROOT/ys"
[ -f "$BINDIR/CrashCore.raw" ] && cp -f "$BINDIR/CrashCore.raw" "$BACKUP_ROOT/core"
[ -f "$CRASHDIR/configs/command.env" ] && cp -f "$CRASHDIR/configs/command.env" "$BACKUP_ROOT/command.env"
ok "已备份到 $BACKUP_ROOT（回滚: sh $0 --rollback）"

# ---- 停服务体面一点：先停服务再换内核 ----
info "停止 ShellCrash..."
/etc/init.d/shellcrash stop 2>/dev/null || "$CRASHDIR"/start.sh stop 2>/dev/null
sleep 2

# ---- 安装内核 ----
info "安装内核..."
rm -f "$BINDIR"/CrashCore.raw "$BINDIR"/CrashCore.gz "$BINDIR"/CrashCore.upx "$BINDIR"/CrashCore.tar.gz
cp -f "$SB_GZ" "$BINDIR/CrashCore.gz"
rm -f "$TMPDIR_SC/CrashCore"
ok "内核已就位: $BINDIR/CrashCore.gz"

# ---- 更新启动命令（关键）----
# command.env 里默认是 mihomo 的参数（-d BINDIR -f config.yaml）。
# sing-box 必须用 run -D BINDIR -C TMPDIR/jsons，否则二进制会被套错参数启动而崩溃。
info "更新内核启动命令..."
CMDENV="$CRASHDIR/configs/command.env"
[ -f "$CMDENV" ] || : > "$CMDENV"
if grep -q '^COMMAND=' "$CMDENV" 2>/dev/null; then
    sed -i 's|^COMMAND=.*|COMMAND="$TMPDIR/CrashCore run -D $BINDIR -C $TMPDIR/jsons"|' "$CMDENV"
else
    printf 'COMMAND="$TMPDIR/CrashCore run -D $BINDIR -C $TMPDIR/jsons"\n' >> "$CMDENV"
fi
ok "启动命令: $(grep '^COMMAND=' "$CMDENV")"

# 小闪存模式下 BINDIR 也要指向内存，否则 ShellCrash 还会去闪存找归档
if [ "$SMALL_FLASH" = 1 ]; then
    if grep -q '^BINDIR=' "$CMDENV" 2>/dev/null; then
        sed -i "s|^BINDIR=.*|BINDIR=$BINDIR|" "$CMDENV"
    else
        printf 'BINDIR=%s\n' "$BINDIR" >> "$CMDENV"
    fi
    ok "小闪存模式: BINDIR=$(grep '^BINDIR=' "$CMDENV" | cut -d= -f2)"
fi

# ---- 写 ShellCrash 配置 ----
info "写入配置..."
setcfg() { # $1=key $2=value $3=file
    _f="${3:-$CFG}"
    if grep -q "^$1=" "$_f" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" "$_f"
    else
        printf '%s=%s\n' "$1" "$2" >> "$_f"
    fi
}
setcfg crashcore singbox
setcfg core_v "$computed_ver"
setcfg ts_service ON

# ---- dns_mod 必须避开 mix/route（关键）----
# ShellCrash 的 sing-box 配置生成器在 dns_mod=mix 或 route 时会生成一个远程 rule_set
# （cn.srs），并把它的 http_client 指向一个"空配置的 direct 出站"。
# sing-box 1.14 起会直接拒绝启动：
#   FATAL initialize rule-set[0]: cn: ... detour to an empty direct outbound makes no sense
# 改为 fake-ip 后该 rule_set 不再生成（fake_ip_filter 过滤仍然生效），已实测可正常启动。
_old_dns_mod=$(getcfg dns_mod)
case "$_old_dns_mod" in
    mix|route)
        setcfg dns_mod fake-ip
        ok "dns_mod: $_old_dns_mod -> fake-ip（规避 sing-box 1.14 的 rule_set 校验）"
        ;;
esac

# gateway.cfg（ShellCrash 7-6 菜单的存储位置）
GW="$CRASHDIR/configs/gateway.cfg"
[ -f "$GW" ] || : > "$GW"
setcfg ts_auth_key "$AUTH_KEY" "$GW"
setcfg ts_hostname "$HOSTNAME_ARG" "$GW"
setcfg ts_subnet true "$GW"
[ "$EXIT_NODE" = 1 ] && setcfg ts_exit_node true "$GW" || setcfg ts_exit_node false "$GW"
chmod 600 "$GW"

# ---- 自定义 endpoints.json（ShellCrash 不生成此文件时才会用它，见 sb_endpoints.sh 的守卫）----
mkdir -p "$CRASHDIR/jsons"
# 通告网段转成 JSON 数组
ROUTES_JSON=""
if [ -n "$SUBNETS" ]; then
    ROUTES_JSON=$(echo "$SUBNETS" | tr ',' '\n' | sed '/^$/d' | awk '{printf "\"%s\", ", $0}' | sed 's/, $//')
fi
SYSIF="false"; [ "$SYSTEM_TUN" = 1 ] && SYSIF="true"
cat > "$CRASHDIR/jsons/endpoints.json" <<EOF
{
  "endpoints": [
    {
      "type": "tailscale",
      "tag": "ts-ep",
      "state_directory": "$CRASHDIR/tailscale",
      "auth_key": "$AUTH_KEY",
      "hostname": "$HOSTNAME_ARG",
      "system_interface": $SYSIF,
      "advertise_routes": [ $ROUTES_JSON ],
      "advertise_exit_node": $([ "$EXIT_NODE" = 1 ] && echo true || echo false),
      "udp_timeout": "5m"
    }
  ]
}
EOF
chmod 600 "$CRASHDIR/jsons/endpoints.json"

# ---- route.json：让 tailnet 流量进 ShellCrash 规则链，仅私有网段直连 ----
cat > "$CRASHDIR/jsons/route.json" <<'EOF'
{
  "route": {
    "rules": [
      { "inbound": ["ts-ep"], "ip_is_private": true, "outbound": "DIRECT" }
    ]
  }
}
EOF

ok "配置写入完成"

# ---- 启动 ----
info "启动 ShellCrash..."
/etc/init.d/shellcrash start 2>/dev/null || "$CRASHDIR"/start.sh start 2>/dev/null
sleep 8

if [ -n "$(pidof CrashCore 2>/dev/null)" ]; then
    ok "CrashCore 已运行"
    # 代理自检：避免"服务报已启动但内核实际已死"的假象
    if command -v curl >/dev/null 2>&1; then
        code=$(curl -s -o /dev/null --max-time 15 -x "http://127.0.0.1:$mix_port" \
               https://www.google.com/generate_204 2>/dev/null)
        if [ "$code" = "204" ]; then
            ok "代理自检通过 (HTTP 204)"
        else
            warn "代理自检返回 HTTP=${code:-无响应}（可能是节点本身不通，也可能是内核已退出）"
            warn "确认内核状态： pidof CrashCore"
        fi
    fi
else
    err "CrashCore 未能启动！"
    err "请查看日志：$TMPDIR_SC/ShellCrash.log"
    err "回滚：sh $0 --rollback"
    exit 1
fi

say ""
say "=== Tailscale 状态 ==="
if [ -f "$TMPDIR_SC/ShellCrash.log" ]; then
    grep -iE 'tailscale|ts-ep|100\.' "$TMPDIR_SC/ShellCrash.log" 2>/dev/null | tail -8 || say "(日志中暂无 tailscale 记录，稍等片刻再看)"
fi
sleep 5
say ""
ok "安装完成！"
say ""
say "接下来请到 Tailscale 后台确认："
say "  1. https://login.tailscale.com/admin/machines  应出现节点「$HOSTNAME_ARG」"
if [ -n "$SUBNETS" ]; then
    say "  2. 该节点会显示待批准的 Subnet routes：$SUBNETS —— 点批准"
fi
[ "$EXIT_NODE" = 1 ] && say "  3. 该节点会显示待批准的 Exit node —— 点批准"
say ""
say "排查：sh $0 --status   回滚：sh $0 --rollback"
