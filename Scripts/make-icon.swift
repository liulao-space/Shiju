// 生成「拾句」的应用图标：一张 1024×1024 的 PNG。
//
// 为什么不放一个 .png 到仓库里：图标是「一个汉字 + 一块渐变」，
// 用代码画比存二进制更可维护——改配色、改字号都在这一处。
// 也不依赖 Xcode 或任何设计工具，`swift Scripts/make-icon.swift out.png` 即可。
//
// 由 Scripts/make-icon.sh 调用，之后交给 sips + iconutil 生成 .icns。

import AppKit
import CoreText
import Foundation

let px = 1024
let side = CGFloat(px)
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func makeContext(size: Int) -> CGContext {
    // bytesPerRow 显式给 size*4，不用 0 让系统自己定——否则行距可能被补齐，
    // 而下面扫像素是按「每行 size*4 字节」算下标的，一补就全错位。
    guard let ctx = CGContext(data: nil,
                              width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("✗ 无法创建绘图上下文\n".data(using: .utf8)!)
        exit(1)
    }
    return ctx
}

// 显式建位图上下文，不用 NSImage.lockFocus()——后者在 Retina 上
// 会按屏幕缩放生成 2x 表示，输出尺寸不稳定。
let ctx = makeContext(size: px)

// ── 底：Big Sur 风格的圆角方块，内容约占 80%，四周留白 ──
let inset = side * 0.098
let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = rect.width * 0.2237        // 与系统图标圆角比例一致
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let colors = [
    CGColor(srgbRed: 0.35, green: 0.56, blue: 0.94, alpha: 1),   // 上：晴空蓝（面板默认主题的强调色）
    CGColor(srgbRed: 0.12, green: 0.27, blue: 0.62, alpha: 1),   // 下：靛
] as CFArray
if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: colors,
                         locations: [0, 1]) {
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
}
ctx.restoreGState()

// ── 字：「拾」用宋体。衬线的气质比黑体更贴「摘句」这件事，也和面板的「纸间」主题同源 ──
let glyphSize = rect.width * 0.56
let font = NSFont(name: "STSongti-SC-Bold", size: glyphSize)
    ?? NSFont(name: "Songti SC", size: glyphSize)
    ?? NSFont.systemFont(ofSize: glyphSize, weight: .bold)

let attributed = NSAttributedString(string: "拾", attributes: [
    .font: font,
    .foregroundColor: NSColor.white,
])
let line = CTLineCreateWithAttributedString(attributed)

/// 先画一遍，量出**真实墨迹**的包围盒（相对文字原点）。
///
/// 为什么不用 `CTLineGetBoundsWithOptions(.useOpticalBounds)`：它给的框和实际落墨
/// 并不一致——实测「拾」按它居中会偏下 27px（1024 画布上的 2.6%）。
/// 靠常数补偿不可靠（换字体就变），量出来最准。
func measureInk() -> (minX: CGFloat, minY: CGFloat, width: CGFloat, height: CGFloat) {
    let probe = 900, origin = CGFloat(150)   // 字号 464，放在 (150,150) 够装下
    let scratch = makeContext(size: probe)

    // 先铺一层不透明黑。CGContext(data: nil) 分配的内存不保证已清零，
    // 不清底的话扫描会把残留数据当成墨迹（实测扫出满宽 900px 的假框）。
    scratch.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    scratch.fill(CGRect(x: 0, y: 0, width: probe, height: probe))

    scratch.textPosition = CGPoint(x: origin, y: origin)
    CTLineDraw(line, scratch)

    guard let raw = scratch.data else { exit(1) }
    let buf = raw.bindMemory(to: UInt8.self, capacity: probe * probe * 4)
    var minX = probe, maxX = -1, minRow = probe, maxRow = -1
    for row in 0..<probe {
        let base = row * probe * 4
        for x in 0..<probe {
            let i = base + x * 4
            // premultipliedLast：白色墨迹 = 四通道都接近 255
            if buf[i] > 224, buf[i + 1] > 224, buf[i + 2] > 224, buf[i + 3] > 224 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
    }
    guard maxX >= minX, maxRow >= minRow else {
        FileHandle.standardError.write("✗ 没画出字，检查字体是否可用\n".data(using: .utf8)!)
        exit(1)
    }
    // 扫到的框不该贴到探针边界，否则说明探针太小或下标错位——宁可报错也不要出歪图标
    if minX == 0 || minRow == 0 || maxX >= probe - 1 || maxRow >= probe - 1 {
        FileHandle.standardError.write(
            "✗ 墨迹扫描贴到探针边界（x[\(minX),\(maxX)] row[\(minRow),\(maxRow)]，探针 \(probe)）\n"
                .data(using: .utf8)!)
        exit(1)
    }
    // 位图缓冲是行优先、第 0 行在图像**顶部**，而绘图坐标系原点在左下角，
    // 所以行号要翻一次才是 CG 坐标里的 y。少了这一步，字会整体掉到画面底部。
    let cgMinY = CGFloat(probe - 1 - maxRow)
    let cgMaxY = CGFloat(probe - 1 - minRow)
    return (CGFloat(minX) - origin, cgMinY - origin,
            CGFloat(maxX - minX + 1), cgMaxY - cgMinY + 1)
}

let ink = measureInk()
// 按量出来的墨迹范围居中（而不是按字体报告的框）
ctx.textPosition = CGPoint(x: (side - ink.width) / 2 - ink.minX,
                           y: (side - ink.height) / 2 - ink.minY)
CTLineDraw(line, ctx)

guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("✗ 生成位图失败\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("✗ PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath)  \(px)×\(px)  墨迹 \(Int(ink.width))×\(Int(ink.height))")
