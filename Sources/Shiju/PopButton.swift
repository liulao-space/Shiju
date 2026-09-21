import AppKit
import Foundation

/// 收录结果，决定按钮显示什么状态。
enum CaptureOutcome {
    case inserted(Snippet)
    case duplicate
    case failed
}

/// 已经取到手、等待用户点「收录」的内容。
///
/// 取词在拖拽结束时就完成，按钮只负责落库——这样点击路径是同步的，
/// 不会出现「点下去才发现取词失败」。同时因为窗口不抢焦点，
/// 原选区在整个过程中一直有效。
struct PendingCapture {
    let text: String
    let appName: String?
    /// 来源应用的 bundleID。用于在按钮弹出之后异步补出处链接。
    let sourceBundleID: String?
    let sourceTitle: String?
    /// 出处链接。取它要走 AppleScript（慢，且可能弹「自动化」授权框），
    /// 所以是 var：先让按钮弹出来，URL 由 AppDelegate 在后台补上。
    var sourceURL: String?
}

/// 悬浮收录按钮。
///
/// 最关键的一点：**绝不抢焦点**。
/// 用无边框普通 NSWindow，重写 `canBecomeKey` / `canBecomeMain` 返回 false，
/// 窗口就永远不会成为 key window，原应用不失焦，选区也不会被系统清除。
/// 这是整个方案能成立的前提——一旦抢了焦点，按钮点下去就抓不到内容了。
final class PopButtonWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        // 全屏应用之上也要能显示，否则在 Safari 全屏阅读时按钮会消失。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        alphaValue = 0
    }
}

/// 胶囊按钮本体。自绘而非用 NSButton，是为了完全控制尺寸、圆角与状态配色。
final class PillView: NSView {

    enum Style {
        case idle        // 收录
        case done        // 已收录
        case duplicate   // 已收过

        var label: String {
            switch self {
            case .idle: return "收录"
            case .done: return "已收录"
            case .duplicate: return "已收过"
            }
        }
    }

    var style: Style = .idle { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    private let height: CGFloat = 30
    private let dotDiameter: CGFloat = 7
    private let paddingH: CGFloat = 12
    private let gap: CGFloat = 7

    override var intrinsicContentSize: NSSize {
        let font = Self.labelFont
        let textWidth = (style.label as NSString)
            .size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(paddingH * 2 + dotDiameter + gap + textWidth),
                      height: height)
    }

    private static var labelFont: NSFont {
        .systemFont(ofSize: 12.5, weight: .medium)
    }

    private var accent: NSColor {
        switch style {
        case .idle: return .controlAccentColor
        case .done: return .systemGreen
        case .duplicate: return .secondaryLabelColor
        }
    }

    private var fill: NSColor {
        // 用 controlBackgroundColor 而非纯白：深色模式下自动跟随。
        NSColor.controlBackgroundColor.withAlphaComponent(hovering ? 1.0 : 0.97)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = bounds.height / 2

        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        accent.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // 状态圆点
        let dotRect = NSRect(x: paddingH,
                             y: (self.bounds.height - dotDiameter) / 2,
                             width: dotDiameter, height: dotDiameter)
        accent.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // 文案
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let text = style.label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: paddingH + dotDiameter + gap,
                              y: (self.bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    // 无边框窗口里，按住不松手会把事件吃掉；这里显式吞掉 mouseDown 以免穿透。
    override func mouseDown(with event: NSEvent) {}
}

/// 悬浮按钮的显隐生命周期。
///
/// 三条收起规则，直接决定这个功能「会不会烦」：
/// - 鼠标滚动累计超过 80pt → 收起（说明你在继续往下读，不需要它）
/// - 鼠标移出按钮外扩 40pt 的区域 → 收起（说明你已经走开了）
/// - 静置 4s → 淡出
///
/// 例外：刚发生过 ⌘C 时不因鼠标移开而收起，否则用户「复制后想看按钮」会扑空。
///
/// 另有两条防误触的前提，都是为「显示一下就消失」这个 bug 加的：
/// - 位置在出现的那一刻**现取**鼠标坐标，不用调用方手里的旧快照
/// - 出现后 0.6s 内不理会「鼠标移开」（详见 `mouseMoveGrace`）
final class PopButtonController {

    var onCapture: ((PendingCapture) -> CaptureOutcome)?
    var onUndo: ((String) -> Void)?

    private let window = PopButtonWindow()
    private let pill = PillView()

    private var dismissTimer: Timer?
    private var undoWindow: Timer?
    private var accumulatedScroll: CGFloat = 0
    private var lastCmdCAt: Date?
    private var shownAt: Date?

    private var pending: PendingCapture?
    private var capturedSnippetID: String?

    private let autoDismissDelay: TimeInterval = 4.0
    private let undoWindowLength: TimeInterval = 3.0
    private let scrollDismissThreshold: CGFloat = 80

    /// 鼠标离按钮多远才算「走开了」。
    ///
    /// 原来是 24pt，而按钮摆在光标右下 40pt 处——按代码常数复算，
    /// **光标只要往上移 14pt 就出界**（按钮翻到光标上方时则是往下 12pt）。
    /// 手一抖就收起。外扩到 40pt 后，最紧方向有 28pt 余量。
    private let hoverPadding: CGFloat = 40

    /// 按钮出现后的这段时间内，不因鼠标移开而收起。
    ///
    /// 这道闸是必须的：从 mouseUp 到按钮真正出现，中间要跑
    /// 前台应用查询 → 窗口标题(AX) → 浏览器 URL(AppleScript) → 模拟 ⌘C 取词，
    /// 实测几十到几百毫秒。这段时间里用户的手早就在动了，
    /// 没有宽限期的话，按钮一出现就已经「在光标之外」，紧接着的
    /// mouseMoved 会立刻把它收掉——表现就是「显示一下就消失」。
    private let mouseMoveGrace: TimeInterval = 0.6

    var isVisible: Bool { window.alphaValue > 0.01 }

    /// 按钮当前挂着的待收录文本。剪贴板那条触发路径用它去重：
    /// 「先划选、再 ⌘C」时不该弹第二次。
    var pendingTextValue: String? { pending?.text }

    init() {
        window.contentView = pill
        pill.autoresizingMask = [.width, .height]
    }

    /// 「用户刚复制过」的信号。
    ///
    /// 原先这里挂的是 `NSEvent.addGlobalMonitorForEvents(matching: [.keyDown])`
    /// 直接监听 ⌘C。那个监听需要**「输入监控」权限**（和辅助功能是两个独立授权），
    /// 没授予时它只是静默不工作——于是「刚复制过不收起」这条例外悄悄失效，
    /// 用户看到的就是「⌘C 之后按钮一闪就没了」，而且怎么查都查不出原因。
    ///
    /// 现在改由剪贴板监听来提供这个信号：它不需要任何额外权限，
    /// 而且「剪贴板变了」本来就是「用户复制过」的准确含义。
    func noteCopyDetected() {
        lastCmdCAt = Date()
    }

    // MARK: - 显示

    /// 拖拽路径：取词已完成，等用户点击确认。
    ///
    /// 刻意**不接收调用方算好的锚点**。取词是异步的，调用方手里那个坐标是
    /// 几百毫秒前的快照（见 `mouseMoveGrace` 的说明）；用它摆按钮，按钮就会
    /// 落在光标之外，出现即被收掉。位置一律在这里现取。
    func show(_ capture: PendingCapture) {
        pending = capture
        capturedSnippetID = nil
        pill.style = .idle
        pill.onClick = { [weak self] in self?.handleClick() }
        present()
        scheduleAutoDismiss()
    }

    /// 快捷键路径：内容已经落库，按钮只作确认提示（可撤销）。
    func showResult(_ outcome: CaptureOutcome) {
        pending = nil
        pill.onClick = { [weak self] in self?.handleClick() }
        switch outcome {
        case .inserted(let snippet):
            capturedSnippetID = snippet.id
            pill.style = .done
            present()
            scheduleUndoWindow()
        case .duplicate:
            capturedSnippetID = nil
            pill.style = .duplicate
            present()
            scheduleAutoDismiss()
        case .failed:
            dismiss(reason: "取词失败")
        }
    }

    private func present() {
        accumulatedScroll = 0

        // 现取鼠标位置，而不是用调用方传进来的（可能已经过期的）坐标。
        // 这样按钮必然出现在光标旁边，鼠标也就必然落在下面的 hover 区里，
        // 不会被紧随其后的 mouseMoved 误收。
        let anchor = NSEvent.mouseLocation

        let size = pill.intrinsicContentSize
        window.setContentSize(size)

        // 默认落在光标右下方；贴边时翻到另一侧，避免被屏幕边缘切掉。
        var origin = NSPoint(x: anchor.x + 12, y: anchor.y - size.height - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX { origin.x = anchor.x - size.width - 12 }
            if origin.y < visible.minY { origin.y = anchor.y + 12 }
            if origin.x < visible.minX { origin.x = visible.minX + 8 }
        }
        window.setFrameOrigin(origin)

        shownAt = Date()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            window.animator().alphaValue = 1
        }
        // 打出来便于区分「按钮根本没出现」和「出现了又被收起」——
        // 这两种症状在界面上都表现为「没看见按钮」，但原因完全不同。
        Diag.note("显示悬浮按钮：位置 \(Int(origin.x)),\(Int(origin.y)) 尺寸 \(Int(size.width))×\(Int(size.height))")
    }

    /// 补上出处链接。
    ///
    /// 取 URL 走 AppleScript，慢且可能弹授权框，所以放在按钮出现之后再补——
    /// 用户点「收录」时通常已经就位。用正文做匹配，避免把上一段选区的 URL
    /// 贴到新卡片上（两次选择挨得很近时可能发生）。
    func attachSourceURL(_ url: String, forText text: String) {
        guard var current = pending, current.text == text else { return }
        current.sourceURL = url
        pending = current
    }

    func dismiss(reason: String) {
        dismissTimer?.invalidate(); dismissTimer = nil
        undoWindow?.invalidate(); undoWindow = nil
        guard window.alphaValue > 0.01 else { return }
        // 收起原因打日志：这类「闪一下就没了」的问题事后只能靠日志定位。
        Diag.note("收起悬浮按钮：\(reason)")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.pill.style = .idle
            self?.capturedSnippetID = nil
            self?.pending = nil
            self?.shownAt = nil
        })
    }

    // MARK: - 点击

    private func handleClick() {
        // 撤销优先，且不依赖 pending——快捷键路径下 pending 是空的。
        if let id = capturedSnippetID {
            onUndo?(id)
            capturedSnippetID = nil
            dismiss(reason: "已点击撤销")
            return
        }

        guard let onCapture, let pending else { return }
        let outcome = onCapture(pending)

        switch outcome {
        case .inserted(let snippet):
            capturedSnippetID = snippet.id
            pill.style = .done
            // 换尺寸后需要重新摆位，否则胶囊会从右边缘溢出。
            let size = pill.intrinsicContentSize
            let frame = window.frame
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.maxY - size.height))
            scheduleUndoWindow()
        case .duplicate:
            pill.style = .duplicate
            scheduleAutoDismiss()
        case .failed:
            dismiss(reason: "落库失败")
        }
    }

    private func scheduleUndoWindow() {
        dismissTimer?.invalidate()
        undoWindow?.invalidate()
        undoWindow = Timer.scheduledTimer(withTimeInterval: undoWindowLength, repeats: false) { [weak self] _ in
            self?.dismiss(reason: "撤销窗口结束")
        }
    }

    private func scheduleAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismissDelay, repeats: false) { [weak self] _ in
            self?.dismiss(reason: "静置超时")
        }
    }

    // MARK: - 外部事件（由 SelectionTrigger 转发）

    func handleScroll(deltaY: CGFloat) {
        guard isVisible else { return }
        accumulatedScroll += deltaY
        if abs(accumulatedScroll) > scrollDismissThreshold {
            dismiss(reason: "滚动 \(Int(accumulatedScroll))pt")
        }
    }

    func handleMouseMoved(to point: NSPoint) {
        guard isVisible else { return }
        // 刚复制过就不因鼠标移开而收起，否则「⌘C 后想看按钮」会扑空。
        if let last = lastCmdCAt, Date().timeIntervalSince(last) < 1.5 { return }
        // 刚出现的一小段时间里，手还带着拖拽之后的余动，这不算「走开」。
        if let shownAt, Date().timeIntervalSince(shownAt) < mouseMoveGrace { return }
        let expanded = window.frame.insetBy(dx: -hoverPadding, dy: -hoverPadding)
        if !expanded.contains(point) {
            let dx = Int(point.x - window.frame.midX), dy = Int(point.y - window.frame.midY)
            dismiss(reason: "鼠标移开（离按钮中心 \(dx),\(dy)pt，容差 \(Int(hoverPadding))pt）")
        }
    }
}
