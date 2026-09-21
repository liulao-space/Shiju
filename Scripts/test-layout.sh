#!/bin/bash
# 真实布局回归：在真的 WebKit（WKWebView）里量几何并断言。
#
# 和 panel-contract-test.cjs 的分工：
#   契约测试（jsdom）  —— 规则写对了没：有没有 .chip[hidden]、min-height 有没有设
#   布局测试（本脚本） —— 画出来对不对：居中差几像素、底栏有没有换行、弹层越没越界
# jsdom 读不到布局（clientWidth 恒为 0），所以「偏上 18px」这种问题只有这里能抓。
#
#   ./Scripts/test-layout.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib-snapshot.sh
. "$ROOT/Scripts/lib-snapshot.sh"

# node 只用来做语法预检（`node --check`），不参与布局测试本身。
# 优先用 PATH 里的：**别写死某台机器上的绝对路径**——别人 clone 下来那条永远不存在，
# 而且会把本机的目录结构带进公开仓库。
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  for c in /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -x "$c" ] && { NODE="$c"; break; }
  done
fi
[ -n "$NODE" ] || { echo "✗ 找不到 node（只用于 JS 语法预检，装一下 Node.js 即可）"; exit 2; }

HTML="$ROOT/Resources/panel.html"
FIX="$ROOT/Tests/snapshot-fixtures.js"
PROBE="$ROOT/Tests/layout-probe.js"

# 语法预检。
# 探针是一个大 IIFE，里面几十个 const——不小心重名（比如别处已有 `squeezed`）
# 会让**整个脚本解析失败**，而 `evaluateJavaScript` 只会回报
# 「A JavaScript exception occurred」，一个字的细节都没有，极难定位。
# `node --check` 一秒就能指出第几行、什么错。
for f in "$FIX" "$PROBE"; do
  if ! "$NODE" --check "$f" > "$TMP/syntax.log" 2>&1; then
    echo "✗ 语法错误：$f"
    sed 's/^/    /' "$TMP/syntax.log"
    exit 1
  fi
done
# 两个文件是拼在一起注入的，还要检查拼接之后没有互相冲突的声明。
cat "$FIX" "$PROBE" > "$TMP/joined.js"
if ! "$NODE" --check "$TMP/joined.js" > "$TMP/syntax.log" 2>&1; then
  echo "✗ 拼接后语法错误（fixtures 与探针之间有重名？）"
  sed 's/^/    /' "$TMP/syntax.log"
  exit 1
fi

build_snapshot_tool "$TMP/shot" || exit 1

# 四档宽度：覆盖 4 列 / 3 列 / 2 列，外加**窗口能拖到的最窄值**（PanelWindow 里
# minSize 是 520）。最后一档专门用来抓「顶栏被挤扁」——按钮文字被裁这种问题
# 只在最窄处出现，而那是用户真的能拖到的宽度。
FAIL=0
for wh in 1200x860 1000x860 760x860 520x860; do
  w="${wh%x*}"; h="${wh#*x}"
  echo "▸ ${w}×${h}pt"
  if ! "$TMP/shot" --html "$HTML" --width "$w" --height "$h" \
        --js-file "$FIX" --js-file "$PROBE" --probe \
      | "$NODE" "$ROOT/Scripts/layout-report.cjs" --width "$w"; then
    FAIL=1
  fi
done

echo
if [ "$FAIL" -ne 0 ]; then
  echo "✗ 布局断言有失败"
  exit 1
fi
echo "✓ 布局全部通过"

if [ "${1:-}" = "--quick" ]; then exit 0; fi

# ── 自检：断言必须有牙齿 ────────────────────────────────
# 把修好的地方分别「改回 bug」，断言必须变红。红不了说明测试是恒真的。
# 前两处就是这次真正修掉的 bug（空状态偏上 18px），第三处是 review 才发现的那个。
echo
echo "自检：把修好的地方改回去，断言应该变红"

expect_red() {  # expect_red <说明> <变异 html> <期望变红的断言关键字> [宽度]
  # 宽度可指定：有些断言只在最窄处才红（比如「按钮文字被裁」只在 520px 出现），
  # 固定用 1200 跑的话变异会静默通过，自检就成了摆设。
  local label="$1" html="$2" needle="$3" width="${4:-1200}" out
  out="$("$TMP/shot" --html "$html" --width "$width" --height 860 \
        --js-file "$FIX" --js-file "$PROBE" --probe \
        | "$NODE" "$ROOT/Scripts/layout-report.cjs" --width "$width" 2>&1)" || true
  # 用 grep -F 做纯子串匹配：C locale 下含多字节字符的正则（[已未] 之类）会静默失配
  if echo "$out" | grep -F '✗ ' | grep -Fq "$needle"; then
    echo "  ✓ $label 改回后确实变红"
  else
    echo "  ✗ $label 自检失败：改回 bug 后断言仍然全绿，说明断言没有牙齿"
    echo "$out" | grep -F '✗' | sed 's/^/      /' || true
    return 1
  fi
}

mutate() {  # mutate <输出文件> <sed 参数>...
  local out="$1"; shift
  sed "$@" "$HTML" > "$out"
  if diff -q "$HTML" "$out" >/dev/null; then
    echo "  ✗ 自检失败：变异没生效（源码结构变了？）"; return 1
  fi
}

RC=0

# ① 空状态撑高改回旧写法（用视口高减常数）
mutate "$TMP/mut-empty.html" \
  's|  min-height: 100%;|  min-height: calc(100vh - var(--h-topbar-total) - 76px);|' || RC=1
expect_red "空状态 min-height（旧公式）" "$TMP/mut-empty.html" "空状态：垂直居中" || RC=1

# ② 空状态时把上下留白收平的那条规则去掉 → 内容盒不再对称，居中又会偏上
mutate "$TMP/mut-pad.html" \
  's|\.content:has(> \.grid\.is-empty){ padding-bottom: 4px; }|/* removed */|' || RC=1
expect_red "空状态下收平内边距" "$TMP/mut-pad.html" "空状态：垂直居中" || RC=1

# ③ 去掉 .chip[hidden]：作者样式的 .chip{display:inline-flex} 会盖掉 UA 的 [hidden]
mutate "$TMP/mut-chip.html" \
  's|\.chip\[hidden\]{ display:none; }|/* removed */|' || RC=1
expect_red ".chip[hidden] 规则" "$TMP/mut-chip.html" "藏起来时真的不占位" || RC=1

# ④ 顶栏让位改回旧写法：搜索框不再可缩，压力全给按钮。
#    两处一起改回去才算「还原成 bug」——只改一处的话另一处仍在兜着。
#    这条**必须在最窄宽度下跑**：1200px 下空间富余，怎么改都不会裁。
mutate "$TMP/mut-topbar.html" \
  -e '/^\.search{/,/^}/ s|^  min-width: 0;$||' \
  -e 's|  \.search{ width:auto; flex:1 1 0; min-width:96px; max-width:200px; }|  .search{ width:auto; flex:1 1 auto; max-width:200px; }|' \
  || RC=1
expect_red "顶栏让位（搜索框可缩）" "$TMP/mut-topbar.html" "按钮没被压得比内容还窄" 520 || RC=1

# ⑤ 卡片头部整个长回来（出处 + 徽标 + 来源名 + 时间）。
#    用户连着两次要求把这些从卡片上撤掉，所以这条要一直盯着。
mutate "$TMP/mut-head.html" \
  's#\${starMark}\${inner}#\${starMark}<div class="card__head"><span class="card__title">\${hl(t0)}</span></div>\${inner}#' \
  || RC=1
expect_red "卡片头部又长回来" "$TMP/mut-head.html" "出处也不在卡片上了" || RC=1

# ⑥ 有星标也不给角标让位：正文两端对齐会一直写到内容盒右沿，就和 ★ 叠上了。
#    这条只在「有星标」的卡片上才看得出来——探针的样例数据里必须真有这么一条。
mutate "$TMP/mut-star.html" \
  's#\.card\[data-star="1"\]{ --star-w: 16px; }#/* removed */#' || RC=1
expect_red "星标不给角标让位" "$TMP/mut-star.html" "星标没有压到正文上" || RC=1

# ⑦ 窄窗下列表行不再给角标让位。列表行右侧本来有 84px 的操作槽，角标落在槽里；
#    ≤720px 时那条槽会被撤掉（padding-right 变 16px），得给有星标的行补回来。
#    这条**只在 520px 下会红**：宽一点右侧还有 84px，角标压不到正文。
mutate "$TMP/mut-star-narrow.html" \
  's#  \.grid\.list \.card\[data-star="1"\]{ padding-right: 30px; }##' || RC=1
expect_red "窄窗下列表行不给角标让位" "$TMP/mut-star-narrow.html" "列表视图：星标没有压到正文上" 520 || RC=1

echo
if [ "$RC" -ne 0 ]; then
  echo "✗ 自检有失败"
  exit 1
fi
echo "✓ 断言有牙齿：改回 bug 后确实变红"
