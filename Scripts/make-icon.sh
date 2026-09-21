#!/bin/bash
# 生成 Resources/Shiju.icns。
#
# 流程：Swift 画一张 1024×1024 PNG → sips 缩出 iconset 需要的 10 个尺寸 →
# iconutil 合成 .icns。全程用系统自带工具，不需要 Xcode 或设计软件。
#
# 图标本身很少改，所以 make-app.sh 只在 .icns 缺失时才调这个脚本。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC="$ROOT/Resources/Shiju.icns"
TMP="${TMPDIR:-/tmp}/shiju-icon"
ICONSET="$TMP/Shiju.iconset"
MASTER="$TMP/icon-1024.png"

mkdir -p "$TMP"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

echo "▸ 画主图"
swift "$ROOT/Scripts/make-icon.swift" "$MASTER"

echo "▸ 缩出各尺寸"
# iconset 要求的 10 个文件：点尺寸 + @2x 变体
while read -r pixels name; do
  sips -z "$pixels" "$pixels" "$MASTER" --out "$ICONSET/icon_$name.png" >/dev/null
done <<'SPEC'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SPEC

echo "▸ 合成 icns"
iconutil -c icns "$ICONSET" -o "$SRC"
echo "✓ $SRC  ($(du -h "$SRC" | cut -f1))"
