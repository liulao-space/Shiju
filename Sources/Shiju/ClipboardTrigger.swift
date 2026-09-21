import Foundation

/// 剪贴板触发的判据。
///
/// **纯逻辑**：不碰 `NSPasteboard`、不看时钟，所有输入由调用方喂进来
/// （I/O 那半在 `ClipboardWatcher.swift`）。这样「哪些情况该弹按钮」
/// 就能用假数据锁住——这块的难点全在**误触发**上（自己写的剪贴板、
/// 取词的往返、复制文件、密码框、按钮上已经挂着同一段……），
/// 而这些只有把边界一条条喂一遍才测得出来（见 `Scripts/test-trigger.sh`）。
///
/// 为什么需要这条路径：除了「拖拽划选」和「双击/三击选词」，用户还有两种
/// 复制方式——**⌘C** 和**右键菜单的「复制」**。这两条不产生任何拖拽事件，
/// 早先完全不触发，表现就是「我明明复制了，按钮没出来」。
/// 而且在微信这类取词拿不到文本的应用里，剪贴板是唯一可靠的信息源。
struct ClipboardTrigger {

    enum Decision: Equatable {
        case accept
        /// 不弹。原因直接进诊断日志——「为什么没弹」必须能事后查。
        case ignore(String)
    }

    /// 上一次「已经认过」的剪贴板内容。
    private(set) var lastSeen: String?

    /// 我们自己刚写进剪贴板的 `changeCount`（面板卡片上的「复制」按钮）。
    private var ownWriteChangeCount: Int = -1

    /// 面板写剪贴板之后调一次，把这次变更认领掉。
    /// 不认领的话，点卡片上的「复制」会把悬浮按钮叫出来——明显是错的。
    mutating func claimOwnWrite(changeCount: Int) {
        ownWriteChangeCount = changeCount
    }

    /// 把当前内容记为基线，不触发。
    ///
    /// 取词走的是「备份剪贴板 → 模拟 ⌘C → 读 → 还原」，剪贴板会绕一圈：
    /// 中间态是选中的文字，还原后是用户原本的内容。这两个都不该被当成
    /// 「用户复制了东西」——不处理的话，每次取词都会顺手多弹一次按钮，
    /// 而且弹出来的可能是用户上一次复制的东西。
    mutating func resync(text: String?) {
        lastSeen = text
    }

    mutating func decide(text raw: String,
                         changeCount: Int,
                         hasFileURL: Bool,
                         pendingText: String?,
                         secureInput: Bool,
                         ignoredApp: Bool) -> Decision {

        // 顺序有讲究：先挡掉「根本不该看」的（自己写的、密码框、忽略名单），
        // 再判内容。而 `lastSeen` **只在最后一步更新**——中途返回就更新的话，
        // 一次误触发会把基线带偏，之后所有正常的复制都会被当成
        // 「和上次一样」而静默漏掉。
        if changeCount == ownWriteChangeCount { return .ignore("是自己刚写的（面板的复制按钮）") }
        if secureInput { return .ignore("系统处于安全输入状态（密码框）") }
        if ignoredApp { return .ignore("前台应用在忽略名单里") }
        if hasFileURL { return .ignore("复制的是文件而不是文本") }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ignore("剪贴板里没有文本") }
        if text == lastSeen { return .ignore("内容和上次认过的一样") }
        if let pendingText, Snippet.normalize(pendingText) == Snippet.normalize(text) {
            return .ignore("按钮上已经挂着同一段")
        }

        lastSeen = text
        return .accept
    }
}
