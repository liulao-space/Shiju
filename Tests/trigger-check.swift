// 触发判据的回归测试：拖拽（DragTracker）+ 剪贴板（ClipboardTrigger）+
// 快捷键配方（HotKeySpec）+ 快捷键登记（HotKeyCenter 的失败记录与回滚）。
//
// 前几块都是**纯逻辑**，所以能用假数据把各种时序和边界喂进去。
// 之所以必须这样测，是因为它们的坑都在「看不见的地方」：
//
//   拖拽：两个 bug 只在真实鼠标时序下暴露
//     bug A：按 leftMouseDragged 事件个数判 → 快速一划只收到 1 个事件就整类漏掉
//     bug B：只累加拖拽事件之间的差值 → 单事件时没有参照点，位移恒为 0
//
//   剪贴板：坑全在**误触发**上——自己写的、取词的往返、复制文件、密码框、
//     按钮上已经挂着同一段。这些都不报错，只会让用户觉得「这软件怎么老乱弹」。
//
//   快捷键配方：坑在「只按一个字母也会被接受」——那样会把那个键从所有应用手里抢走。
//
//   快捷键登记：坑在**失败之后那些记录还对不对**——注册不上不报错、不崩溃，
//     只是「用户改了个被占用的组合，界面上什么提示都没有」，最难发现。
//     这一组要真去注册全局快捷键（Carbon 在命令行进程里可用）。
//
// 直接 swiftc 编译运行，不进 Package.swift：
// 主 target 是 executableTarget 且入口在 main.swift，做成 testTarget 会让
// 顶层代码在测试进程里跑起来（app.run() 会把测试挂住）。

import AppKit
import Carbon

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)\(detail().isEmpty ? "" : "  —— \(detail())")")
    }
}

func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool { abs(a - b) < tol }

// ============================================================ DragTracker

print("DragTracker")

// ── 常规划选：多个拖拽事件 ──────────────────────────────
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 100, y: 100))
    for x in stride(from: 120, through: 200, by: 20) { t.extend(to: NSPoint(x: CGFloat(x), y: 100)) }
    let (hadStart, distance) = t.finish(at: NSPoint(x: 200, y: 100))
    check("常规划选：认得出这是一次拖拽", hadStart)
    check("常规划选：位移是 100pt", near(distance, 100), "实际 \(distance)")
    check("常规划选：判定为选择动作",
          DragTracker.isSelection(hadStart: hadStart, distance: distance))
}

// ── bug A + bug B 的回归：快速一划，只收到 1 个拖拽事件 ──
// 系统会合并鼠标事件，这是真实会发生的时序。
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 100, y: 100))
    t.extend(to: NSPoint(x: 160, y: 100))       // 只此一个拖拽事件
    let (hadStart, distance) = t.finish(at: NSPoint(x: 200, y: 100))
    check("快速一划（仅 1 个拖拽事件）：位移不是 0", distance > 0, "实际 \(distance)")
    check("快速一划：位移取满 100pt（起点来自 mouseDown，末段来自 mouseUp）",
          near(distance, 100), "实际 \(distance)")
    check("快速一划：仍然判定为选择动作（bug A/B 回归）",
          DragTracker.isSelection(hadStart: hadStart, distance: distance))
}

// ── 手抖的单击：不该触发 ────────────────────────────────
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 100, y: 100))
    let (hadStart, distance) = t.finish(at: NSPoint(x: 101, y: 101))
    check("手抖单击：位移约 1.4pt", near(distance, 1.414, 0.01), "实际 \(distance)")
    check("手抖单击：不判定为选择动作",
          !DragTracker.isSelection(hadStart: hadStart, distance: distance))
}

// ── 阈值边界 ────────────────────────────────────────────
do {
    check("阈值边界：正好 4pt 算触发",
          DragTracker.isSelection(hadStart: true, distance: 4))
    check("阈值边界：3.9pt 不算触发",
          !DragTracker.isSelection(hadStart: true, distance: 3.9))
    check("阈值边界：没看到按下就不触发",
          !DragTracker.isSelection(hadStart: false, distance: 999))
}

// ── 没看到 mouseDown（应用刚启动就松手）：无从判断 ──────
do {
    var t = DragTracker()
    t.extend(to: NSPoint(x: 300, y: 300))       // 没有 begin
    let (hadStart, distance) = t.finish(at: NSPoint(x: 400, y: 400))
    check("无 mouseDown：不认这是一次拖拽", !hadStart)
    check("无 mouseDown：不判定为选择动作",
          !DragTracker.isSelection(hadStart: hadStart, distance: distance))
}

// ── 位移是「沿途累加」，不是「首尾直线距离」 ────────────
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 0, y: 0))
    t.extend(to: NSPoint(x: 10, y: 0))
    t.extend(to: NSPoint(x: 10, y: 10))
    let (_, distance) = t.finish(at: NSPoint(x: 10, y: 10))
    check("位移按沿途累加（20pt，而非首尾直线 14.1pt）",
          near(distance, 20), "实际 \(distance)")
}

// ── finish 之后必须复位，否则会污染下一次判定 ───────────
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 0, y: 0))
    _ = t.finish(at: NSPoint(x: 500, y: 500))
    check("finish 后不再处于跟踪态", !t.isTracking)
    let (hadStart, distance) = t.finish(at: NSPoint(x: 500, y: 500))
    check("finish 后位移已复位", near(distance, 0), "实际 \(distance)")
    check("finish 后再次 finish 不算选择",
          !DragTracker.isSelection(hadStart: hadStart, distance: distance))
}

// ── begin 必须重置上一次的残留 ──────────────────────────
do {
    var t = DragTracker()
    t.begin(at: NSPoint(x: 0, y: 0))
    t.extend(to: NSPoint(x: 300, y: 0))          // 上一次拖了 300
    t.begin(at: NSPoint(x: 0, y: 0))             // 新的一次按下
    let (_, distance) = t.finish(at: NSPoint(x: 5, y: 0))
    check("begin 会清掉上一次的位移残留", near(distance, 5), "实际 \(distance)")
}

// ============================================================ ClipboardTrigger

print("\nClipboardTrigger")

/// 默认参数全填好，用例里只写关心的那几个。
func decide(_ t: inout ClipboardTrigger,
            text: String,
            count: Int,
            file: Bool = false,
            pending: String? = nil,
            secure: Bool = false,
            ignored: Bool = false) -> ClipboardTrigger.Decision {
    t.decide(text: text, changeCount: count, hasFileURL: file,
             pendingText: pending, secureInput: secure, ignoredApp: ignored)
}

func isAccept(_ d: ClipboardTrigger.Decision) -> Bool { d == .accept }

// ── 基本：第一次复制就该弹 ──────────────────────────────
do {
    var t = ClipboardTrigger()
    check("第一次复制文本 → 弹按钮", isAccept(decide(&t, text: "人间送小温。", count: 1)))
}

// ── 同一段内容再复制一次：不重复弹 ──────────────────────
// 场景：用户复制同一句话两遍，或者取词自己造成的写入。
do {
    var t = ClipboardTrigger()
    _ = decide(&t, text: "死生亦大矣。", count: 1)
    check("同一段内容再来一次 → 不弹", !isAccept(decide(&t, text: "死生亦大矣。", count: 2)))
    check("换成新内容 → 又该弹", isAccept(decide(&t, text: "新的句子。", count: 3)))
}

// ── 空白内容 ────────────────────────────────────────────
do {
    var t = ClipboardTrigger()
    check("空字符串 → 不弹", !isAccept(decide(&t, text: "", count: 1)))
    check("只有空白 → 不弹", !isAccept(decide(&t, text: " \n\t ", count: 2)))
}

// ── 自己写的剪贴板（面板卡片上的「复制」）──────────────
do {
    var t = ClipboardTrigger()
    t.claimOwnWrite(changeCount: 7)
    check("自己写的那次变更 → 不弹",
          !isAccept(decide(&t, text: "卡片正文", count: 7)))
    // 认领只针对那一个 changeCount，之后的真实复制照样要弹
    check("认领之后的下一次真实复制 → 照弹",
          isAccept(decide(&t, text: "卡片正文", count: 8)))
}

// ── 安全输入 / 忽略名单 / 复制文件 ──────────────────────
do {
    var t = ClipboardTrigger()
    check("安全输入（密码框）→ 不弹",
          !isAccept(decide(&t, text: "hunter2", count: 1, secure: true)))
    check("前台应用在忽略名单里 → 不弹",
          !isAccept(decide(&t, text: "hunter2", count: 2, ignored: true)))
    check("复制的是文件而不是文本 → 不弹",
          !isAccept(decide(&t, text: "/Users/x/a.png", count: 3, file: true)))
}

// ── 按钮上已经挂着同一段：不弹第二次 ────────────────────
// 场景：先拖拽划选（按钮已弹出），紧接着 ⌘C。
do {
    var t = ClipboardTrigger()
    check("按钮上挂着同一段 → 不弹",
          !isAccept(decide(&t, text: "不要温和地走进那个良夜。", count: 1,
                           pending: "不要温和地走进那个良夜。")))
    check("只差首尾空白也算同一段",
          !isAccept(decide(&t, text: "  不要温和地走进那个良夜。\n", count: 2,
                           pending: "不要温和地走进那个良夜。")))
    check("按钮上挂的是别的内容 → 该弹",
          isAccept(decide(&t, text: "被误解是表达者的宿命。", count: 3,
                          pending: "不要温和地走进那个良夜。")))
}

// ── 被挡下的那一次**不能**更新基线 ─────────────────────
// 这条是整套判据的地基：中途 return 时如果顺手把 lastSeen 改了，
// 一次误判就会让后面所有正常的复制都被当成「和上次一样」而漏掉。
do {
    var t = ClipboardTrigger()
    _ = decide(&t, text: "A", count: 1)                     // 认过 A
    _ = decide(&t, text: "B", count: 2, secure: true)       // B 被挡下
    check("被挡下的内容不会污染基线：B 之后正常复制仍能弹",
          isAccept(decide(&t, text: "B", count: 3)))
}

// ── 取词的「备份 → ⌘C → 还原」往返 ─────────────────────
// 取词读剪贴板之前会把现状记为基线（resync），所以：
//   中间态（选中的文字）和还原后的原内容都不该触发。
do {
    var t = ClipboardTrigger()
    t.resync(text: "用户原本的剪贴板")           // 取词开始
    check("取词往返后回到原内容 → 不弹",
          !isAccept(decide(&t, text: "用户原本的剪贴板", count: 1)))
    check("取词之后用户真复制了新东西 → 该弹",
          isAccept(decide(&t, text: "选中的那句", count: 2)))

    // 如果没有 resync：还原回原内容会被当成一次「新复制」而误弹。
    // 这里显式记下这个差别，免得以后有人觉得 resync 可有可无。
    var t2 = ClipboardTrigger()
    _ = decide(&t2, text: "选中的那句", count: 1)          // 中间态漏了进来
    check("（反证）少了 resync 时，还原回去会被误当成新复制",
          isAccept(decide(&t2, text: "用户原本的剪贴板", count: 2)))
}

// ============================================================ HotKeySpec

print("\nHotKeySpec")

do {
    let s = HotKeySpec(keyCode: UInt32(kVK_ANSI_S), modifiers: HotKeySpec.opt | HotKeySpec.cmd)
    check("显示成 ⌥⌘S", s.display == "⌥⌘S", "实际 \(s.display)")
    check("存进 UserDefaults 再读回来不变", HotKeySpec(raw: s.raw) == s, "raw = \(s.raw)")
}

do {
    let all = HotKeySpec.ctrl | HotKeySpec.opt | HotKeySpec.shift | HotKeySpec.cmd
    let s = HotKeySpec(keyCode: UInt32(kVK_ANSI_X), modifiers: all)
    // 顺序按 macOS 习惯：⌃⌥⇧⌘
    check("修饰键顺序是 ⌃⌥⇧⌘", s.display == "⌃⌥⇧⌘X", "实际 \(s.display)")
}

do {
    check("只有 ⇧ 不算合法（⇧A 就是个大写字母）",
          !HotKeySpec.isValid(modifiers: HotKeySpec.shift))
    check("没有修饰键不算合法（会把那个键从所有应用手里抢走）",
          !HotKeySpec.isValid(modifiers: 0))
    check("⌘ 算合法", HotKeySpec.isValid(modifiers: HotKeySpec.cmd))
    check("⌥ 算合法", HotKeySpec.isValid(modifiers: HotKeySpec.opt))
    check("⌃ 算合法", HotKeySpec.isValid(modifiers: HotKeySpec.ctrl))
    check("⌃⇧ 算合法（有 ⌃ 就够）",
          HotKeySpec.isValid(modifiers: HotKeySpec.ctrl | HotKeySpec.shift))
}

do {
    check("空串解析成 nil（= 用户主动清掉了）", HotKeySpec(raw: "") == nil)
    check("乱码解析成 nil", HotKeySpec(raw: "abc") == nil)
    check("缺一段解析成 nil", HotKeySpec(raw: "1") == nil)
    check("只有 ⇧ 的存档解析成 nil（免得旧数据把非法组合带进来）",
          HotKeySpec(raw: "1-\(HotKeySpec.shift)") == nil)
}

// ── 修饰键转换：只能带出该带的那四位 ────────────────────
// NSEvent.modifierFlags 里混着 numericPad / function / capsLock，它们**不是**
// Carbon 的修饰键常量，混进 RegisterEventHotKey 的参数会导致注册失败。
// 这里断言的是**结果值**而不是「有没有掩位」，所以「把 AppKit 的位直接当
// Carbon 的位用」这类写法会被抓住（见 Scripts/test-trigger.sh 的变异自检）。
do {
    let flags: NSEvent.ModifierFlags = [.command, .numericPad, .function, .capsLock]
    check("转换时忽略 numericPad / function / capsLock",
          HotKeySpec.carbonModifiers(from: flags) == HotKeySpec.cmd,
          "实际 \(HotKeySpec.carbonModifiers(from: flags))")
    check("四个修饰键都转得对",
          HotKeySpec.carbonModifiers(from: [.control, .option, .shift, .command])
            == (HotKeySpec.ctrl | HotKeySpec.opt | HotKeySpec.shift | HotKeySpec.cmd))
}

do {
    check("认识的键码给出可读名字",
          HotKeySpec.keyName(UInt32(kVK_ANSI_S)) == "S",
          "实际 \(HotKeySpec.keyName(UInt32(kVK_ANSI_S)))")
    check("认不出的键码退化成「键码 N」而不是猜一个错名字",
          HotKeySpec.keyName(9999) == "键码 9999",
          "实际 \(HotKeySpec.keyName(9999))")
}

do {
    check("默认「打开面板」是 ⌥⌘S", Settings.defaultOpenPanel.display == "⌥⌘S",
          "实际 \(Settings.defaultOpenPanel.display)")
    check("默认「收录选中文字」是 ⌥⌘C", Settings.defaultCapture.display == "⌥⌘C",
          "实际 \(Settings.defaultCapture.display)")
    check("两个默认值不重复", Settings.defaultOpenPanel != Settings.defaultCapture)
}

// ============================================================ HotKeyCenter
//
// 这一组要**真的去注册全局快捷键**（Carbon 在命令行进程里可用，已实测），
// 因为要验的是「注册失败之后那些记录还对不对」，光靠值类型测不到。
// 覆盖三处踩过的坑：
//   · 失败的那次不登记 → 两个槽位共用同一个 id → 后一个注册成功会把前一个的失败记录冲掉
//   · 回滚时重新装旧组合，装成功顺手把失败原因清了 → 设置窗口里看不到任何提示
//   · 注销掉失败的槽位，失败记录没跟着走 → 窗口里一直挂着一条早就无效的报错

print("\nHotKeyCenter（失败记录与回滚）")

/// 找一个当前空闲的 ⌃⌥⌘ 组合：试登记一下再立刻注销。
/// 找不到（组合都被占了）就返回 nil，整组跳过——**环境不具备时跳过，
/// 而不是报失败**，否则本机的按键占用会被误读成代码坏了。
func freeSpec(_ codes: [Int]) -> HotKeySpec? {
    for code in codes {
        let s = HotKeySpec(keyCode: UInt32(code),
                           modifiers: HotKeySpec.ctrl | HotKeySpec.opt | HotKeySpec.cmd)
        let id = HotKeyCenter.shared.register(s) {}
        let ok = HotKeyCenter.shared.activeFailures.isEmpty
        HotKeyCenter.shared.unregister(id: id)
        if ok { return s }
    }
    return nil
}

do {
    let center = HotKeyCenter.shared
    // 两个组合必须来自不相交的键码池，否则可能挑到同一个。
    if let a = freeSpec([kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M]),
       let b = freeSpec([kVK_ANSI_N, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R]) {

        let idA = center.register(a) {}
        check("登记成功后没有失败记录", center.activeFailures.isEmpty,
              "实际 \(center.activeFailures)")

        // 同一个组合再登记一次 → Carbon 必定拒绝（eventHotKeyExistsErr）
        let idB = center.register(a) {}
        check("重复登记同一组合 → 记下失败原因", center.activeFailures.count == 1,
              "实际 \(center.activeFailures)")
        check("失败的那次也占一个独立槽位（id 不与他人共用）", idB != idA)

        check("失败的槽位改到空闲组合 → update 成功", center.update(id: idB, spec: b))
        check("改成功后失败记录清掉", center.activeFailures.isEmpty,
              "实际 \(center.activeFailures)")

        // 现在 a 归 idA、b 归 idB。把 idA 也改成 b → 撞车 → 必须回滚到 a
        check("改成已被占用的组合 → update 返回 false", !center.update(id: idA, spec: b))
        check("回滚不能把失败原因冲掉（回滚那次成功不该清掉它）",
              center.activeFailures.count == 1, "实际 \(center.activeFailures)")

        // 反证「真的回滚了」：a 应该还在 idA 手里，再登记一次必然失败
        let idC = center.register(a) {}
        check("回滚确实把旧组合装回去了（a 仍被占用）",
              center.activeFailures.count == 2, "实际 \(center.activeFailures)")
        center.unregister(id: idC)
        check("注销掉失败的槽位后，它的失败记录跟着走",
              center.activeFailures.count == 1, "实际 \(center.activeFailures)")

        center.unregister(id: idA)
        check("注销掉出问题的槽位后，失败记录清空",
              center.activeFailures.isEmpty, "实际 \(center.activeFailures)")
        center.unregister(id: idB)
    } else {
        print("  · 跳过：找不到两个空闲的 ⌃⌥⌘ 组合，本机占用太多")
    }
}

print("\n  \(passed) 通过 / \(failed) 失败")
exit(failed == 0 ? 0 : 1)
