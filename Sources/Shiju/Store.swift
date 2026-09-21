import Foundation
import SQLite3

/// SQLite 是 C 宏，Swift 里拿不到，需要手工桥接。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 本地卡片库。单文件、无服务、无账号。
///
/// 关于全文搜索的一个取舍：设计文档原计划用 FTS5，实测后改用 `LIKE`。
/// 原因是 FTS5 的分词器对中文都不合适——
/// `unicode61` 会把一整串汉字当作单个 token，搜「句子」匹配不到「这是一句话」；
/// `trigram` 又要求查询至少 3 个字符，而中文两字查询极常见。
/// `LIKE '%x%'` 对中文是正确且无长度限制的，5000 条量级全表扫描在 1ms 内，
/// 因此这里选正确性而非索引。
final class Store {
    static let shared = Store()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.shiju.store")

    private init() {}

    // MARK: - 生命周期

    static var databaseURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("library.db")
    }

    func open() {
        queue.sync {
            guard db == nil else { return }
            let url = Store.databaseURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            var handle: OpaquePointer?
            if sqlite3_open(url.path, &handle) != SQLITE_OK {
                Diag.note("数据库打开失败: \(url.path)")
                return
            }
            db = handle
            exec("PRAGMA journal_mode = WAL;")
            exec("PRAGMA synchronous = NORMAL;")
            migrate()
        }
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS snippets (
          id            TEXT PRIMARY KEY,
          text          TEXT NOT NULL,
          text_hash     TEXT NOT NULL,
          source_app    TEXT,
          source_title  TEXT,
          source_url    TEXT,
          captured_at   INTEGER NOT NULL,
          starred       INTEGER NOT NULL DEFAULT 0,
          deleted_at    INTEGER,
          tags          TEXT NOT NULL DEFAULT '[]'
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_snippets_hash ON snippets(text_hash);")
        exec("CREATE INDEX IF NOT EXISTS idx_snippets_time ON snippets(captured_at DESC);")
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            Diag.note("SQL 失败: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    // MARK: - 写入

    /// 返回 nil 表示这条内容此前已收录（命中 text_hash 去重）。
    ///
    /// `tags` 只有面板手动记录那条路会传（选区收录没有标签可填）。
    @discardableResult
    func insert(text: String,
                sourceApp: String?,
                sourceTitle: String?,
                sourceURL: String?,
                tags: [String] = []) -> Snippet? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hash = Snippet.hash(trimmed)
        var result: Snippet?

        queue.sync {
            guard let db else { return }
            if existingID(hash: hash) != nil { return }

            let snippet = Snippet(
                id: UUID().uuidString,
                text: trimmed,
                textHash: hash,
                sourceApp: sourceApp,
                sourceTitle: sourceTitle,
                sourceURL: sourceURL,
                capturedAt: Int64(Date().timeIntervalSince1970 * 1000),
                starred: false,
                deletedAt: nil,
                tags: tags
            )

            let sql = """
            INSERT INTO snippets
              (id, text, text_hash, source_app, source_title, source_url, captured_at, starred, deleted_at, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, snippet.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, snippet.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, snippet.textHash, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 4, snippet.sourceApp)
            bindOptionalText(stmt, 5, snippet.sourceTitle)
            bindOptionalText(stmt, 6, snippet.sourceURL)
            sqlite3_bind_int64(stmt, 7, snippet.capturedAt)
            sqlite3_bind_text(stmt, 8, encodeTags(snippet.tags), -1, SQLITE_TRANSIENT)

            if sqlite3_step(stmt) == SQLITE_DONE { result = snippet }
        }
        return result
    }

    /// 已存在则返回其 id；软删除状态下的也算「已存在」，避免删了又被重新收录。
    func existingID(hash: String) -> String? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM snippets WHERE text_hash = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        sqlite3_bind_text(stmt, 1, hash, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    func setStarred(id: String, starred: Bool) {
        run("UPDATE snippets SET starred = ? WHERE id = ?;", [.int(starred ? 1 : 0), .text(id)])
    }

    func update(id: String, text: String, tags: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run("UPDATE snippets SET text = ?, text_hash = ?, tags = ? WHERE id = ?;",
            [.text(trimmed), .text(Snippet.hash(trimmed)), .text(encodeTags(tags)), .text(id)])
    }

    func softDelete(id: String) {
        run("UPDATE snippets SET deleted_at = ? WHERE id = ?;",
            [.int(Int64(Date().timeIntervalSince1970 * 1000)), .text(id)])
    }

    /// 事后补上出处链接。
    ///
    /// 为什么需要「事后」：取浏览器 URL 走 AppleScript，慢且可能弹授权框，
    /// 不能挡在收录流程上。所以先落库（`source_url` 为 NULL），等 URL 回来了再回填。
    /// 只填 `IS NULL` 的行，避免覆盖已有的更准确的链接。
    func setSourceURL(id: String, url: String) {
        guard !url.isEmpty else { return }
        run("UPDATE snippets SET source_url = ? WHERE id = ? AND source_url IS NULL;", [.text(url), .text(id)])
    }

    func restore(id: String) {
        run("UPDATE snippets SET deleted_at = NULL WHERE id = ?;", [.text(id)])
    }

    /// 撤销「刚刚收录」的那一条：直接物理删除。
    ///
    /// 为什么不用 `softDelete`：`existingID(hash:)` 把软删除的行也算作「已存在」，
    /// 所以软删之后同一句话会再也收不进来，用户看到的是「点了没反应」。
    /// 这行是几秒前才插进去的，硬删等价于「这次收录从未发生过」，语义也更准。
    func discard(id: String) {
        run("DELETE FROM snippets WHERE id = ?;", [.text(id)])
    }

    /// 回收站清理：软删除满 7 天后物理删除。
    func purgeExpired() {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 7 * 24 * 3600 * 1000
        run("DELETE FROM snippets WHERE deleted_at IS NOT NULL AND deleted_at < ?;", [.int(cutoff)])
    }

    // MARK: - 读取

    func all() -> [Snippet] { query(search: nil, filter: nil) }

    func query(search: String?, filter: String?) -> [Snippet] {
        var rows: [Snippet] = []
        queue.sync {
            guard let db else { return }
            var clauses = ["deleted_at IS NULL"]
            var binds: [Bind] = []

            switch filter {
            case "star": clauses.append("starred = 1")
            case "idea": clauses.append("source_app IS NULL")
            case "page":
                clauses.append("(lower(source_app) LIKE '%safari%' OR lower(source_app) LIKE '%chrome%'"
                             + " OR lower(source_app) LIKE '%edge%' OR lower(source_app) LIKE '%arc%'"
                             + " OR lower(source_app) LIKE '%firefox%')")
            case "term":
                clauses.append("(lower(source_app) LIKE '%terminal%' OR lower(source_app) LIKE '%iterm%'"
                             + " OR lower(source_app) LIKE '%warp%' OR lower(source_app) LIKE '%kitty%')")
            default: break
            }

            if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
                // LIKE 而非 FTS5：中文分词在 FTS5 下不可用，详见类注释。
                clauses.append("(text LIKE ? OR ifnull(source_title,'') LIKE ? OR ifnull(source_app,'') LIKE ?)")
                let pattern = "%\(search)%"
                binds.append(.text(pattern)); binds.append(.text(pattern)); binds.append(.text(pattern))
            }

            let sql = "SELECT id, text, text_hash, source_app, source_title, source_url,"
                    + " captured_at, starred, deleted_at, tags FROM snippets"
                    + " WHERE \(clauses.joined(separator: " AND "))"
                    + " ORDER BY captured_at DESC LIMIT 2000;"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, b) in binds.enumerated() { b.apply(to: stmt, at: Int32(i + 1)) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Snippet(
                    id: text(stmt, 0) ?? "",
                    text: text(stmt, 1) ?? "",
                    textHash: text(stmt, 2) ?? "",
                    sourceApp: text(stmt, 3),
                    sourceTitle: text(stmt, 4),
                    sourceURL: text(stmt, 5),
                    capturedAt: sqlite3_column_int64(stmt, 6),
                    starred: sqlite3_column_int(stmt, 7) != 0,
                    deletedAt: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8),
                    tags: decodeTags(text(stmt, 9))
                ))
            }
        }
        return rows
    }

    func stats() -> (total: Int, starred: Int) {
        var total = 0, starred = 0
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            if sqlite3_prepare_v2(db, "SELECT COUNT(*), SUM(starred) FROM snippets WHERE deleted_at IS NULL;",
                                  -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int(stmt, 0))
                starred = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return (total, starred)
    }

    // MARK: - 绑定与取值

    private enum Bind {
        case text(String)
        case int(Int64)
        func apply(to stmt: OpaquePointer?, at index: Int32) {
            switch self {
            case .text(let s): sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case .int(let i): sqlite3_bind_int64(stmt, index, i)
            }
        }
    }

    private func run(_ sql: String, _ binds: [Bind]) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            for (i, b) in binds.enumerated() { b.apply(to: stmt, at: Int32(i + 1)) }
            sqlite3_step(stmt)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: tags),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func decodeTags(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
}
