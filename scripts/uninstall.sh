#!/bin/sh
# dji-4g-sim-skill — 清理本 skill 安装的依赖
#
# 只动本 skill 自己下载的东西（~/.local/share/dji-4g-sim）。
# 不碰 ~/Library/Logs/ModemCat、~/Library/Application Support/ModemCat 里的
# 运行数据，也不碰 /usr/local —— 除非你当年自己跑过包内的 ./install。
#
# 用法：
#   ./uninstall.sh            停进程 + 删安装目录
#   ./uninstall.sh --purge    连运行数据（日志、SQLite、会话）一起删
set -eu

INSTALL_ROOT="${DJI4G_INSTALL_ROOT:-$HOME/.local/share/dji-4g-sim}"
DATA_DIRS="$HOME/Library/Application Support/ModemCat
$HOME/Library/Logs/ModemCat"

PURGE=0
if [ "${1:-}" = "--purge" ]; then
  PURGE=1
fi

echo "→ 停止 ModemCat"
for bin in "$INSTALL_ROOT/modemcat"/*/modemcat; do
  [ -x "$bin" ] && ( cd "$(dirname "$bin")" && ./modemcat stop ) 2>/dev/null || true
done
pkill -f "bin/modemcat-macos" 2>/dev/null || true
sleep 1

echo "→ 删除 $INSTALL_ROOT"
rm -rf "$INSTALL_ROOT"

if [ "$PURGE" = "1" ]; then
  echo "$DATA_DIRS" | while IFS= read -r d; do
    [ -n "$d" ] && [ -e "$d" ] && { echo "→ 删除 $d"; rm -rf "$d"; }
  done
else
  echo "  保留运行数据（加 --purge 可一并删除）："
  echo "$DATA_DIRS" | sed 's/^/    /'
fi

echo "完成。"
