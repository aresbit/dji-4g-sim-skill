#!/bin/sh
# dji-4g-sim-skill — 只读诊断：模块在不在、哪种模式、流量走不走得通
#
# 本脚本不修改任何状态，可以随时跑。
#
# 用法：
#   ./status.sh              全部检查（含出口实测，约几百字节流量）
#   ./status.sh --no-egress  跳过出口实测（一点流量都不想花时）
#
# 出口实测默认开启且刻意做得极小：一次 HTTP GET 一个只回 ~200 字节的
# 回显服务。它回答的是"这张卡真能出网吗"，这是本地 IP 回答不了的问题
# ——拿到 192.168.225.x 只证明模块自己的 DHCP 在工作。

set -eu

HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -P -- "${HERE}/.." && pwd)

DO_EGRESS=1
[ "${1:-}" = "--no-egress" ] && DO_EGRESS=0

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
kv()   { printf '  %-14s %s\n' "$1" "$2"; }

IFACE=""
UI_URL="http://127.0.0.1:7575"

bold "1. 设备"
USB_PRESENT=0
if ioreg -p IOUSB -w0 -l 2>/dev/null | grep -q 'idVendor" = 11427'; then
  USB_PRESENT=1
  ok "USB 层可见：BAIWANG EG25G-QDC507 (2ca3:4006)"
else
  warn "USB 层不可见。最常见原因是 USB-C 线只供电不传数据；换线再试。"
fi

IFACE=$(networksetup -listallhardwareports 2>/dev/null \
          | awk '/Hardware Port: EG25G-QDC507/{f=1} f&&/Device:/{print $2; exit}')
if [ -n "$IFACE" ]; then
  ok "网络服务 EG25G-QDC507 → ${IFACE}"
else
  warn "没有对应的网络服务（说明当前不是 CDC-ECM 上网模式）"
fi

bold "2. ModemCat 进程"
if pgrep -f "bin/modemcat-macos" >/dev/null 2>&1; then
  ok "运行中 (PID $(pgrep -f 'bin/modemcat-macos' | head -1))"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$UI_URL" 2>/dev/null || echo "---")
  kv "管理页" "${UI_URL} → HTTP ${code}"
else
  warn "未运行。启动：${ROOT}/scripts/bootstrap.sh --start"
fi
# ModemCat 以可访问的 USB AT 接口区分两种模式
LOG="$HOME/Library/Logs/ModemCat/modemcat.log"
if [ -f "$LOG" ]; then
  if tail -40 "$LOG" | grep -q "USB AT bridge opened"; then
    ok "USB AT 桥在线（短信/eSIM/AT 可用）"
  fi
  if tail -40 "$LOG" | grep -qE "LIBUSB_ERROR_(IO|PIPE|ACCESS|NO_DEVICE)"; then
    warn "近期出现 LIBUSB 错误（见 references/troubleshooting.md #2）"
  fi
fi

bold "3. 链路"
if [ -n "$IFACE" ]; then
  ip4=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
  mtu=$(ifconfig "$IFACE" 2>/dev/null | awk '/mtu/{print $NF; exit}')
  ip6=$(ifconfig "$IFACE" 2>/dev/null | awk '/inet6 2[0-9a-f]/{print $2; exit}')
  kv "IPv4" "${ip4:-无}"
  kv "MTU" "${mtu:-?}"
  if [ -n "$ip6" ]; then
    ok "IPv6 全局地址：${ip6}（拿到运营商前缀说明已附着蜂窝网）"
  else
    warn "无 IPv6 全局地址（部分运营商/SIM 本就不下发，不代表失败）"
  fi
else
  warn "当前为短信模式（usbnet=0），无网卡，这是正常的。"
fi

bold "4. 默认出口与代理抢占"
DEFAULT_IF=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')
kv "1.1.1.1 出口" "${DEFAULT_IF:-?}"
if [ -n "$IFACE" ] && [ "$DEFAULT_IF" = "$IFACE" ]; then
  ok "普通流量确实走模块"
elif [ -n "$IFACE" ]; then
  case "$DEFAULT_IF" in
    utun*)
      warn "普通流量走的是 ${DEFAULT_IF}（通常是 Clash/mihomo 等代理的 TUN），不是模块。"
      warn "模块的默认路由被 0/1、128/1 分割路由盖住了。想让流量走模块："
      warn "  · 在代理软件里把 EG25G-QDC507 指定为直连/出口，或"
      warn "  · 临时关闭 TUN 模式，让 en* 的默认路由生效"
      ;;
    *) warn "普通流量走 ${DEFAULT_IF}，不是模块。" ;;
  esac
else
  kv "默认路由" "$(netstat -rn -f inet 2>/dev/null | awk '$1=="default"{print $2" "$NF; exit}')"
fi

if [ "$DO_EGRESS" = "1" ] && [ -n "$IFACE" ]; then
  bold "5. 出口实测（绑定 ${IFACE}，约几百字节）"
  # 绑源地址可以绕过 TUN，直接问"这块网卡自己通不通"
  out=$(curl -4 -s --noproxy '*' --interface "$IFACE" --max-time 15 \
        "http://ip-api.com/json/?fields=query,isp,as,city,regionName,country" 2>/dev/null || true)
  if [ -n "$out" ]; then
    ok "IPv4 出网成功"
    printf '  %s\n' "$out"
  else
    bad "IPv4 出网失败：注册/APN/资费需排查（见 references/troubleshooting.md #4）"
  fi
  code=$(curl -4 -s --noproxy '*' --interface "$IFACE" --max-time 15 \
         -o /dev/null -w '%{http_code} %{time_total}s' \
         https://www.apple.com/library/test/success.html 2>/dev/null || echo "失败")
  kv "HTTPS 实取" "HTTP ${code}"
  v6=$(curl -6 -s --noproxy '*' --interface "$IFACE" --max-time 12 \
       "https://api64.ipify.org" 2>/dev/null || true)
  [ -n "$v6" ] && kv "IPv6 出口" "$v6" || warn "IPv6 出网不可用"
elif [ "$DO_EGRESS" = "1" ]; then
  bold "5. 出口实测"
  warn "无网卡，跳过。（先在上网页切到「上网模式」）"
fi

bold "6. 日志尾部"
if [ -f "$LOG" ]; then
  tail -8 "$LOG" | sed 's/^/  /'
else
  warn "暂无日志：$LOG"
fi

printf '\n%s\n' "提示：共享日志/截图前先抹掉 ICCID、IMSI、EID、完整手机号和验证码。"
