import AppKit
import Carbon

/// 快捷键录制控件：点一下进入录制态，按下组合键即记下。
///
/// 自绘而不是用 `NSTextField`：这里要的是「点一下 → 变成『按下组合键…』→
/// 按完还原」这个状态机，用输入框做反而要一路绕开它的编辑行为
/// （光标、选区、输入法、粘贴……）。
final class ShortcutRecorderView: NSView {

    /// 当前组合。nil = 未设置。
    var spec: HotKeySpec? { didSet { needsDisplay = true } }

    /// 用户改动了就回调。传 nil 表示清空。
    var onChange: ((HotKeySpec?) -> Void)?

    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 26) }

    override func mouseDown(with event: NSEvent) {
        guard !recording else { return }
        recording = true
        // 录制期间把已注册的全局快捷键全部摘掉：否则用户按到「当前正占用」的
        // 组合时，Carbon 会在系统层把它吃掉，这里根本收不到 keyDown——
        // 表现是「想改快捷键，结果一按就触发了旧功能，还改不掉」。
        HotKeyCenter.shared.suspend()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }

        switch Int(event.keyCode) {
        case kVK_Escape:
            endRecording()                       // 取消录制，保留原值
            return
        case kVK_Delete, kVK_ForwardDelete:
            spec = nil
            endRecording()
            onChange?(nil)
            return
        default:
            break
        }

        guard let new = HotKeySpec.from(event: event) else {
            // 只按了 ⇧ 或没按修饰键。蜂鸣提示但不接受，也不退出录制态——
            // 用户多半是手滑，让他接着按。
            NSSound.beep()
            return
        }
        spec = new
        // **必须先 endRecording 再 onChange**，顺序反了会静默丢掉「注册失败」。
        //
        // 录制期间所有全局快捷键都是挂起状态，而 `HotKeyCenter.update` 在挂起时
        // 走的是「只存组合、不真注册」那条分支——于是用户设了个被别的应用占用的
        // 组合，我们根本不会去试，`lastFailure` 永远是 nil，设置窗口里那句
        // 「已被占用，当前设置未生效」也就永远不会出现。用户只会以为改成功了，
        // 然后困惑于「快捷键按了没反应」。
        //
        // 先 endRecording 会把注册恢复起来，`onChange` 里的注册尝试才是真的。
        endRecording()
        onChange?(new)
    }

    private func endRecording() {
        guard recording else { return }
        recording = false
        HotKeyCenter.shared.resume()
        needsDisplay = true
    }

    /// 外部强制收尾（比如窗口被关掉）。
    ///
    /// 必须有这条：`recording` 是控件的状态，窗口关掉时它不会自己复位。
    /// 不复位的话，下次打开窗口点这个框会被 `mouseDown` 里的 `guard !recording`
    /// 直接挡掉——录制器整个变砖，而且看不出任何原因（框还是那个框）。
    func cancelRecording() { endRecording() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                   : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = recording ? "按下组合键…" : (spec?.display ?? "未设置")
        let color: NSColor = recording
            ? .controlAccentColor
            : (spec == nil ? .tertiaryLabelColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: recording ? .medium : .regular),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                           y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}

/// 快捷键设置窗口。
///
/// 目前只有两个快捷键，所以用一个手搭的小窗口就够了；
/// 接更多偏好设置时再换成 tab 视图。
final class SettingsWindowController: NSObject, NSWindowDelegate {

    /// 快捷键改动后通知外面重新注册。
    var onHotKeysChanged: (() -> Void)?

    private var window: NSWindow?
    private let openRecorder = ShortcutRecorderView()
    private let captureRecorder = ShortcutRecorderView()
    private let warning = NSTextField(labelWithString: "")

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        openRecorder.spec = Settings.openPanelHotKey
        captureRecorder.spec = Settings.captureHotKey
        refreshWarning()
        // 应用是 accessory（无 Dock 图标），不 activate 的话窗口会开在别的应用后面，
        // 用户会以为「点了没反应」。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 把「注册不上」这件事显式说出来。
    private func refreshWarning() {
        let failures = HotKeyCenter.shared.activeFailures
        warning.stringValue = failures.isEmpty
            ? ""
            : "⚠︎ " + failures.joined(separator: "；") + "，当前设置未生效，请换一个组合。"
        warning.textColor = .systemOrange
    }

    // MARK: - 组装

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 286),
                         styleMask: [.titled, .closable],
                         backing: .buffered,
                         defer: false)
        w.title = "拾句 · 快捷键"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        openRecorder.onChange = { [weak self] spec in
            Settings.openPanelHotKey = spec
            self?.onHotKeysChanged?()
            self?.refreshWarning()
        }
        captureRecorder.onChange = { [weak self] spec in
            Settings.captureHotKey = spec
            self?.onHotKeysChanged?()
            self?.refreshWarning()
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(row(title: "打开面板", recorder: openRecorder))
        stack.addArrangedSubview(row(title: "收录选中文字", recorder: captureRecorder))

        warning.font = .systemFont(ofSize: 11.5)
        warning.textColor = .systemOrange
        warning.preferredMaxLayoutWidth = 352
        stack.addArrangedSubview(warning)

        let hint = NSTextField(wrappingLabelWithString: """
        点一下方框，再按下你想要的组合键。至少需要一个 ⌘ / ⌥ / ⌃——\
        只按一个字母会把那个键从所有应用手里抢走，连打字都会受影响。
        Delete 清空，Esc 取消录制。组合若已被系统或其他应用占用，会保留原设置并提示。
        """)
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 352
        stack.addArrangedSubview(hint)

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])
        w.contentView = content
        return w
    }

    private func row(title: String, recorder: ShortcutRecorderView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, spacer, recorder])
        row.orientation = .horizontal
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: 352).isActive = true
        return row
    }

    @objc private func resetDefaults() {
        Settings.openPanelHotKey = Settings.defaultOpenPanel
        Settings.captureHotKey = Settings.defaultCapture
        openRecorder.spec = Settings.openPanelHotKey
        captureRecorder.spec = Settings.captureHotKey
        onHotKeysChanged?()
        refreshWarning()
    }

    func windowWillClose(_ notification: Notification) {
        // 万一关窗口时还在录制态（比如用 ⌘W 关的），必须收尾两件事：
        // 一是把全局快捷键装回去（不然一直挂着，快捷键全失效），
        // 二是把录制态复位（不然下次打开窗口录制器点不动）。
        openRecorder.cancelRecording()
        captureRecorder.cancelRecording()
        HotKeyCenter.shared.resume()
    }
}
