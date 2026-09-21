#!/bin/bash
# 把 Shiju.app 装到 /Applications，并重启它。
#
# 为什么要有这一步，而不是直接双击 dist 里的 app：
#   1. dist/ 在项目目录里，启动台和聚焦搜不到，每次都得进文件夹找
#   2. 一个应用存在两份副本时，系统会当成两个不同的应用——
#      「辅助功能」授权是跟路径走的，两份就得授权两次
# 所以固定装一份，只用这一份。
#
# 注意：**每次重新编译后都要重新运行本脚本**，否则 /Applications 里跑的还是旧版本。
set -euo pipefail

cd "$(dirname "$0")/.."
APP="$(pwd)/dist/Shiju.app"
# 安装后的包名用中文，和 CFBundleDisplayName 一致。
# 原因：Spotlight 只按**文件名**索引应用，包名叫 Shiju.app 时搜「拾句」搜不到；
# 而启动台和访达显示的又都是「拾句」，两边对不上。macOS 上中文包名很常见
# （本机就有 微信.app / 飞书.app / 百度网盘.app），不影响签名与运行。
DEST="/Applications/拾句.app"
LEGACY="/Applications/Shiju.app"

[ -d "$APP" ] || { echo "✗ 找不到 $APP，先跑 ./Scripts/make-app.sh"; exit 1; }

# 装之前先退掉，否则会覆盖到正在运行的二进制
if pgrep -f "$DEST/Contents/MacOS/Shiju" >/dev/null 2>&1; then
  echo "▸ 退出正在运行的实例"
  # 用 bundle id 而不是应用名：包名是中文的「拾句」，但 CFBundleName 仍是 Shiju，
  # 按名字找容易在两种写法之间踩空。
  osascript -e 'tell application id "com.liulao.shiju" to quit' 2>/dev/null || true
  sleep 1
  pkill -f "$DEST/Contents/MacOS/Shiju" 2>/dev/null || true
  sleep 1
fi
# 早期版本装成了 Shiju.app，清掉，避免两份副本各要一次授权
if [ -d "$LEGACY" ]; then
  echo "▸ 清理旧包名 $LEGACY"
  pkill -f "$LEGACY/Contents/MacOS/Shiju" 2>/dev/null || true
  rm -rf "$LEGACY"
fi
# dist 里那份也退掉，避免多个副本同时跑（授权会分叉）
pkill -f "$APP/Contents/MacOS/Shiju" 2>/dev/null || true

echo "▸ 复制到 $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "▸ 清隔离属性（本地构建本来就没有，防手滑）"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "▸ 启动"
open "$DEST"
sleep 2

if pgrep -f "$DEST/Contents/MacOS/Shiju" >/dev/null 2>&1; then
  echo
  echo "✓ 已安装并运行：$DEST"
  echo
  echo "打开方式："
  echo "  · 聚焦搜索（⌘空格）输入「拾句」"
  echo "  · 启动台里找蓝色「拾」图标"
  echo "  · 注意它没有 Dock 图标，运行后只在**菜单栏右侧**出现一个「拾」字"
  echo
  # 读诊断日志里的权限状态。没有它，「选中文字没反应」这件事从外部完全看不出
  # 是权限问题还是代码问题——所以这里主动读回来告诉用户。
  #
  # 为什么不用 `log show`：统一日志在受限环境下直接拒绝运行
  # （`log: Cannot run while sandboxed`），而且 **zsh 里 `log` 是内建命令**，
  # 不写绝对路径会被 shell 吃掉、静默返回空——看上去就像「应用一条日志都没打」。
  DIAG="$HOME/Library/Application Support/Shiju/diagnostics.log"
  if [ -f "$DIAG" ]; then
    # 日志是异步写的，刚启动时可能还没落盘——重试几次，别把「还没写」当成「没有」。
    #
    # 注意这里**不能**用 `grep -o '辅助功能权限[已未]授予'`：脚本跑在 C locale 下，
    # `[已未]` 这种含多字节字符的括号表达式会被按【字节】拆开，
    # 于是「权限」和「授予」之间隔着 3 个字节匹配不上，静默返回空——
    # 表现得就像日志里没有这一行。只用字面量 + case 通配最稳。
    line=""
    for _ in 1 2 3 4 5; do
      line="$(grep '启动：辅助功能权限' "$DIAG" 2>/dev/null | tail -1 || true)"
      [ -n "$line" ] && break
      sleep 1
    done
    case "$line" in
      *已授予*) perm="辅助功能权限已授予" ;;
      *未授予*) perm="辅助功能权限未授予" ;;
      *)        perm="" ;;
    esac
    monitors="$(grep -o '全局监听已注册 [0-9]*/[0-9]* 个' "$DIAG" 2>/dev/null | tail -1 || true)"
    case "$perm" in
      "辅助功能权限已授予") echo "✓ $perm" ;;
      "辅助功能权限未授予")
        echo "⚠️  辅助功能权限未授予 —— 悬浮按钮不会出现"
        echo "    菜单栏图标会显示「拾!」，点它即可直达授权页；勾选后自动生效，无需重启。" ;;
      *) echo "（诊断日志里还没有权限记录）" ;;
    esac
    [ -n "$monitors" ] && echo "  $monitors"
    echo "  诊断日志：$DIAG"
  else
    echo "（还没有诊断日志，可看菜单栏图标：显示「拾!」即缺权限）"
  fi
else
  echo "✗ 启动失败，检查 /Applications 是否可写，或看控制台日志"
  exit 1
fi
