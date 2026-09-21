#!/bin/bash
# 出 README 用的界面图，落到 docs/images/（这些图**进版本库**，GitHub 页面直接引用）。
#
# 为什么不复用 Scripts/snapshot-panel.sh：那个脚本的图是给**自己看**的——
# 每张都按 860pt 高画，为的是「一屏装下尽量多的情况」，方便横向比对。
# 放进 README 就不行了：14 张卡片只占半屏，剩下半屏空白，第一眼看过去像坏了。
# 所以这里单独定高，并且**裁到内容高度**。
#
# 改过面板外观（Resources/panel.html 的 CSS/结构）之后要重跑一次，
# 否则 README 上的图和新版本对不上——图是给人看的第一印象，比代码更容易过期。
#
#   ./Scripts/snapshot-readme.sh            # 出全部
#   ./Scripts/snapshot-readme.sh --only list
#   ./Scripts/snapshot-readme.sh --only themes
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
HTML="$ROOT/Resources/panel.html"
FIX="$ROOT/Tests/snapshot-fixtures.js"
THEMES_JS="$ROOT/Tests/snapshot-themes.js"
OUTDIR="$ROOT/docs/images"
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
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

# --only 的过滤放在调用处（而不是函数里）：主题那一张要连着出 4 张再拼，
# 放在函数里的话每张都会被单独判一次名字，拼图那步就接不上了。
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

render() {  # render <输出目录> <名字> <宽> <高> [内联 js] [额外的 js 文件]
  local dir="$1" name="$2" w="$3" h="$4" extra="${5:-}" jsfile="${6:-}"
  local args=(--html "$HTML" --out "$dir/$name.png" --width "$w" --height "$h" --js-file "$FIX")
  [ -n "$jsfile" ] && args+=(--js-file "$jsfile")
  [ -n "$extra" ] && args+=(--js "$extra")
  "$TMP/shot" "${args[@]}"
}

# 操作按钮平时 opacity:0，hover 才出来。README 里看不见按钮就等于没这个功能，
# 所以下面几处要先 forceHover()（只改可见性，不动布局）。
HOVER='window.SNAP.reset(); window.SNAP.forceHover();'

# 1. 卡片视图。宽 1200 是为了拿到 4 列——列数是这个应用最直观的一个
#    「随面板宽度变」的特性，3 列看不出这个。
#
#    高度得跟着内容走，而卡片区是 CSS 多列布局：容器高度一变，
#    分列的结果也会跟着变，所以这个数只能**量**不能算。620 是量出来的：
#    1200pt 宽下内容底边落在 589pt，加上 `.content` 给「滚到底」留的
#    26px 呼吸位，正好填满——再矮就切掉最后一排卡片，再高就多一截空白。
#
#    这一张刻意**不** forceHover：网格里 14 张卡片同时亮出操作按钮太吵，
#    而且真实使用中一次只会 hover 一张。按钮的样子交给下面列表那张展示。
if want panel; then
  render "$OUTDIR" panel 1200 620
fi

# 2. 列表视图。这个视图自带「按天分组」的分组头，内容比卡片视图长得多，
#    860 是窗口的常规高度，正好装下「今天 / 昨天」两组，看得出分组的节奏。
if want list; then
  render "$OUTDIR" list 900 860 "$HOVER document.querySelector(\"[data-view=list]\").click()"
fi

# 3. 详情弹窗。弹窗是**垂直居中**的，所以高度不能裁——裁了就偏。
#    这一张要展示的是「卡片上撤掉的来源 / 出处 / 链接 / 时间，在这里都找得到」。
if want detail; then
  render "$OUTDIR" detail 1100 860 'document.querySelector("#grid .card").click()'
fi

# 4. 主题一览。同一份内容在四种主题下各出一张，**拼成 2×2**。
#
#    为什么拼：分开放四张图，读者要自己上下滚动才能对比；拼在一起才一眼看得出
#    「差别只在配色」。顺带省掉三份重复的文件体积。
#
#    为什么是 2 列而不是 1 行 4 张：README 里图片按容器宽度缩放（约 1012px）。
#    一行 4 张的话每张只剩 250px 宽，只能看出一团颜色；2×2 每张有约 500px，
#    卡片上的字都能看清。代价是图变高（约 580px），但这一段本来就是「画廊」，
#    高一点不碍事。
#
#    700×385 是量出来的：700pt 宽正好 2 列卡片，385pt 高正好装下 2 行卡片，
#    不多不少（卡片区是 CSS 多列布局，高度一变分列结果也变，所以只能量）。
#
#    挑的这四种覆盖了两端：晴空 / 纸间是浅色（冷白 / 暖米，反差最大的一对），
#    夜览 / 灯下是深色（中性 / 暖光）。
if want themes; then
  THEME_DIR="$TMP/themes"
  mkdir -p "$THEME_DIR"
  for t in sky paper night lamp; do
    render "$THEME_DIR" "theme-$t" 700 385 "THEME_DEMO.apply('$t')" "$THEMES_JS"
  done
  "$TMP/shot" --stitch --out "$OUTDIR/themes.png" --cols 2 --gap 14 \
    --in "$THEME_DIR/theme-sky.png" \
    --in "$THEME_DIR/theme-paper.png" \
    --in "$THEME_DIR/theme-night.png" \
    --in "$THEME_DIR/theme-lamp.png"
fi

echo
echo "✓ README 配图在 $OUTDIR"
echo "  记得一起提交：git add docs/images"
