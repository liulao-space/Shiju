import AppKit
import Carbon
import Foundation
import SelectedTextKit

/// 取词：在任意应用拿到当前选中的文本。
///
/// 三层保护，顺序不能颠倒：
/// 1. 安全输入（密码框）→ 直接放弃，既不读也不模拟按键
/// 2. 敏感应用忽略名单 → 直接放弃
/// 3. 交给 SelectedTextKit 按策略降级取词
final class SelectionReader {

    /// 默认不捕获的应用。用户可在设置里增删（当前为硬编码，后续接偏好存储）。
    ///
    /// 做成 `static` 是因为剪贴板那条触发路径也要用同一份名单——
    /// 两边各存一份的话，迟早会出现「取词被挡住、但复制到剪贴板照样弹按钮」这种不一致。
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "in.sinew.Enpass-Desktop",
        "com.apple.Passwords",
        // 拾句自己。
        //
        // 少了这一条，在面板里**拖窗口**（面板是特意做成可拖的）会被当成一次
        // 2744pt 的划选，在卡片里选中文字想复制也一样——于是每次都白跑一趟
        // AX 取词，日志里刷满「检测到拖拽选择结束 / 放弃取词」，
        // 而且真选中卡片文字时还会在自己面板上弹出自己的按钮。
        // 实测日志里这种噪声占了大半，排查真问题时非常碍事。
        "com.liulao.shiju",
    ]

    /// 敏感域名/标题关键词，命中则不弹按钮。
    private let ignoredTitleKeywords = ["银行", "支付", "转账", "信用卡", "登录密码"]

    static func isIgnoredApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredBundleIDs.contains(bundleID)
    }

    /// 读取当前选中文本。返回 nil 表示没有可用选区（或已被保护规则拦下）。
    ///
    /// 这里**刻意不查浏览器 URL**。查 URL 走 AppleScript，可能因为「自动化」授权
    /// 弹窗没人点、或目标应用正在弹模态框而阻塞几十秒（系统默认超时 60s）。
    /// 挂在关键路径上的话，按钮就永远不出现——表现是「选中文字后毫无反应」。
    /// URL 只是卡片的出处链接，不是收录内容本身，所以交给调用方在按钮弹出之后再补
    /// （见 `browserURL(for:timeout:)`）。
    func read() async -> PendingCapture? {
        // 保护 1：安全输入。密码框聚焦时系统会开启 secure input，
        // 此时任何读取与模拟按键都必须停止。
        if IsSecureEventInputEnabled() {
            Diag.note("放弃取词：系统处于安全输入状态（密码框）")
            return nil
        }

        let front = NSWorkspace.shared.frontmostApplication
        let bundleID = front?.bundleIdentifier
        let appName = front?.localizedName

        // 保护 2：忽略名单
        if Self.isIgnoredApp(bundleID: bundleID) {
            Diag.note("放弃取词：\(bundleID ?? "") 在忽略名单里")
            return nil
        }

        let title = Self.frontWindowTitle()
        if let title, ignoredTitleKeywords.contains(where: { title.contains($0) }) {
            Diag.note("放弃取词：窗口标题命中敏感词（\(title)）")
            return nil
        }

        // 保护 3：取词。SelectedTextKit 自带剪贴板备份还原与提示音静音，
        // 因此走 ⌘C 通道也不会污染用户剪贴板。
        //
        // 这里必须用**数组版** `strategies:`，不能用 `.auto`：
        // `.auto` 的实现是「先 AX，拿不到再试菜单复制」，但它把 AX 那一步写成
        // `let text = try await getSelectedTextByAX()`——**AX 一抛错就整体放弃**，
        // 后面的菜单/⌘C 兜底压根不会执行。实测在 Chrome 里 AX 会抛
        // `AXError -25212`（noValue），于是「选中了文字但按钮不出现」。
        // 数组版是逐个 try/catch 后 continue，才是真的兜底。
        do {
            guard let text = try await SelectedTextManager.shared.getSelectedText(
                strategies: [.accessibility, .menuAction, .shortcut]
            ) else {
                Diag.note("放弃取词：三条通道都没拿到文本（\(bundleID ?? "未知应用")）")
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                Diag.note("放弃取词：取到的内容去掉空白后为空")
                return nil
            }
            return PendingCapture(text: trimmed,
                                  appName: appName,
                                  sourceBundleID: bundleID,
                                  sourceTitle: title,
                                  sourceURL: nil)      // URL 稍后补，见上
        } catch {
            Diag.note("取词失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 剪贴板路径：内容已经在剪贴板里了，不需要再去读选区。
    ///
    /// 这条路径**完全不依赖 AX 取词**，所以在微信这类自绘界面、
    /// 取词拿不到文本的应用里也能工作——用户按下 ⌘C 或右键「复制」之后，
    /// 文本已经在剪贴板上，直接拿来用即可。
    func pendingFromClipboard(text: String) -> PendingCapture {
        let front = NSWorkspace.shared.frontmostApplication
        return PendingCapture(text: text,
                              appName: front?.localizedName,
                              sourceBundleID: front?.bundleIdentifier,
                              sourceTitle: Self.frontWindowTitle(),
                              sourceURL: nil)
    }

    /// 前台应用最前面那个窗口的标题。拿不到就返回 nil，不阻塞流程。
    private static func frontWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // 必须给 AX 调用一个上限。目标应用卡住时系统默认会等好几秒，
        // 而这个调用在剪贴板触发路径上是跑在**主线程**的（由定时器直接调用），
        // 等下去会把整个界面冻住。
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXTitleAttribute as CFString, &title) == .success else { return nil }
        let value = title as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 浏览器当前标签页 URL。仅覆盖常见浏览器，失败即返回 nil（面板会优雅降级）。
    ///
    /// 慢且不可控：AppleScript 要先过「自动化」授权，目标应用忙时还会一直等
    /// （系统默认超时 60s）。所以**不要**放进「松手到按钮出现」的关键路径，
    /// 并且用 `timeout` 给它一个等待上限——超时就放弃 URL。
    /// 它只是卡片的出处链接，不值得让用户干等。
    static func browserURL(for bundleID: String?, timeout: TimeInterval) async -> String? {
        guard let script = appleScript(for: bundleID) else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await run(script) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            // 注意：AppleScript 是阻塞调用，取消不掉，这里只是「不再等它」。
            // 它会自己跑完然后被丢弃——换来的是按钮不必陪着一起等。
            group.cancelAll()
            return first
        }
    }

    private static func appleScript(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        switch bundleID {
        case "com.apple.Safari":
            return "tell application \"Safari\" to return URL of front document"
        case "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac":
            let name = bundleID == "com.microsoft.edgemac" ? "Microsoft Edge" : "Google Chrome"
            return "tell application \"\(name)\" to return URL of active tab of front window"
        case "company.thebrowser.Browser":   // Arc
            return "tell application \"Arc\" to return URL of active tab of front window"
        default:
            return nil
        }
    }

    /// NSAppleScript 不是线程安全的，但「在同一个线程里创建并使用」是安全的。
    /// 这里整体丢到后台队列：既不阻塞主线程，也满足上面这条约束。
    private static func run(_ script: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error { Diag.note("取浏览器 URL 失败：\(error)") }
                cont.resume(returning: result?.stringValue)
            }
        }
    }
}

/// 触发：什么时候该弹按钮。
///
/// 不用轮询。macOS 没有「用户选中了文字」的系统通知，但选择这个**动作**本身
/// 是可观测的，有两条路径：
/// - 拖拽划过一段 → 从按下到松手累计位移够大
/// - 双击/三击选词选行 → **不产生任何拖拽事件**，只能看 `clickCount`
///
/// 两条都要，否则「双击选一个词」这种最常用的操作反而不弹按钮。
///
/// 判据一律用「位移距离」而不是「事件个数」：快速一划时系统会合并鼠标事件，
/// 可能只收到 1 个 `leftMouseDragged`，按个数判会直接漏掉。
/// 而**位移的起点必须取 `leftMouseDown` 的位置**——只靠拖拽事件之间的差值，
/// 在「只收到 1 个事件」时压根没有参照点，算出来是 0，等于没修。
///
/// 误触不用担心：窗口标题栏双击、双击文件图标这些也会触发，
/// 但取词那一步拿不到文本，按钮自然不弹。
final class SelectionTrigger {

    /// 不带坐标。按钮的位置由 PopButtonController 在「出现的那一刻」现取鼠标坐标，
    /// 因为这里给出的坐标要等异步取词跑完才被用上，届时早就过期了。
    var onSelectionEnd: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?

    private var monitors: [Any] = []
    private var drag = DragTracker()

    /// 累计位移超过这个值才算「划过一段」。
    ///
    /// 4pt 是刻意选的：手抖的单击通常只挪 1–2pt，划选一个字至少十几个点，
    /// 中间有足够宽的区分带，不会因为阈值贴边而在两种行为之间跳。
    private let minDragDistance: CGFloat = 4

    func start() {
        stop()

        // 全局监听不会收到本应用自身的事件，所以点击悬浮按钮不会再次触发。
        //
        // 另外注意：**鼠标类事件不需要辅助功能权限**，键盘类才需要。
        // 所以「权限没授予」时这里照样能收到事件、照样会打日志——
        // 日志里能看到拖拽判定，却永远看不到按钮，这个组合本身就是
        // 「权限问题」的强信号。
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            self?.drag.begin(at: NSEvent.mouseLocation)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
            self?.drag.extend(to: NSEvent.mouseLocation)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] event in
            guard let self else { return }
            let (hadStart, distance) = self.drag.finish(at: NSEvent.mouseLocation)

            // 双击 / 三击选词选行：没有拖拽，但同样是一次选择。
            if event.clickCount >= 2 {
                Diag.note("检测到 \(event.clickCount) 连击选词")
                self.onSelectionEnd?()
                return
            }

            guard hadStart else { return }   // 没看到按下（应用刚启动），无从判断，略过
            guard DragTracker.isSelection(hadStart: hadStart,
                                          distance: distance,
                                          threshold: self.minDragDistance) else { return }   // 普通单击，静默略过，否则每次点击都刷屏
            Diag.note("检测到拖拽选择结束（位移 \(Int(distance))pt）")
            self.onSelectionEnd?()
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { [weak self] event in
            self?.onScroll?(event.scrollingDeltaY)
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.onMouseMoved?(NSEvent.mouseLocation)
        }) { monitors.append(m) }

        // 监听注册不上时 `addGlobalMonitorForEvents` 只是返回 nil，不抛错也不报错。
        // 数量不对就说明系统层面没放行，比「选中文字没反应」这句话有用得多。
        Diag.note("全局监听已注册 \(monitors.count)/5 个")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

/// 权限：辅助功能。没有它，取词与全局监听都不会工作。
enum Permissions {

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 弹系统引导框，把用户送到「隐私与安全性 → 辅助功能」。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
