#!/bin/sh
# dji-4g-sim-skill — 在 macOS 上拉起大疆第一代 4G 模块（EG25-G / QDC507）的管理环境
#
# 设计取舍：
#   1. 依赖以「固定版本 + SHA-256 校验」的方式拉取，不 vendor 源码。
#      可复现、可审计，升级只需改 manifest/dependencies.json。
#   2. 便携安装到 ~/.local/share，不写 /usr/local，全程不需要 sudo。
#      （若想要开机自启，再单独跑安装目录内的 ./install，那一步才需要密码。）
#   3. 幂等：重复执行只会检测、跳过已装的依赖、确保进程在跑。
#
# 用法：
#   ./bootstrap.sh            检测 → 安装依赖 → 启动 → 打开管理页
#   ./bootstrap.sh --check    只做检测，不下载、不启动（新设备先跑这个）
#   ./bootstrap.sh --start    跳过检测与安装，仅确保进程在跑
#   ./bootstrap.sh --no-open  启动但不打开浏览器

set -eu

HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -P -- "${HERE}/.." && pwd)
MANIFEST="${ROOT}/manifest/dependencies.json"

INSTALL_ROOT="${DJI4G_INSTALL_ROOT:-$HOME/.local/share/dji-4g-sim}"
UI_URL="http://127.0.0.1:7575"
LOG_FILE="$HOME/Library/Logs/ModemCat/modemcat.log"

log()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
hr()   { printf -- '---- %s\n' "$*"; }

MODE="full"
NO_OPEN=0
for arg in "$@"; do
  case "$arg" in
    --check)   MODE="check" ;;
    --start)   MODE="start" ;;
    --no-open) NO_OPEN=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$arg（可用：--check / --start / --no-open）" ;;
  esac
done

# ---------------------------------------------------------------- manifest 读取
# 扁平键 + sed：不依赖 jq / python3，全新机器上也能跑。
mget() {
  [ -f "$MANIFEST" ] || die "缺少依赖表：$MANIFEST"
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$MANIFEST" | head -n 1
}

REPO=$(mget modemcat_repo)
VERSION=$(mget modemcat_version)
ASSET=$(mget modemcat_asset)
SHA256=$(mget modemcat_sha256)
RELEASE_URL=$(mget modemcat_release_url)

[ -n "$REPO" ] && [ -n "$VERSION" ] && [ -n "$ASSET" ] && [ -n "$SHA256" ] && [ -n "$RELEASE_URL" ] \
  || die "依赖表字段不全，拒绝继续。"

INSTALL_DIR="${INSTALL_ROOT}/modemcat/${VERSION}"
BIN="${INSTALL_DIR}/modemcat"

# ---------------------------------------------------------------- 环境
check_env() {
  hr "1/4 环境"
  [ "$(uname -s)" = "Darwin" ] || die "本 skill 目前只覆盖 macOS。"
  [ "$(uname -m)" = "arm64" ] \
    || die "当前依赖只有 Apple Silicon 发行包（Intel 版上游未发布）。"
  ok "macOS $(sw_vers -productVersion) / $(uname -m)"
  for c in curl unzip shasum ioreg; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"
  done
  ok "基础命令齐备（curl / unzip / shasum / ioreg）"
}

# ---------------------------------------------------------------- 设备
detect_device() {
  if ioreg -p IOUSB -w0 -l 2>/dev/null | grep -q 'idVendor" = 11427'; then
    DEV_DESC="BAIWANG EG25G-QDC507 (2ca3:4006) · USB 层可见"
    return 0
  fi
  DEV_HW=$(networksetup -listallhardwareports 2>/dev/null \
            | awk '/Hardware Port: EG25G-QDC507/{f=1} f&&/Device:/{print $2; exit}')
  if [ -n "$DEV_HW" ]; then
    DEV_DESC="EG25G-QDC507 → ${DEV_HW} · 网络服务可见"
    return 0
  fi
  return 1
}

check_device_or_die() {
  hr "2/4 模块检测"
  if detect_device; then
    ok "$DEV_DESC"
    return 0
  fi
  warn "未检测到大疆 4G 模块。"
  warn "排查顺序："
  warn "  ① USB-C 线是否支持数据传输（最常见的坑，换线再试）"
  warn "  ② 换一个能供电的端口 / 带供电的 Hub"
  warn "  ③ 重新插拔模块"
  warn "详见 references/troubleshooting.md #5"
  return 1
}

# ---------------------------------------------------------------- 依赖
ensure_dependency() {
  hr "3/4 依赖：ModemCat ${VERSION}"
  log "  来源：https://github.com/${REPO}（非官方第三方，非商业许可）"

  if [ -x "$BIN" ] && [ "$(cat "${INSTALL_DIR}/.version" 2>/dev/null || true)" = "$VERSION" ]; then
    ok "已安装，跳过下载：${INSTALL_DIR}"
    return 0
  fi

  TMP=$(mktemp -d)
  trap 'rm -rf "${TMP:-}"' EXIT INT TERM

  log "  下载 ${ASSET} …"
  curl -fL --progress-bar "${RELEASE_URL}/${ASSET}" -o "${TMP}/${ASSET}" \
    || die "下载失败。确认网络可达，以及 ${VERSION} 是否仍附带该发行包。"

  log "  校验 SHA-256 …"
  ACTUAL=$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')
  if [ "$ACTUAL" != "$SHA256" ]; then
    printf '  期望 %s\n  实际 %s\n' "$SHA256" "$ACTUAL" >&2
    die "校验不匹配，已中止（绝不安装来路不明的二进制）。"
  fi
  ok "SHA-256 校验通过"

  unzip -q "${TMP}/${ASSET}" -d "${TMP}/unpacked" || die "解压失败。"
  PKG=$(find "${TMP}/unpacked" -maxdepth 2 -name modemcat -type f -print -quit | xargs -I{} dirname {})
  [ -n "$PKG" ] && [ -f "${PKG}/install" ] || die "发行包结构异常（未找到 modemcat / install）。"

  mkdir -p "$INSTALL_DIR"
  cp -R "${PKG}"/. "$INSTALL_DIR"/
  # 网络下载的文件带隔离属性，不清掉首次启动会被 Gatekeeper 拦下
  xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true
  chmod +x "${INSTALL_DIR}/modemcat" "${INSTALL_DIR}/bin/modemcat-macos" 2>/dev/null || true
  printf '%s\n' "$VERSION" > "${INSTALL_DIR}/.version"
  ok "已安装到 ${INSTALL_DIR}（未使用 sudo）"
}

# ---------------------------------------------------------------- 启动
start_service() {
  hr "4/4 启动"
  if pgrep -f "bin/modemcat-macos" >/dev/null 2>&1; then
    ok "ModemCat 已在运行（PID $(pgrep -f 'bin/modemcat-macos' | head -1)）"
  else
    ( cd "$INSTALL_DIR" && ./modemcat start ) \
      || die "启动失败。日志：${LOG_FILE}"
    sleep 3
    if pgrep -f "bin/modemcat-macos" >/dev/null 2>&1; then
      ok "已启动"
    else
      warn "进程未出现，查日志：${LOG_FILE}"
    fi
  fi

  if curl -s -o /dev/null --max-time 5 "$UI_URL" 2>/dev/null; then
    ok "管理页在线：${UI_URL}"
  else
    warn "管理页暂无响应，等几秒再试：${UI_URL}"
  fi

  if [ "$NO_OPEN" = "0" ]; then
    open "$UI_URL" 2>/dev/null || true
  fi

  log ""
  hr "下一步"
  log "  首次访问 ${UI_URL} 需设置管理员账号（账号 3–64 位，密码 ≥12 字节）"
  log "  链路/上网页诊断：  ${ROOT}/scripts/status.sh"
  log "  两种模式怎么选：   ${ROOT}/references/modemcat.md"
  log "  报错先查：         ${ROOT}/references/troubleshooting.md"
}

# ---------------------------------------------------------------- 主流程
case "$MODE" in
  check)
    check_env
    if check_device_or_die; then :; fi
    log ""
    log "检测结束（未做任何改动）。"
    ;;
  start)
    start_service
    ;;
  full)
    check_env
    check_device_or_die || exit 1
    ensure_dependency
    start_service
    ;;
esac
