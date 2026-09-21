import AppKit
import Foundation
import WebKit

/// 标题栏那一条的拖动区。
///
/// 为什么要一个原生视图：面板是 `fullSizeContentView`，内容铺满整个窗口，
/// 标题栏（连同红绿灯）**浮在内容之上**。HTML 那边给顶部留了
/// `--titlebar-h` 的空白，但那块空白本身不吃鼠标事件，拖不动窗口。
/// 这里用一层透明视图把那条接过来，调 `performDrag` 让窗口跟着鼠标走——
/// 这是 macOS 上移动窗口的标准做法。
///
/// 它只盖住标题栏那一条（下面就是纯背景，没有控件），所以不会挡到任何按钮。
/// 红绿灯在标题栏视图里，层级比内容视图高，照样能点。
final class TitlebarDragView: NSView {

    /// 不画任何东西，纯接手鼠标。
    override func draw(_ dirtyRect: NSRect) {}

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 卡片面板：一个原生窗口，里面是 WKWebView 承载的 HTML 界面。
///
/// 选 HTML 而不是 SwiftUI 的理由：卡片流、搜索、标签筛选、亮暗色这些
/// 用 HTML/CSS 写比 SwiftUI 快得多，而且改样式不用重编译。
/// Swift 只负责「窗口 + 数据 + 事件」三件事。
///
/// 没有实现 `WKUIDelegate`：面板已经不用 `window.prompt` / `confirm` 了
/// （「＋ 记录」和删除确认都换成了自己的 `<dialog>`，见 panel.html）。
/// 哪天要在面板里用 `window.open` 或文件选择框，再把这个 delegate 接上。
final class PanelWindowController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// 面板自己往剪贴板写了东西（卡片上的「复制」）。
    /// 剪贴板监听靠它把这次变更认领掉，免得把悬浮按钮叫出来。
    var onOwnClipboardWrite: (() -> Void)?

    /// 用户点了顶栏的齿轮，要开快捷键设置。
    var onOpenSettings: (() -> Void)?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var dragStrip: TitlebarDragView?
    private var isReady = false
    private var pendingPayloads: [String] = []

    // MARK: - 打开

    func show() {
        if window == nil { buildWindow() }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func close() {
        window?.close()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    private func buildWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "action")
        // 面板要能读写本地文件（加载同目录资源），但不允许任意网络请求。
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // 让 HTML 自己的底色透出来
        if #available(macOS 13.3, *) {
            web.isInspectable = true                      // 便于开发期调试
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "拾句"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 520, height: 420)
        win.center()
        win.setFrameAutosaveName("ShijuPanel")

        // contentView 不能直接就是 webView：那样就没地方挂拖动条了。
        // 套一层容器，webView 铺满，拖动条浮在顶部那一条。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1020, height: 700))
        container.autoresizingMask = [.width, .height]

        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)

        let strip = TitlebarDragView(frame: .zero)
        // 坐标原点在左下角：minYMargin 弹性 = 下面那段可以伸缩 = 自己贴在顶部。
        strip.autoresizingMask = [.width, .minYMargin]
        container.addSubview(strip)

        win.contentView = container

        window = win
        webView = web
        dragStrip = strip
        layoutDragStrip()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification, object: win)

        loadPanel()
    }

    @objc private func windowDidResize() { layoutDragStrip() }

    /// 把拖动条对齐到标题栏那一条。
    private func layoutDragStrip() {
        guard let window, let container = window.contentView, let strip = dragStrip else { return }
        let h = Self.titlebarHeight(of: window)
        strip.frame = NSRect(x: 0,
                             y: container.bounds.height - h,
                             width: container.bounds.width,
                             height: h)
    }

    /// 标题栏的实际高度。
    ///
    /// 推导：`contentRect` 是「内容区」高度，`frame` 是含标题栏的总高，
    /// 两者相减就是标题栏。`fullSizeContentView` 下内容铺满整个窗口，
    /// `contentLayoutRect` 就等于完整内容区，所以这个减法依然成立。
    ///
    /// 为什么不硬编码 28：本机实测是 **32**（见诊断日志），
    /// 而且这个值会随系统版本、工具栏、无障碍设置变。量出来最稳。
    private static func titlebarHeight(of window: NSWindow) -> CGFloat {
        let byLayout = window.frame.height - window.contentLayoutRect.height
        if byLayout > 0 && byLayout < 100 { return byLayout }   // 100 是防呆上限
        let bySafeArea = window.contentView?.safeAreaInsets.top ?? 0
        return bySafeArea > 0 ? bySafeArea : 32
    }

    private func loadPanel() {
        guard let url = Self.panelHTMLURL() else {
            Diag.note("找不到 panel.html")
            return
        }
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// 打包后从 .app/Contents/Resources 读；开发期从可执行文件旁的 Resources 读。
    private static func panelHTMLURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "panel", withExtension: "html") {
            return bundled
        }
        // 开发期：.build/debug/Shiju → ../../Resources/panel.html
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            exe.deletingLastPathComponent().appendingPathComponent("Resources/panel.html"),
            exe.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/panel.html"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 数据下发

    /// 从数据库拉全量并推给界面。面板不持有真相，每次打开都重新灌。
    func refresh() {
        let rows = Store.shared.query(search: nil, filter: nil).map { $0.jsPayload() }
        guard let json = Self.jsonString(rows) else { return }
        evaluate("window.Shiju && window.Shiju.hydrate(\(json));")
    }

    /// 收录成功后把新卡片插到最前，走面板自带的入场动画与撤销。
    func pushCaptured(_ snippet: Snippet) {
        guard let json = Self.jsonString(snippet.jsPayload()) else { return }
        evaluate("window.Shiju && window.Shiju.capture(\(json));")
    }

    private func evaluate(_ script: String) {
        guard isReady, let webView else {
            pendingPayloads.append(script)   // 页面还没加载完，先排队
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error { Diag.note("JS 执行失败: \(error.localizedDescription)") }
        }
    }

    private static func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // 避免 JSON 里的 </script> 之类意外截断（虽然走 evaluateJavaScript 风险较低）。
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - 来自面板的消息

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "action",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let id = body["id"] as? String

        switch type {
        case "star":
            if let id { Store.shared.setStarred(id: id, starred: body["value"] as? Bool ?? false) }

        case "delete":
            if let id { Store.shared.softDelete(id: id) }

        case "undo":
            if let id { Store.shared.restore(id: id) }

        case "discard":
            // 面板「已收录 · 撤销」：撤销刚刚那条收录。走物理删除而非软删，
            // 否则同一句话会被去重逻辑永久挡住（详见 Store.discard）。
            if let id { Store.shared.discard(id: id) }

        case "edit":
            if let id, let text = body["text"] as? String {
                Store.shared.update(id: id, text: text, tags: body["tags"] as? [String] ?? [])
            }

        case "copy":
            if let text = body["text"] as? String {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                // 告诉剪贴板监听「这次是我们自己写的」。不认领的话，
                // 点卡片上的「复制」会顺手把悬浮收录按钮叫出来——明显是错的。
                onOwnClipboardWrite?()
            }

        case "capture":
            // 面板「＋ 记录」走这条：手动记一条。
            // 没有来源应用（source_app 为空 → Snippet.kind 判成「灵感」），
            // 但出处、链接、标签是用户自己填的，要一起落库。
            if let text = body["text"] as? String,
               let snippet = Store.shared.insert(text: text,
                                                 sourceApp: nil,
                                                 sourceTitle: (body["title"] as? String)?.nilIfBlank,
                                                 sourceURL: (body["url"] as? String)?.nilIfBlank,
                                                 tags: body["tags"] as? [String] ?? []) {
                pushCaptured(snippet)
            }

        case "setTheme":
            if let value = body["value"] as? String {
                UserDefaults.standard.set(value, forKey: "panelTheme")
            }

        case "settings":
            // 顶栏齿轮：打开快捷键设置。
            // 面板不自己持有设置窗口——那是 AppDelegate 的东西，
            // 这里只发一个意图出去，免得两个控制器互相引用。
            onOpenSettings?()

        case "startDrag":
            // 顶栏空白处按下 → 窗口跟着鼠标走。
            // 标题栏那一条由原生 TitlebarDragView 直接接管，不走这里。
            beginWindowDrag()

        default:
            break
        }
    }

    /// 让窗口跟着鼠标走。
    ///
    /// 关键：**不要用 `NSApp.currentEvent`**。JS 的消息是异步送到主线程的，
    /// 等它到达时当前事件可能已经变成 leftMouseDragged 甚至 nil，
    /// `performDrag` 就会拿到错的起点（表现为「一拖就跳」或者完全不动）。
    /// 这里按「此刻鼠标在哪」自己合成一个 mouseDown，起点必然正确。
    private func beginWindowDrag() {
        guard let window else { return }
        let local = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown,
                                             location: local,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: 1) else { return }
        window.performDrag(with: event)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        // 先告诉页面「顶部要留多高给红绿灯」，再灌数据——
        // 顺序反了会先按 CSS 里的兜底值（28px）排一次版，再跳一下。
        injectTitlebarInset()
        if let theme = UserDefaults.standard.string(forKey: "panelTheme") {
            evaluate("window.Shiju && window.Shiju.setTheme('\(theme)');")
        }
        pendingPayloads.forEach { evaluate($0) }
        pendingPayloads.removeAll()
        refresh()
    }

    /// 把标题栏高度交给 CSS。
    ///
    /// HTML 里 `--titlebar-h` 的兜底值是 28px（标准标题栏高度），
    /// 这里用真实值覆盖它。分开两处写是有意的：万一注入失败（比如页面还没加载完），
    /// 兜底值也能保证内容不被红绿灯压住——只是不够精确而已。
    private func injectTitlebarInset() {
        guard let window else { return }
        let h = Self.titlebarHeight(of: window)
        Diag.note("面板标题栏高度 \(Int(h))pt，已注入 --titlebar-h")
        evaluate("document.documentElement.style.setProperty('--titlebar-h', '\(Int(h))px');")
    }
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 面板里的链接（卡片出处）交给系统浏览器打开，不在面板内跳走。
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

}

private extension String {
    /// 去掉空白后为空就当没填。
    ///
    /// 面板的「出处 / 链接」都是选填，用户点开表单又没填时送过来的是空串。
    /// 空串会原样写进数据库，卡片元信息那里就会显示成一栏空白（而不是省略），
    /// 所以在这里统一归一成 nil。
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
