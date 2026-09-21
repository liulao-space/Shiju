import AppKit
import Carbon
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let trigger = SelectionTrigger()
    private let reader = SelectionReader()
    private let popButton = PopButtonController()
    private let panel = PanelWindowController()
    private let clipboard = ClipboardWatcher()
    private let settings = SettingsWindowController()

    /// 两个全局快捷键的登记 id。存 id 而不是 `HotKeySpec`：
    /// 改快捷键时按 id 就地更新，不用先注销再注册（中间那一刻会漏按键）。
    private var openPanelHotKeyID: UInt32?
    private var captureHotKeyID: UInt32?

    private var isPaused = false
    /// 取词是异步的，加锁避免连续拖拽时并发读造成闪烁。
    private var isReading = false
    /// 用来发现「运行中权限被授予」——补上之后全局监听要重新注册才生效。
    private var lastPermissionState = false
    private var permissionTimer: Timer?

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 清空上一轮日志。混着看会把「这次没触发」误判成「这次触发了」。
        Diag.rotate()

        Store.shared.open()
        Store.shared.purgeExpired()

        setupStatusItem()
        setupHotKeys()
        wirePopButton()
        wireTrigger()
        wireClipboard()
        wireSettings()

        // 权限状态一定要落日志：没有它，「选中文字没反应」这件事
        // 从外部完全看不出是权限问题还是代码问题。
        let granted = Permissions.isAccessibilityGranted
        Diag.note("启动：辅助功能权限\(granted ? "已授予" : "未授予")，可执行文件 \(Bundle.main.bundlePath)")
        lastPermissionState = granted

        if !granted {
            // 没有权限时取词和全局监听都不工作。这里只调系统的授权引导
            // （它会把应用登记进「辅助功能」列表），**不弹自己的模态框**：
            // 模态会阻塞主线程，菜单栏图标点不动、权限轮询也停摆，
            // 反而把「勾上就自动生效」这条路堵死。
            // 需要详细说明时，用户点菜单栏的「拾!」即可（见 statusItemClicked）。
            Permissions.requestAccessibility()
        }
        startPermissionWatch()
    }

    /// 盯着权限变化。
    ///
    /// 用户在「系统设置」里勾上之后，**全局监听不会自己开始收到事件**——
    /// 必须重新注册一遍，否则用户得重启应用，很容易被当成「授权了也没用」。
    private func startPermissionWatch() {
        updateStatusItemAppearance()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Permissions.isAccessibilityGranted
            guard now != self.lastPermissionState else { return }
            self.lastPermissionState = now
            Diag.note("辅助功能权限变为\(now ? "已授予" : "已撤销")")
            if now {
                self.trigger.stop()
                self.trigger.start()
                Diag.note("已重新注册全局监听")
            }
            self.updateStatusItemAppearance()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // 关掉面板不等于退出应用
    }

    /// 再次「打开」应用（聚焦里按回车、`open -a 拾句`）时把面板叫出来。
    ///
    /// 不实现这个的话，应用已经在跑的时候 `open` 只会把它激活，
    /// 而它没有 Dock 图标也没有窗口，用户看到的就是「点了没反应」。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panel.show() }
        return true
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 汉字单字图标在小尺寸下的辨识度远高于抽象图形。
            button.title = "拾"
            button.font = .systemFont(ofSize: 15, weight: .medium)
            button.toolTip = "拾句 · 选中文字即可收录"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// 菜单栏图标兼作状态灯。
    ///
    /// 加感叹号是为了让「缺权限」这件事**一眼可见**——否则用户只会看到
    /// 「选中文字没反应」，然后去猜是哪里坏了。
    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        if isPaused {
            button.title = "拾̶"
            button.toolTip = "拾句 · 已暂停捕获"
        } else if !Permissions.isAccessibilityGranted {
            button.title = "拾!"
            button.toolTip = "拾句 · 缺少「辅助功能」权限，悬浮按钮不会出现。点一下去授权。"
        } else {
            button.title = "拾"
            button.toolTip = "拾句 · 选中文字即可收录"
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else if !Permissions.isAccessibilityGranted {
            // 缺权限时左键直接去授权——此时打开面板没多大意义
            showPermissionAlert()
        } else {
            panel.show()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // 把当前快捷键写在菜单项里。用户改了快捷键之后没法从别处看到它，
        // 忘了就得开设置窗口翻——顺手写在这里成本几乎为零。
        let openTitle = Settings.openPanelHotKey.map { "打开面板（\($0.display)）" } ?? "打开面板"
        let open = NSMenuItem(title: openTitle, action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settingsItem = NSMenuItem(title: "快捷键设置…",
                                      action: #selector(openSettings),
                                      keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let pauseTitle = isPaused ? "恢复捕获" : "暂停捕获"
        let pause = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        let stats = Store.shared.stats()
        let statsItem = NSMenuItem(title: "已收录 \(stats.total) 句 · 星标 \(stats.starred)",
                                   action: nil, keyEquivalent: "")
        statsItem.isEnabled = false
        menu.addItem(statsItem)

        menu.addItem(.separator())

        let permTitle = Permissions.isAccessibilityGranted ? "辅助功能权限已授权" : "去授权辅助功能…"
        let perm = NSMenuItem(title: permTitle, action: #selector(openPermissions), keyEquivalent: "")
        perm.target = self
        perm.isEnabled = !Permissions.isAccessibilityGranted
        menu.addItem(perm)

        let reveal = NSMenuItem(title: "打开数据库位置", action: #selector(revealDatabase), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出拾句", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 用完即撤，否则左键点击也会走菜单
    }

    @objc private func openPanel() { panel.show() }

    @objc private func openSettings() { settings.show() }

    @objc private func togglePause() {
        isPaused.toggle()
        // 必须走统一的刷新入口：直接写 title 会把「拾!」（缺权限）覆盖掉，
        // 用户就看不出「暂停」和「没权限」的区别了。
        updateStatusItemAppearance()
    }

    @objc private func openPermissions() { showPermissionAlert() }

    @objc private func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.databaseURL])
    }

    /// 只在用户主动问的时候弹（点菜单栏「拾!」或右键菜单里的「去授权辅助功能…」）。
    ///
    /// 刻意**不**在启动时弹：`runModal()` 会阻塞主线程，菜单栏图标点不动、
    /// 权限轮询也停摆——而「勾上就自动生效」恰恰依赖那个轮询。
    private func showPermissionAlert() {
        guard !Permissions.isAccessibilityGranted else { return }
        let alert = NSAlert()
        alert.messageText = "拾句需要「辅助功能」权限"
        alert.informativeText = """
        读取选中文字必须通过系统的辅助功能接口，这是 macOS 的强制要求，无法绕过。

        请到「系统设置 → 隐私与安全性 → 辅助功能」中勾选拾句。勾选后会自动生效，不需要重启。

        如果列表里已经有拾句、并且是勾上的，但它仍然不工作：说明那一条是旧版本的残留记录（重新编译会让签名变化，旧授权会失效）。请用列表下方的「−」把它删掉，再重新添加一次。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    // MARK: - 快捷键

    private func setupHotKeys() {
        applyHotKeys()
        settings.onHotKeysChanged = { [weak self] in self?.applyHotKeys() }
    }

    /// 按当前偏好（重新）注册两个快捷键。
    ///
    /// 「打开面板」刻意**不检查辅助功能权限**——面板本身只是读数据库，
    /// 不需要任何授权。这一点很重要：权限出问题时，用户至少还能靠它把库打开看看。
    private func applyHotKeys() {
        openPanelHotKeyID = apply(Settings.openPanelHotKey,
                                  currentID: openPanelHotKeyID,
                                  label: "打开面板") { [weak self] in self?.panel.show() }

        captureHotKeyID = apply(Settings.captureHotKey,
                                currentID: captureHotKeyID,
                                label: "收录选中文字") { [weak self] in self?.captureViaHotKey() }
    }

    /// 注册 / 更新 / 注销一个快捷键，返回它当前的登记 id（nil = 未设置）。
    ///
    /// 用 `update(id:spec:)` 而不是「先注销再注册」：后者中间那一刻按键会漏掉，
    /// 而且注册失败时旧的就真没了。
    ///
    /// 注册失败**不在这里上报**：原因挂在登记项上，由设置窗口读
    /// `HotKeyCenter.activeFailures` 显示。这里只留一条诊断日志。
    private func apply(_ spec: HotKeySpec?,
                       currentID: UInt32?,
                       label: String,
                       handler: @escaping () -> Void) -> UInt32? {
        guard let spec else {
            if let currentID { HotKeyCenter.shared.unregister(id: currentID) }
            Diag.note("快捷键「\(label)」未设置")
            return nil
        }
        if let currentID {
            if HotKeyCenter.shared.update(id: currentID, spec: spec) { return currentID }
            Diag.note("快捷键「\(label)」改为 \(spec.display) 失败，已保留原设置")
            return currentID
        }
        let id = HotKeyCenter.shared.register(spec, handler: handler)
        Diag.note("快捷键「\(label)」= \(spec.display)")
        return id
    }

    private func captureViaHotKey() {
        guard !isPaused, Permissions.isAccessibilityGranted else { return }
        Task { @MainActor in
            let t0 = Date()
            guard let captured = await readSelection() else { return }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Diag.note("快捷键取词耗时 \(ms)ms")
            let outcome = insert(captured)
            popButton.showResult(outcome)
            if case .inserted(let snippet) = outcome {
                if panel.isOpen { panel.pushCaptured(snippet) }
                backfillURL(snippetID: snippet.id, bundleID: captured.sourceBundleID)
            }
        }
    }

    /// 取词期间把剪贴板监听停掉。
    ///
    /// `SelectedTextKit` 走 ⌘C 通道时是「备份剪贴板 → 模拟 ⌘C → 读 → 还原」，
    /// 剪贴板会绕一圈。不暂停的话，**每次取词都会顺手多弹一次按钮**，
    /// 而且弹出来的可能是用户上一次复制的内容。
    /// 结束后 `resume()` 会把现状重新记为基线，整段往返就此消化掉。
    private func readSelection() async -> PendingCapture? {
        clipboard.pause()
        defer { clipboard.resume() }
        return await reader.read()
    }

    // MARK: - 剪贴板触发

    /// 「复制」也是一次收录意图，但它**不产生任何拖拽事件**——
    /// 早先只认拖拽和双击，于是 ⌘C 和右键「复制」完全漏掉，
    /// 用户看到的就是「我明明复制了，按钮没出来」。
    ///
    /// 这条路径还有第二个好处：它不依赖 AX 取词，所以在微信这类
    /// 自绘界面、取词拿不到文本的应用里也能工作。
    private func wireClipboard() {
        clipboard.pendingText = { [weak self] in self?.popButton.pendingTextValue }
        clipboard.onCopy = { [weak self] text in
            guard let self, !self.isPaused else { return }
            // 刚复制过 → 按钮不该因为鼠标移开就立刻收起（否则「复制完想看按钮」会扑空）
            self.popButton.noteCopyDetected()
            let captured = self.reader.pendingFromClipboard(text: text)
            self.popButton.show(captured)
            self.enrichPendingURL(captured)
        }
        clipboard.start()
    }

    private func wireSettings() {
        panel.onOwnClipboardWrite = { [weak self] in
            self?.clipboard.claimOwnWrite()
        }
        // 面板顶栏的齿轮。快捷键设置的主入口——右键菜单栏图标那条路
        // 藏得太深（用户反馈「没看到设置入口」），面板才是天天看得见的地方。
        panel.onOpenSettings = { [weak self] in self?.settings.show() }
    }

    // MARK: - 拖拽触发

    private func wireTrigger() {
        trigger.onSelectionEnd = { [weak self] in
            self?.handleSelectionEnd()
        }
        trigger.onScroll = { [weak self] delta in
            self?.popButton.handleScroll(deltaY: delta)
        }
        trigger.onMouseMoved = { [weak self] point in
            self?.popButton.handleMouseMoved(to: point)
        }
        trigger.start()
    }

    private func handleSelectionEnd() {
        // 三个早退分支都要留痕。鼠标类全局监听【不需要】辅助功能权限，
        // 所以权限没授予时这里照样会被调用——不打日志的话，
        // 日志里就只有「检测到拖拽选择结束」，后面空空如也，
        // 看上去像取词卡死了，实际是权限没给。
        guard !isPaused else { return }
        guard !isReading else {
            Diag.note("忽略本次选择：上一次取词还没结束")
            return
        }
        guard Permissions.isAccessibilityGranted else {
            Diag.note("放弃取词：辅助功能权限未授予（菜单栏图标应为「拾!」，点它去授权）")
            return
        }
        isReading = true
        Task { @MainActor in
            defer { isReading = false }
            let t0 = Date()
            guard let captured = await readSelection() else { return }
            // 这段耗时直接决定「松手到按钮出现」的手感，也是过去按钮出现在
            // 光标之外的根因（位置曾是松手那一刻的快照）。留个日志便于复查。
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            Diag.note("取词耗时 \(ms)ms，\(captured.text.count) 字")
            popButton.show(captured)
            // 按钮已经出来了，出处链接再慢慢补——绝不让它挡在前面。
            enrichPendingURL(captured)
        }
    }

    // MARK: - 出处链接

    /// 按钮弹出之后，在后台把「出处链接」补到待收录内容上。
    ///
    /// 取 URL 要跑 AppleScript：慢，且第一次访问某个浏览器时系统会弹
    /// 「自动化」授权框，用户不点它就一直等（系统默认超时 60s）。
    /// 挂到关键路径上的话，表现就是「选中文字后毫无反应」——这条 bug 踩过一次了。
    /// 所以给它 1.2s 上限，超时直接放弃：出处链接只是卡片上的装饰，
    /// 不值得让按钮陪着一起等。
    private func enrichPendingURL(_ captured: PendingCapture) {
        guard captured.sourceBundleID != nil else { return }
        Task { @MainActor in
            let t0 = Date()
            guard let url = await SelectionReader.browserURL(for: captured.sourceBundleID,
                                                             timeout: 1.2) else { return }
            Diag.note("补上出处链接 \(url)（耗时 \(Int(Date().timeIntervalSince(t0) * 1000))ms）")
            popButton.attachSourceURL(url, forText: captured.text)
        }
    }

    /// 快捷键路径没有「等用户点一下」的窗口——内容一取到就落库了，
    /// 所以链接只能事后回填到数据库里。
    ///
    /// 刻意**不**顺手刷新面板：面板每次打开都会从库里重灌，
    /// 链接自然会出现；而此刻刷新会把用户刚看到的那张新卡片整屏重建，得不偿失。
    private func backfillURL(snippetID: String, bundleID: String?) {
        guard bundleID != nil else { return }
        Task {
            guard let url = await SelectionReader.browserURL(for: bundleID, timeout: 3.0) else { return }
            Store.shared.setSourceURL(id: snippetID, url: url)
            Diag.note("已回填出处链接 \(url)")
        }
    }

    // MARK: - 落库

    private func insert(_ captured: PendingCapture) -> CaptureOutcome {
        let snippet = Store.shared.insert(text: captured.text,
                                          sourceApp: captured.appName,
                                          sourceTitle: captured.sourceTitle,
                                          sourceURL: captured.sourceURL)
        guard let snippet else { return .duplicate }
        return .inserted(snippet)
    }

    private func wirePopButton() {
        popButton.onCapture = { [weak self] captured in
            guard let self else { return .failed }
            let outcome = self.insert(captured)
            if case .inserted(let snippet) = outcome, self.panel.isOpen {
                self.panel.pushCaptured(snippet)
            }
            return outcome
        }
        popButton.onUndo = { id in
            Store.shared.softDelete(id: id)
        }
    }
}
