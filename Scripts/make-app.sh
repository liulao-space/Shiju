#!/bin/bash
# 组装 Shiju.app。
#
# 为什么要手工打包：本机只装了 Command Line Tools，没有 Xcode，
# 因此 xcodebuild 不可用。SwiftPM 能编译出可执行文件，
# 但 .app 目录结构与 Info.plist 需要自己拼——LSUIElement 只能从这里声明。
#
#   ./Scripts/make-app.sh           # 自己用：用本机开发证书签，辅助功能授权能留住
#   ./Scripts/make-app.sh --dist    # 发出去：ad-hoc 签，不带本机证书的任何痕迹
#
# 两者签名方式不同，理由见文件末尾那段注释。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/Shiju.app"
FOR_DIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dist) FOR_DIST=1; shift ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

# 版本号只有一个来源：仓库根目录的 VERSION 文件。
# 早先写死在下面那份 Info.plist 里，于是「发 Release 打 tag」和「包里写的版本」
# 是两件要手动对齐的事——忘一次就发出去一个版本号对不上的包。
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
[ -n "$VERSION" ] || { echo "✗ 读不到 $ROOT/VERSION"; exit 1; }

# CFBundleVersion 用提交数，保证每次发版都是递增的整数（系统用它判新旧）。
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)"
case "$BUILD" in ''|*[!0-9]*) BUILD=1 ;; esac
[ "$BUILD" -gt 0 ] 2>/dev/null || BUILD=1

echo "▸ 编译 (release) 版本 $VERSION (build $BUILD)"
# --disable-sandbox 是必须的：SwiftPM 默认用 sandbox-exec 跑 manifest，
# 在受限环境里会直接报 "sandbox_apply: Operation not permitted"。
swift build -c release --disable-sandbox

BIN="$ROOT/.build/release/Shiju"
[ -f "$BIN" ] || { echo "✗ 编译产物不存在: $BIN"; exit 1; }

echo "▸ 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shiju"
cp "$ROOT/Resources/panel.html" "$APP/Contents/Resources/panel.html"

# 图标。.icns 是生成物，不进版本库；缺了就现生成一次（约 10 秒）。
ICON="$ROOT/Resources/Shiju.icns"
if [ ! -f "$ICON" ]; then
  echo "▸ 图标缺失，先生成"
  "$ROOT/Scripts/make-icon.sh"
fi
cp "$ICON" "$APP/Contents/Resources/Shiju.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>Shiju</string>
	<key>CFBundleDisplayName</key>     <string>拾句</string>
	<key>CFBundleExecutable</key>      <string>Shiju</string>
	<key>CFBundleIdentifier</key>      <string>com.liulao.shiju</string>
	<key>CFBundleIconFile</key>        <string>Shiju</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<!-- 下面两行是占位值，紧接着由 PlistBuddy 从 VERSION / git 提交数写进去。
	     写成占位而不是在 heredoc 里插变量，是因为 heredoc 一旦改成不带引号的形式，
	     plist 里以后万一出现 $ 或反引号就会被 shell 吃掉，而且错得很安静。 -->
	<key>CFBundleShortVersionString</key><string>0.0.0</string>
	<key>CFBundleVersion</key>         <string>0</string>
	<key>LSMinimumSystemVersion</key>  <string>13.0</string>
	<key>NSHighResolutionCapable</key> <true/>
	<key>LSUIElement</key>             <true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>用于读取浏览器当前页面的标题与链接，作为收录内容的出处。</string>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD"                "$APP/Contents/Info.plist"

echo "▸ 签名"
# 签名身份直接决定「辅助功能」授权能不能留住，这里踩过坑，写清楚：
#
# ad-hoc（`--sign -`）签出来的包，系统记的是 **cdhash**：
# `identifier "com.liulao.shiju" and cdhash H"..."`。
# cdhash 是二进制的哈希，**每次重新编译都会变** → 旧的授权记录对不上 →
# 权限静默失效。表现就是「昨天还好好的，今天选中文字毫无反应」，
# 而且菜单栏图标没有任何异常提示，极难自查。
#
# 用一张固定的本地证书签，系统记的就变成
# `identifier "com.liulao.shiju" and certificate root = H"..."`——
# 只要证书不变，重编译多少次授权都在。
#
# 但**这张证书只在这台机器上受信任**。用它签出来的包发出去，别人的机器上
# 既验不过 Gatekeeper，还会把本机的证书名写进包里。所以对外分发走另一条路：
# `--dist` 用 ad-hoc，包里不带任何本机痕迹，代价是别人得手动去掉隔离属性
# （README「安装」一节里写的就是这一步）。
if [ "$FOR_DIST" = 1 ]; then
  echo "  对外分发模式：ad-hoc 签名（不引用本机证书）"
  codesign --force --deep --sign - "$APP" \
    && echo "  ✓ 已 ad-hoc 签名" \
    || { echo "  ✗ 签名失败"; exit 1; }
else
  # 本机开发用。也可以显式指定别的证书：
  #   SHIJU_SIGN_IDENTITY="我的证书" ./Scripts/make-app.sh
  # 想建一张专属的：见 docs/开发笔记.md「签名与辅助功能权限」一节。
  #
  # 这个默认值是**作者本机**那张证书的名字。别人 clone 下来通常没有它，
  # 脚本会自己退回 ad-hoc 并打印警告——那是正常的，不影响运行，
  # 只是每次重新编译后要重新勾一次「辅助功能」权限。
  SIGN_IDENTITY="${SHIJU_SIGN_IDENTITY:-WindowSwitcher Local}"
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
      && echo "  已用「$SIGN_IDENTITY」签名（授权可跨重编译保留）" \
      || { echo "  签名失败，退回 ad-hoc"; codesign --force --deep --sign - "$APP" 2>/dev/null || true; }
  else
    echo "  找不到证书「$SIGN_IDENTITY」，退回 ad-hoc"
    echo "  ⚠️ ad-hoc 签名下，每次重新编译都要重新勾选「辅助功能」权限"
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (签名跳过，不影响本地运行)"
  fi
fi

echo
echo "✓ 完成: $APP  ($VERSION build $BUILD)"
echo
if [ "$FOR_DIST" = 1 ]; then
  echo "这是**对外分发**的包。下一步："
  echo "  ./Scripts/make-dmg.sh   打成 dmg，然后作为 Release 附件传上去"
  echo
  echo "提醒：包里没有 Apple 开发者签名，别人下载后会被 Gatekeeper 拦。"
  echo "      README「安装」一节写了怎么让用户绕过去（去掉隔离属性）。"
else
  echo "下一步："
  echo "  ./Scripts/install.sh    装到 /Applications（推荐，之后可从启动台/聚焦打开）"
  echo "  ./Scripts/make-dmg.sh   打成 dmg 安装包（备份或换机用）"
  echo
  echo "首次运行后需授予「辅助功能」权限："
  echo "  系统设置 → 隐私与安全性 → 辅助功能 → 勾选「拾句」"
fi
