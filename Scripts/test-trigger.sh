#!/bin/bash
# 触发判据的回归测试。
#
# 测三块**纯逻辑**，都是「不报错、只会静默地少弹或多弹」的那类问题：
#
#   1. DragTracker（拖拽划选）——「按下—拖拽—松手」的位移统计与阈值判定。
#      踩过两次坑，两次都只在**真实的鼠标时序**下才暴露：
#        bug A：按 leftMouseDragged 事件个数判 → 快速一划只收到 1 个事件，整类漏掉
#        bug B：只累加拖拽事件之间的差值 → 单事件时没有参照点，位移恒为 0（改了等于没改）
#
#   2. ClipboardTrigger（⌘C / 右键「复制」）——判「这次剪贴板变化该不该弹按钮」。
#      坑全在误触发上：自己写的剪贴板、取词的「备份→⌘C→还原」往返、复制文件、
#      密码框、按钮上已经挂着同一段。这些都不报错，只会让用户觉得
#      「这软件怎么老乱弹」或者反过来「我明明复制了怎么不弹」。
#
#   3. HotKeySpec（快捷键配方）——键码与修饰键的解析、显示、持久化。
#      坑在「只按一个字母也被接受」——那会把那个键从**所有**应用手里抢走，
#      用户录完连打字都不正常了，而且不会联想到是这里干的。
#
# 这三块都不碰 UI 层，所以能用假数据把各种时序和边界喂进去。
# 直接调 swiftc 编译运行，不进 Package.swift：主 target 是 executableTarget
# 且入口在 main.swift，做成 testTarget 会让顶层代码在测试进程里跑起来
# （app.run() 会把测试挂住）。
#
# 默认带自检：把五个修复逐个「改回 bug」，断言必须变红——
# **没有这一步，测试可能是恒真的**。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SRC_DIR="$ROOT/Sources/Shiju"
CHECK="$ROOT/Tests/trigger-check.swift"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 参与编译的源文件。只挑**不碰 UI 层**的：测试进程因此不会去建窗口、
# 不会去开数据库，也不会因为多编一个文件就把整条 AppKit/SQLite 链路拖进来。
#
# Diagnostics.swift 是被 HotKey.swift 拖进来的（注册失败要写诊断日志），
# 而它能单独编，是因为它的日志路径已经改从 Paths.swift 取——
# 原先它向 Store.databaseURL 借目录，方向是反的，也顺带把 Store 整条链带进来了。
CORE=(
  "$SRC_DIR/DragTracker.swift"
  "$SRC_DIR/ClipboardTrigger.swift"
  "$SRC_DIR/Snippet.swift"
  "$SRC_DIR/HotKey.swift"
  "$SRC_DIR/Paths.swift"
  "$SRC_DIR/Diagnostics.swift"
)

# 直接调 swiftc，不走 SwiftPM——SwiftPM 需要 --disable-sandbox 才能求值 manifest，
# 而 swiftc 不认这个参数（`error: unknown argument: '--disable-sandbox'`）。
#
# 另外 Swift 只允许在名为 main.swift 的文件里写顶层语句，
# 所以先把检查文件拷成 main.swift 再编（仓库里保留可读的文件名）。
#
# 返回值：0 = 全绿，1 = 有用例失败，2 = 编译失败。**必须区分开**——
# 自检里「变异版本编不过」不算「断言变红」，混在一起会让自检变成假绿。
build_and_run() {
  local out="$1"; shift
  cp "$CHECK" "$TMP/main.swift"
  if ! swiftc -O -o "$out" "$@" "$TMP/main.swift" > "$TMP/compile.log" 2>&1; then
    echo "✗ 编译失败："
    sed 's/^/    /' "$TMP/compile.log"
    return 2
  fi
  # 诊断日志指到临时目录：这组用例会**故意**制造「快捷键注册失败」，
  # 不重定向就会写进用户真实的那份日志里，而那份日志正是排查问题时要读的。
  SHIJU_DIAG_LOG="$TMP/diag.log" "$out"
}

echo "▸ 主用例"
rc=0
build_and_run "$TMP/check" "${CORE[@]}" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo
  if [ "$rc" -eq 2 ]; then echo "✗ 编译不过，后面的都不用跑了"; else echo "✗ 有用例失败"; fi
  exit 1
fi
echo
echo "✓ 全部通过"

if [ "${1:-}" = "--quick" ]; then exit 0; fi

# ── 自检：断言必须有牙齿 ────────────────────────────────
echo
echo "自检：把七个 bug 分别改回去，断言应该变红"

# expect_red <标签> <源文件> <sed 表达式> <变异后应出现的标记>
#
# sed 用**地址范围**（`/^    mutating func begin/,/^    }/`）圈住目标函数，
# 而不是用行号：行号会随注释增删漂移，而漂移之后 sed 静默不匹配、
# 变异版本等于原版、断言照样全绿——自检就成了摆设。
# 标记串是第二道保险：sed 没匹配上就一定找不到它。
expect_red() {
  local label="$1" src="$2" expr="$3" marker="$4"
  local mut="$TMP/mut.swift"
  sed "$expr" "$src" > "$mut"
  if ! grep -qF "$marker" "$mut" || diff -q "$src" "$mut" >/dev/null; then
    echo "  ✗ $label：没能生成变异版本（源码结构变了？）"
    return 1
  fi

  # 把 CORE 里对应的那个文件换成变异版本，其余照旧。
  local files=()
  for f in "${CORE[@]}"; do
    if [ "$f" = "$src" ]; then files+=("$mut"); else files+=("$f"); fi
  done

  local rc=0
  build_and_run "$TMP/check-mut" "${files[@]}" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ✗ $label：改回 bug 后断言仍然全绿，说明断言没有牙齿"
    return 1
  fi
  if [ "$rc" -eq 2 ]; then
    echo "  ✗ $label：变异版本编不过，sed 表达式要跟着源码改"
    return 1
  fi
  echo "  ✓ $label：改回后确实变红"
}

# bug B：begin 不记录起点位置 → 单事件时没有参照点，位移恒为 0
expect_red "拖拽 bug B（起点取自 mouseDown）" "$SRC_DIR/DragTracker.swift" \
  '/^    mutating func begin/,/^    }/ s/^        lastPoint = point$/        lastPoint = nil  \/\/ 变异/' \
  'lastPoint = nil' || exit 1

# bug A：完全丢掉拖拽事件之间的累加 → 只靠起点到终点
expect_red "拖拽 bug A（沿途累加位移）" "$SRC_DIR/DragTracker.swift" \
  '/^    mutating func extend/,/^    }/ s/^        distance += hypot(point.x - last.x, point.y - last.y)$/        _ = point  \/\/ 变异/' \
  '_ = point' || exit 1

# 剪贴板：被挡下的那一次顺手更新了基线 → 之后正常的复制会被当成「和上次一样」漏掉
expect_red "剪贴板（被挡下的那次不污染基线）" "$SRC_DIR/ClipboardTrigger.swift" \
  's|^        if secureInput { return \.ignore(|        if secureInput { lastSeen = raw; return .ignore(|' \
  'lastSeen = raw' || exit 1

# 快捷键：把「至少要有一个非 ⇧ 的修饰键」放宽成「有修饰键就行」
expect_red "快捷键（只按 ⇧ 不算合法）" "$SRC_DIR/HotKey.swift" \
  's#^        modifiers & (cmd | opt | ctrl) != 0$#        modifiers != 0  // 变异#' \
  'modifiers != 0  // 变异' || exit 1

# 快捷键：把 AppKit 的修饰位直接当 Carbon 的位用（经典错法，结果是注册不上）
expect_red "快捷键（只带出该带的四位修饰键）" "$SRC_DIR/HotKey.swift" \
  's/^        var m: UInt32 = 0$/        var m: UInt32 = UInt32(flags.rawValue)  \/\/ 变异/' \
  '// 变异' || exit 1

# 登记中心：注册失败就不登记 → 失败原因无处可挂，界面永远没有提示
expect_red "快捷键登记（失败的那次也要占一个槽位）" "$SRC_DIR/HotKey.swift" \
  's/^        registrations.append(reg)$/        if reg.failure == nil { registrations.append(reg) }  \/\/ 变异/' \
  '// 变异' || exit 1

# 登记中心：回滚成功顺手把失败原因清了 → 用户看不到「已被占用」
expect_red "快捷键登记（回滚不回填失败原因）" "$SRC_DIR/HotKey.swift" \
  's/^        registrations\[idx\]\.failure = failure$/        \/\/ 变异/' \
  '// 变异' || exit 1

echo
echo "✓ 断言有牙齿：改回 bug 后确实变红"
