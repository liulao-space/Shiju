#!/bin/bash
# 构建离屏截图/探针工具（Tests/panel-snapshot.swift）。
#
# 被 snapshot-panel.sh（出图）和 test-layout.sh（量几何）共用——
# 两处各自写一份编译逻辑，迟早会漂移成「一个能编一个编不过」。
#
# 用法：先 cd 到仓库根、设好 ROOT 与 TMP，再 `. Scripts/lib-snapshot.sh`，
# 然后调 build_snapshot_tool <输出路径>。
#
# 说明两个编译上的坑：
#   * Swift 只允许在名为 main.swift 的文件里写顶层语句 → 先拷再编。
#   * 工具链默认按 Swift 6 的严格并发检查报一堆 @MainActor 警告，而这个脚本
#     从头到尾都在主线程跑（app.run() 就是主 runloop），警告全是噪音 → -swift-version 5。
build_snapshot_tool() {
  local out="$1"
  cp "$ROOT/Tests/panel-snapshot.swift" "$TMP/main.swift"
  if ! swiftc -O -swift-version 5 -o "$out" "$TMP/main.swift" > "$TMP/build.log" 2>&1; then
    echo "✗ 编译失败："
    cat "$TMP/build.log"
    return 1
  fi
  [ -x "$out" ] || { echo "✗ 编译失败（没产出可执行文件）"; return 1; }
}
