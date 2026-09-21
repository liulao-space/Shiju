import Foundation

/// 应用自己的文件位置。
///
/// 单独抽出来是为了**断开 `Diag` 对 `Store` 的反向依赖**。原先诊断日志的位置是
/// 从 `Store.databaseURL.deletingLastPathComponent()` 借来的，方向是反的：
/// 日志必须在数据库之前就可用了——「数据库打开失败」正是最需要日志的时候。
///
/// 这个反向依赖还带来一个很具体的后果：`Diag` 没法单独编译，于是
/// `Scripts/test-trigger.sh` 一编到 `HotKey.swift`（它要 `Diag.note`）就会被
/// 拖进整条 SQLite 链路。分层修正顺带把测试的编译面收窄了。
enum AppPaths {

    /// `~/Library/Application Support/Shiju`
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Shiju", isDirectory: true)
    }
}
