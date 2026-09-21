import Foundation

/// 一条收录记录。
///
/// 字段命名与面板 JS 期望的键名不完全一致（面板用的是 `app` / `title` / `url` / `ts`），
/// 转换集中在 `jsPayload(now:)` 里做，避免两边各自拼装导致漂移。
struct Snippet {
    var id: String
    var text: String
    var textHash: String
    var sourceApp: String?
    var sourceTitle: String?
    var sourceURL: String?
    var capturedAt: Int64          // 毫秒时间戳
    var starred: Bool
    var deletedAt: Int64?
    var tags: [String]

    /// 去重用的归一化：去首尾空白 → 连续空白折叠为单空格 → 转小写。
    /// 这样「同一句话多带了个换行」也能正确识别为重复。
    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    static func hash(_ text: String) -> String {
        let normalized = normalize(text)
        // 用 FNV-1a 而不是 CryptoKit：不需要密码学强度，且免去一次 import。
        var h: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }

    /// 内容类型。面板据此决定排版（终端用等宽、灵感用标题字体）。
    var kind: String {
        guard let app = sourceApp?.lowercased() else { return "idea" }
        if app.contains("terminal") || app.contains("iterm") || app.contains("warp")
            || app.contains("alacritty") || app.contains("kitty") || app.contains("hyper") {
            return "terminal"
        }
        if app.contains("safari") || app.contains("chrome") || app.contains("edge")
            || app.contains("arc") || app.contains("firefox") || app.contains("quark") {
            return "page"
        }
        if app.contains("wechat") || app.contains("qq") || app.contains("telegram")
            || app.contains("feishu") || app.contains("lark") || app.contains("dingtalk") {
            return "chat"
        }
        return "note"
    }

    /// 面板 `Shiju.hydrate()` 需要的形状。
    func jsPayload(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "text": text,
            "kind": kind,
            "capturedAt": capturedAt,
            "ts": max(0, now - capturedAt),   // 距今毫秒，面板旧逻辑兼容用
            "at": Snippet.relativeLabel(from: capturedAt, now: now),
            "starred": starred,
            "tags": tags,
        ]
        if let app = sourceApp { dict["app"] = app }
        if let title = sourceTitle, !title.isEmpty { dict["title"] = title }
        if let url = sourceURL, !url.isEmpty { dict["url"] = url }
        return dict
    }

    /// 相对时间文案。用日历日差而非毫秒差，跨零点时不会把「昨天深夜」算成「今天」。
    static func relativeLabel(from ts: Int64, now: Int64) -> String {
        let cal = Calendar.current
        let then = Date(timeIntervalSince1970: Double(ts) / 1000)
        let today = cal.startOfDay(for: Date(timeIntervalSince1970: Double(now) / 1000))
        let thatDay = cal.startOfDay(for: then)
        let days = cal.dateComponents([.day], from: thatDay, to: today).day ?? 0

        let hm = DateFormatter()
        hm.locale = Locale(identifier: "zh_CN")
        hm.dateFormat = "HH:mm"

        switch days {
        case ..<0: return hm.string(from: then)
        case 0:
            let minutes = Int((now - ts) / 60000)
            if minutes < 1 { return "刚刚" }
            if minutes < 60 { return "\(minutes) 分钟前" }
            return "今天 " + hm.string(from: then)
        case 1: return "昨天 " + hm.string(from: then)
        case 2...6: return "\(days) 天前"
        default:
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = cal.component(.year, from: then) == cal.component(.year, from: Date())
                ? "M月d日" : "yyyy年M月d日"
            return df.string(from: then)
        }
    }
}
