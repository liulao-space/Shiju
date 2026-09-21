import Foundation

/// 诊断日志：把关键状态同时写到文件里。
///
/// 为什么不用 `NSLog` 就够了：统一日志（unified log）只能从 Console.app 或
/// `log show` 读，而 `log show` 在受限环境里会直接拒绝运行（`Cannot run while
/// sandboxed`）；更坑的是 **zsh 里 `log` 是个内建命令**，直接敲 `log show ...`
/// 会被 shell 吃掉、静默返回空——看上去就像「应用一条日志都没打」，
/// 从而把一个正常的程序误判成「压根没跑起来」。这个坑实际踩过一次，
/// 代价是排查方向整个跑偏。
///
/// 所以关键状态一律同时落一份纯文本到
/// `~/Library/Application Support/Shiju/diagnostics.log`：
/// 命令行能读，用户也能直接打开看。
enum Diag {

    /// 日志位置直接来自 `AppPaths`，不向 `Store` 借目录——
    /// 日志要能在数据库打开失败时照常工作（见 `Paths.swift`）。
    ///
    /// 环境变量 `SHIJU_DIAG_LOG` 可以把它指到别处。测试进程靠这个避免污染：
    /// 触发判据那套测试会故意制造「快捷键注册失败」，不重定向的话
    /// 那些假造的失败会写进用户真实的那份日志里，而那份日志正是排查问题时要读的。
    /// 顺带也让「跑一次测试就在用户 home 下建出 Application Support/Shiju」这件事不发生。
    static var logURL: URL {
        if let path = ProcessInfo.processInfo.environment["SHIJU_DIAG_LOG"] {
            return URL(fileURLWithPath: path)
        }
        return AppPaths.supportDirectory.appendingPathComponent("diagnostics.log")
    }

    /// 超过这个行数就从头截断，避免长期运行把文件撑大。
    private static let maxLines = 400

    private static let queue = DispatchQueue(label: "com.shiju.diag")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 记一条。同时进统一日志（给 Console.app）和文本文件（给命令行）。
    static func note(_ message: String) {
        NSLog("[Shiju] \(message)")
        let line = "\(formatter.string(from: Date()))  \(message)"
        queue.async { append(line) }
    }

    private static func append(_ line: String) {
        let url = logURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? "拾句 诊断日志\n\n".write(to: url, atomically: true, encoding: .utf8)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))

        // 超长就重写一遍，只留最后 maxLines 行。
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
            try? (lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 启动时清一次，避免上一轮的日志混进这一轮，让人误判。
    static func rotate() {
        queue.sync {
            let header = "拾句 诊断日志（每次启动清空）\n\n"
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? header.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
