import AppKit
import Carbon
import Foundation

/// 轮询剪贴板，发现「用户复制了文本」就回调。
///
/// 判据全在 `ClipboardTrigger`（纯逻辑、可单测），这里只负责 I/O：
/// 定时器、读 `NSPasteboard`、查前台应用。
///
/// 剪贴板**没有事件通知**（`NSPasteboard` 不发通知），只能轮询 `changeCount`。
/// 这是所有剪贴板管理器的通行做法，读一个整数，开销可以忽略。
/// 这里的「轮询」和触发判据那块的「不要轮询」不矛盾：那边有事件可用（鼠标），
/// 这边没有。
final class ClipboardWatcher {

    /// 用户复制了一段文本。
    var onCopy: ((String) -> Void)?

    /// 按钮当前挂着的待收录文本。用来避免「先划选、再 ⌘C」时弹两次。
    var pendingText: (() -> String?)?

    /// 0.4s。更快没有意义（用户感知不到），更慢就开始显得迟钝。
    private let interval: TimeInterval = 0.4

    private var timer: Timer?
    private var trigger = ClipboardTrigger()
    private var lastChangeCount: Int
    /// 取词期间暂停：那段时间剪贴板的变化是我们自己造成的。
    private var paused = false

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // .common 而不是 .default：菜单弹出、窗口拖动期间也要照常跑。
        // 挂 .default 的话，菜单一打开轮询就停了，用户「在右键菜单里选复制」反而抓不到。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 面板自己写剪贴板之后调一次，把这次变更认领掉。
    func claimOwnWrite() {
        lastChangeCount = NSPasteboard.general.changeCount
        trigger.claimOwnWrite(changeCount: lastChangeCount)
    }

    func pause() { paused = true }

    /// 取词结束：把剪贴板现状重新记为基线，整段往返就此消化掉。
    func resume() {
        lastChangeCount = NSPasteboard.general.changeCount
        trigger.resync(text: NSPasteboard.general.string)
        paused = false
    }

    private func tick() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !paused else { return }

        let text = pb.string(forType: .string) ?? ""
        let front = NSWorkspace.shared.frontmostApplication

        switch trigger.decide(text: text,
                              changeCount: count,
                              hasFileURL: pb.types?.contains(.fileURL) ?? false,
                              pendingText: pendingText?(),
                              secureInput: IsSecureEventInputEnabled(),
                              ignoredApp: SelectionReader.isIgnoredApp(bundleID: front?.bundleIdentifier)) {
        case .accept:
            let chars = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            Diag.note("剪贴板触发：\(chars) 字（\(front?.localizedName ?? "未知应用")）")
            onCopy?(text)
        case .ignore(let reason):
            // 每一次「剪贴板变了但没弹」都留痕：用户报「复制了没反应」时，
            // 这条日志能直接区分「压根没检测到」和「检测到了但被规则挡了」。
            Diag.note("剪贴板变了但不触发：\(reason)")
        }
    }
}
