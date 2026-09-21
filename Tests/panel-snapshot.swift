// 面板视觉截图：把 Resources/panel.html 放进离屏 WKWebView 渲染成 PNG。
//
// 为什么需要它：panel-contract-test.cjs 跑在 jsdom 里，**读得到 computed style，
// 但读不到布局**——clientWidth 恒为 0，元素实际落在哪、有没有换行、有没有居中，
// 一概测不出来。第 5 轮那几条需求（列数跟随、标签不换行、空状态居中、弹层贴锚点）
// 全是纯布局问题，jsdom 只能验「CSS 规则写对了」，验不了「画出来是对的」。
//
// 而 screencapture 在本机没屏幕录制权限（`could not create image from display`），
// 所以走 WKWebView 自己的 takeSnapshot——它渲染的是 webview 的内容，
// 不经过屏幕，也就不需要那个权限。
//
// 用法见 Scripts/snapshot-panel.sh。单独跑：
//   swiftc -o shot Tests/panel-snapshot.swift   # 需先拷成 main.swift
//   ./shot --html Resources/panel.html --out /tmp/a.png --width 1200 --height 860

import AppKit
import ImageIO
import WebKit

// MARK: - 参数

struct Opts {
    var html = ""
    var out = "/tmp/panel.png"
    var width = 1200.0
    var height = 860.0
    var js = ""
    var wait = 0.45          // 给 CSS 过渡和 rAF 留时间，截到中间态就白搭
    var settle = 0.25        // didFinish 之后再等一会，等字体和主题变量落地
    var timeout = 20.0
    var live = false         // 保留动画（默认关：见下面 freezeJS 的说明）
    var probe = false        // 不截图，只把 JS 的返回值打到 stdout（用来量真实几何）
    // 拼图模式：把若干张已出好的图拼成一张（见下面「拼图」一段）
    var stitch = false
    var inputs: [String] = []
    var cols = 0             // 0 = 全排一行
    var gap = 14.0
}

/// 多段 JS 依次拼接（--js / --js-file 都可以给多次），
/// 这样「公共的样例数据」和「这一步要量的东西」可以分文件写。
func append(_ a: String, _ b: String) -> String {
    if a.isEmpty { return b }
    if b.isEmpty { return a }
    return a + ";\n" + b
}

func parseArgs() -> Opts {
    var o = Opts()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0

    /// 取下一个参数当值。无值开关（--live / --probe）不走这里——
    /// 早先的写法是「每个参数都强行取下一个当值」，结果放在最后的 `--probe`
    /// 取不到值就直接跳出循环，开关静默失效（截图模式下跑完还报成功）。
    func value(_ key: String) -> String? {
        guard i + 1 < args.count else {
            FileHandle.standardError.write("\(key) 后面缺值\n".data(using: .utf8)!)
            return nil
        }
        i += 1
        return args[i]
    }

    while i < args.count {
        let k = args[i]
        switch k {
        case "--live":    o.live = true
        case "--probe":   o.probe = true
        case "--stitch":  o.stitch = true
        case "--in":      if let v = value(k) { o.inputs.append(v) }
        case "--cols":    if let v = value(k) { o.cols = Int(v) ?? o.cols }
        case "--gap":     if let v = value(k) { o.gap = Double(v) ?? o.gap }
        case "--html":    if let v = value(k) { o.html = v }
        case "--out":     if let v = value(k) { o.out = v }
        case "--width":   if let v = value(k) { o.width = Double(v) ?? o.width }
        case "--height":  if let v = value(k) { o.height = Double(v) ?? o.height }
        case "--js":      if let v = value(k) { o.js = append(o.js, v) }
        case "--js-file":
            if let v = value(k) {
                if let text = try? String(contentsOfFile: v, encoding: .utf8) {
                    o.js = append(o.js, text)
                } else {
                    // 读不到就静默当空串的话，调用方会拿到一张「数据没注入」的图还以为是好的
                    FileHandle.standardError.write("读不到 \(v)\n".data(using: .utf8)!)
                }
            }
        case "--wait":    if let v = value(k) { o.wait = Double(v) ?? o.wait }
        case "--settle":  if let v = value(k) { o.settle = Double(v) ?? o.settle }
        case "--timeout": if let v = value(k) { o.timeout = Double(v) ?? o.timeout }
        default:
            FileHandle.standardError.write("未知参数 \(k)\n".data(using: .utf8)!)
        }
        i += 1
    }
    return o
}

let opts = parseArgs()

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write("✗ \(msg)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - 拼图
//
// 把已经出好的若干张图拼成一张。存在的理由只有一个：**README 里的主题一览**。
// 四种主题分开放四张图，读者要自己上下滚动才能对比；拼成一条才看得出
// 「差别只在配色」这件事。顺手也省掉三份重复的文件体积。
//
// 这里不做缩放：调用方出的图尺寸本来就一样，缩放只会引入重采样误差
// （`sips -Z` 对小图反而可能把文件变大）。
if opts.stitch {
    let imgs: [CGImage] = opts.inputs.map { path in
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { fail("读不到图片 \(path)") }
        return img
    }
    guard !imgs.isEmpty else { fail("--stitch 至少要一个 --in") }

    let cols = opts.cols > 0 ? opts.cols : imgs.count
    let rows = Int(ceil(Double(imgs.count) / Double(cols)))
    let cellW = imgs.map(\.width).max()!
    let cellH = imgs.map(\.height).max()!
    let gap = Int(opts.gap)
    let W = cols * cellW + (cols - 1) * gap
    let H = rows * cellH + (rows - 1) * gap

    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("建不了画布 \(W)×\(H)") }

    // 背景**留透明**：README 在 GitHub 的浅色和深色两种页面下都会被渲染，
    // 填一个固定底色的话，总有一种模式看着是错的。
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

    for (idx, img) in imgs.enumerated() {
        let col = idx % cols, row = idx / cols
        // CG 的原点在**左下角**，而图是自上而下排的 —— 行号要翻一次，
        // 否则多行拼出来整排顺序是倒的（和画图标那次踩的是同一个坑）。
        let x = col * (cellW + gap)
        let y = (rows - 1 - row) * (cellH + gap)
        ctx.draw(img, in: CGRect(x: x, y: y, width: img.width, height: img.height))
    }

    guard let out = ctx.makeImage() else { fail("合成失败") }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("编码 PNG 失败") }
    do { try png.write(to: URL(fileURLWithPath: opts.out)) }
    catch { fail("写文件失败：\(error.localizedDescription)") }
    print("✓ \(opts.out)  \(imgs.count) 张拼成 \(cols)×\(rows)，\(W)×\(H)px")
    exit(0)
}

guard !opts.html.isEmpty else {
    FileHandle.standardError.write("缺少 --html\n".data(using: .utf8)!)
    exit(2)
}

// MARK: - 窗口与 webview

// 无 Xcode 环境下用 AppKit 起一个不激活的进程：不需要 Dock 图标，也不抢焦点。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let rect = NSRect(x: 0, y: 0, width: opts.width, height: opts.height)
let win = NSWindow(contentRect: rect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
win.isReleasedWhenClosed = false
// 挪到屏幕外：不打扰用户，但**必须 orderFront**——不在窗口层级里的 WKWebView
// 不会真正排版，takeSnapshot 会得到一张空白图。
win.setFrameOrigin(NSPoint(x: -40000, y: -40000))

let web = WKWebView(frame: rect, configuration: WKWebViewConfiguration())
web.autoresizingMask = [.width, .height]
win.contentView = web
win.orderFrontRegardless()

// MARK: - 导航

final class Nav: NSObject, WKNavigationDelegate {
    var didFinish: (() -> Void)?
    var didFail: ((String) -> Void)?

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { didFinish?() }
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        didFail?(e.localizedDescription)
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError e: Error) {
        didFail?(e.localizedDescription)
    }
}

let nav = Nav()
web.navigationDelegate = nav

// MARK: - 冻住动画

/// 卡片是 `animation: cardIn .3s ... both` 从 opacity:0 淡入的。
/// 离屏窗口不在屏幕合成里，WKWebView 不会推进动画 → 卡片永远停在 opacity:0，
/// 截出来就是「顶栏正常、卡片区一片空白」，很容易被误读成渲染坏了。
///
/// 所以截图前先把动画和过渡关掉——面板自己就有这条降级规则
/// （`@media (prefers-reduced-motion: reduce)`），这里等于手动扮演一次
/// 「用户开了减弱动态效果」，不是额外发明的行为。加 `--live` 可关掉，用于专门看动画。
let freezeJS = """
(() => {
  const s = document.createElement('style');
  s.id = '__snapshot_freeze';
  s.textContent = '*,*::before,*::after{animation:none !important;transition:none !important;}';
  document.head.appendChild(s);
  return 'frozen';
})()
"""

func shoot() {
    let conf = WKSnapshotConfiguration()
    conf.rect = rect
    conf.afterScreenUpdates = true
    web.takeSnapshot(with: conf) { image, error in
        if let error = error { fail("takeSnapshot 失败：\(error.localizedDescription)") }
        guard let image = image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { fail("拿不到位图数据") }
        do {
            try png.write(to: URL(fileURLWithPath: opts.out))
            let px = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            print("✓ \(opts.out)  \(Int(opts.width))×\(Int(opts.height))pt → \(px)px")
            exit(0)
        } catch {
            fail("写文件失败：\(error.localizedDescription)")
        }
    }
}

func prepareAndShoot() {
    // 先冻动画，再跑调用方给的 JS（比如点开弹层）——顺序不能反，
    // 否则弹层的展开过渡会截到一半。
    let steps = (opts.live ? [] : [freezeJS]) + (opts.js.isEmpty ? [] : [opts.js])
    guard !steps.isEmpty else {
        if opts.probe { fail("--probe 需要配 --js 或 --js-file") }
        shoot(); return
    }
    web.evaluateJavaScript(steps.joined(separator: ";\n")) { value, error in
        if let error = error {
            // 注入出错就报出来——宁可失败，也别给一张「看着正常但状态不对」的图
            fail("注入脚本出错：\(error.localizedDescription)")
        }
        // 探针模式：脚本最后一句的返回值就是结果，直接打到 stdout。
        // 这样「居中偏了几像素」这种问题能量出来，不用对着 PNG 估。
        if opts.probe {
            let text = (value as? String) ?? String(describing: value ?? "")
            print(text)
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + opts.wait) { shoot() }
    }
}

nav.didFinish = {
    DispatchQueue.main.asyncAfter(deadline: .now() + opts.settle) { prepareAndShoot() }
}
nav.didFail = { fail("加载失败：\($0)") }

// 总超时：webview 卡住时不要挂着不返回
DispatchQueue.main.asyncAfter(deadline: .now() + opts.timeout) {
    fail("超时 \(Int(opts.timeout))s 未完成", 3)
}

let url = URL(fileURLWithPath: opts.html)
web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

app.run()
