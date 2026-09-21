import Foundation

/// 一次「按下 → 拖拽 → 松手」的位移统计。
///
/// 为什么单独抽出来：触发判据这块踩过两次坑，两次都只在**真实的鼠标时序**下才暴露——
///
/// 1. 按「`leftMouseDragged` 事件个数」判：快速一划时系统会合并鼠标事件，
///    可能只收到 1 个，于是「划得很快」这一整类选择被静默漏掉。
/// 2. 只累加「拖拽事件之间」的差值：在只收到 1 个事件时压根没有参照点，
///    算出来恒为 0——**改了判据但等于没改**。起点必须取 `leftMouseDown` 的位置。
///
/// 抽成不依赖 AppKit 的纯结构体之后，就能用假坐标把这两种时序喂进来锁住。
struct DragTracker {

    private(set) var startPoint: NSPoint?
    private(set) var lastPoint: NSPoint?
    private(set) var distance: CGFloat = 0

    /// 是否正处在一次「按下—松手」之间。
    var isTracking: Bool { startPoint != nil }

    /// 鼠标按下。这里定的起点是全部位移的基准，不能省。
    mutating func begin(at point: NSPoint) {
        startPoint = point
        lastPoint = point
        distance = 0
    }

    /// 拖拽过程中的一次移动。
    mutating func extend(to point: NSPoint) {
        guard let last = lastPoint else { return }   // 没见过按下，无从累加
        distance += hypot(point.x - last.x, point.y - last.y)
        lastPoint = point
    }

    /// 松手。返回本次累计位移并复位。
    ///
    /// 会把「最后一个拖拽事件 → 松手位置」这一段也算进去，
    /// 否则快速松手时最后一段位移会被丢掉。
    mutating func finish(at point: NSPoint) -> (hadStart: Bool, distance: CGFloat) {
        extend(to: point)
        let result = (hadStart: startPoint != nil, distance: distance)
        startPoint = nil
        lastPoint = nil
        distance = 0
        return result
    }

    /// 这次「按下—松手」算不算一次选择动作。
    ///
    /// 单独拿出来是为了让「阈值判据」本身也能被单测覆盖——
    /// 判据改错不会崩、不会报错，只会静默地少弹或多弹按钮，最难发现。
    ///
    /// `threshold` 取 4pt：手抖的单击通常只挪 1–2pt，划选一个字至少十几个点，
    /// 中间有足够宽的区分带。
    static func isSelection(hadStart: Bool, distance: CGFloat, threshold: CGFloat = 4) -> Bool {
        hadStart && distance >= threshold
    }
}
