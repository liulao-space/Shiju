#!/bin/bash
# 面板视觉截图：把 Resources/panel.html 渲染成 PNG，肉眼确认布局。
#
# 存在理由：jsdom 测不了布局（见 Tests/panel-snapshot.swift 顶部的说明）。
# 契约测试保证「规则写对了」，这个保证「画出来是对的」——两件事。
# 要数字而不是图的话用 Scripts/test-layout.sh（同一个工具，探针模式）。
#
#   ./Scripts/snapshot-panel.sh              # 出全部图，落到 dist/shots/
#   ./Scripts/snapshot-panel.sh --only wide  # 只出一张
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HTML="$ROOT/Resources/panel.html"
FIX="$ROOT/Tests/snapshot-fixtures.js"
OUTDIR="$ROOT/dist/shots"
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --out)  OUTDIR="${2:-}"; shift 2 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

[ -f "$HTML" ] || { echo "✗ 找不到 $HTML"; exit 1; }
mkdir -p "$OUTDIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib-snapshot.sh
. "$ROOT/Scripts/lib-snapshot.sh"
build_snapshot_tool "$TMP/shot" || exit 1

# 所有截图都先加载 Tests/snapshot-fixtures.js（样例数据 + 强制显示操作按钮的小工具），
# 再叠上这一步自己的 JS。
snap() {  # snap <名字> <宽> <高> [额外的 js]
  local name="$1" w="$2" h="$3" extra="${4:-}"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  local args=(--html "$HTML" --out "$OUTDIR/$name.png" --width "$w" --height "$h" --js-file "$FIX")
  [ -n "$extra" ] && args+=(--js "$extra")
  "$TMP/shot" "${args[@]}"
}

# 脚本长到一行塞不下时写成文件，别在命令行里拼字符串
snapfile() {  # snapfile <名字> <宽> <高> <js 文件>
  local name="$1" w="$2" h="$3" file="$4"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  "$TMP/shot" --html "$HTML" --out "$OUTDIR/$name.png" \
    --width "$w" --height "$h" --js-file "$FIX" --js-file "$file"
}

# 需要「一个数据文件 + 一句内联操作」时用这个
snapjs() {  # snapjs <名字> <宽> <高> <js 文件> <内联 js>
  local name="$1" w="$2" h="$3" file="$4" extra="${5:-}"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then return 0; fi
  "$TMP/shot" --html "$HTML" --out "$OUTDIR/$name.png" \
    --width "$w" --height "$h" --js-file "$FIX" --js-file "$file" --js "$extra"
}

# 操作按钮平时 opacity:0，hover 才出来。截图里看不到就等于没验证，
# 所以这几张要先 forceHover()（只改可见性，不动布局）。
SHOW_BUTTONS='window.SNAP.reset(); window.SNAP.forceHover();'

# ── 第 5 轮那几条需求的「眼见为实」 ─────────────────────────────
# 宽窄两档看列数：1200 应该 4 列，760 应该 2 列。写死断点的话两档之间会有
# 一段「拖了但没反应」的区间，这里用 1000 再插一档，专门盯那段。
snap wide      1200 860
snap mid       1000 860
snap narrow     760 860
# 最窄一档 = PanelWindow 的 minSize(520)。顶栏「空间不够时谁让位」的问题
# 只在这里看得出来——搜索框该缩，按钮不该被压扁。
snap min        520 860

# 顶栏特写：功能入口挤在一排按钮里，整屏图上太小看不清。
# 高度只给 150，让顶栏占满画面。
snap topbar    1000 150

# 列表视图 + 多标签：看底栏标签有没有换行、右侧按钮有没有被挤变形
snap list       900 860 "$SHOW_BUTTONS document.querySelector(\"[data-view=list]\").click()"

# 标签底栏压测：同一份数据在 4 列（窄卡）和 2 列（宽卡）下各截一张。
# 限数跟着列数走，所以这两张显示的标签个数应该不一样（1 个 vs 3 个）。
snapfile tags4 1200 860 "$ROOT/Tests/snapshot-tags.js"
snapfile tags2  760 860 "$ROOT/Tests/snapshot-tags.js"

# 空状态：看是不是真的水平+垂直居中（jsdom 只能验 min-height 的写法）
snap empty     1100 760 'Shiju.hydrate([])'

# 弹层：主题与标签都该贴在各自按钮的正下方，且主题弹层没有底部文案
snap popover   1100 860 'document.querySelector("#themeBtn").click()'
snap tagpop    1100 860 'document.querySelector("#tagBtn").click()'

# 详情弹窗：卡片上撤掉的「来源（含徽标）」和「时间」都得在这里找得到，
# 而底部不该再出现那串 id。这一屏以前没有截图，改的偏偏就是它。
snap sheet     1100 860 'document.querySelector("#grid .card").click()'

# 来源徽标的配色：用**真实的应用名**（localizedName）再截两张。
# 之所以要另起一份数据：SEED 里的短名恰好都能对上映射表，
# 而真实库里存的「Google Chrome」对不上——灰底的问题在样例数据上根本看不出来。
snapjs sheet-chrome 1100 860 "$ROOT/Tests/snapshot-sources.js" "SRC.open('s1')"
snapjs sheet-idea   1100 860 "$ROOT/Tests/snapshot-sources.js" "SRC.open('s4')"

# 标签筛选选中态：入口要变成「标签名 + 命中条数」，且列表只剩命中项
snap tagfilter 1100 860 \
  'document.querySelector("#tagBtn").click(); document.querySelectorAll("#tagList .tagrow")[0].click()'

echo
echo "✓ 截图在 $OUTDIR"
