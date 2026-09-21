#!/bin/bash
# 把 dist/Shiju.app 打成一个「拖进去就装」的 dmg。
#
# 盘里放三样东西：Shiju.app、指向 /Applications 的快捷方式、一份安装说明。
# 打开 dmg 后把 app 拖到 Applications 上就装好了——这是 macOS 的常规做法。
#
# 两种用途，用的是同一份产物：
#   * 自己备份一份可回滚的版本、或者拷到别的机器
#   * 发 GitHub Release 给别人下载（那就得先跑 ./Scripts/make-app.sh --dist）
#
# 安装说明（dmg 里那份 .txt）不是可有可无的：这个包没有 Apple 开发者签名，
# 别人双击只会看到「已损坏」。说明文件是用户唯一能在**打不开的情况下**读到的线索，
# 所以它必须躺在盘里，而不是只写在网页上。
set -euo pipefail

cd "$(dirname "$0")/.."
APP="$(pwd)/dist/Shiju.app"
[ -d "$APP" ] || { echo "✗ 找不到 $APP，先跑 ./Scripts/make-app.sh"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
OUT="$(pwd)/dist/Shiju-${VERSION}.dmg"

# 先看一眼签名是谁，决定结尾那句提醒怎么写。
# 用 `codesign -dv` 的 Authority 行：ad-hoc 签出来的包没有这一行。
AUTHORITY="$(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"

STAGE="${TMPDIR:-/tmp}/shiju-dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# 盘里用中文包名，和 /Applications 里的安装名一致（理由见 install.sh）
cp -R "$APP" "$STAGE/拾句.app"
ln -s /Applications "$STAGE/Applications"      # 拖拽安装的目标

# 安装说明。文案要和 README「安装」一节说的一致——两处不一致时，
# 用户会以为自己操作错了，然后跑去开 issue。
cat > "$STAGE/安装说明.txt" <<'TXT'
拾句 · 安装说明
==============

1. 把左边的「拾句.app」拖到右边的「Applications」文件夹上。


2. 打开「终端」，粘贴下面这一行，回车：

     xattr -dr com.apple.quarantine /Applications/拾句.app

   为什么要这一步：
   拾句没有 Apple 开发者签名（那张证书一年 99 美元），macOS 会把从网上
   下载的应用拦下来——直接双击只会弹一个「已损坏，无法打开」的框，
   而那个框上没有「仍要打开」的按钮，看着像文件坏了，其实没有。

   上面这行命令就是把「这是从网上下载的文件」这个标记去掉。它不做别的，
   也不需要管理员密码。

   不想敲命令的话也可以：**右键**点「拾句」→ 打开 → 在弹窗里再点一次
   「打开」。注意别直接双击。


3. 从启动台，或者聚焦搜索（⌘空格，输入「拾句」）打开。


4. 第一次打开会引导你去授予「辅助功能」权限。这是 macOS 的强制要求，
   绕不过去——没有它，选中文字时按钮不会出现。
   授予之后立刻生效，不用重启。


两点提醒
--------

* 拾句是个**菜单栏应用**，装完不会出现在 Dock 里，
  只在屏幕右上角的菜单栏多一个「拾」字。找不到它不是没装上。

* 系统要求：macOS 13 或更高，且是 Apple Silicon（M 系列）芯片。
  Intel Mac 需要自己从源码构建。


项目主页
--------
https://github.com/liulao-space/shiju
TXT

echo "▸ 压缩打包（UDZO）"
rm -f "$OUT"
hdiutil create -volname "拾句" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
rm -rf "$STAGE"

echo
echo "✓ $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "校验："
hdiutil verify "$OUT" 2>&1 | sed 's/^/  /'
echo
echo "签名身份：${AUTHORITY:-ad-hoc（无证书）}"
if [ -z "$AUTHORITY" ]; then
  echo
  echo "提醒：这是 ad-hoc 签名的包，别人下载后会被 Gatekeeper 拦下，"
  echo "     需要按盘里「安装说明.txt」去掉隔离属性。这一步 README 里也写了。"
else
  echo
  echo "提醒：签名用的是本机证书「$AUTHORITY」，**只在这台机器上受信任**。"
  echo "     要对外分发请改用：./Scripts/make-app.sh --dist && ./Scripts/make-dmg.sh"
fi
