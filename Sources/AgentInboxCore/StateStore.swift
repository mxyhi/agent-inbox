import Foundation
import OSLog
import SQLite3

public actor StateStore {
    private let databaseURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "agent-inbox", category: "StateStore")

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Agent Inbox/state.sqlite"),
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    public func load() async -> PersistedState {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            try migrate(database)

            let pinMode = try readPinMode(database) ?? .todoOnly
            let trackingStartedAt = try ensureTrackingStartedAt(database)
            let completedSessionIDs = try readCompletedSessionIDs(database)
            let panelAnchor = try readPanelAnchor(database)
            let promptFilterRules = try readPromptFilterRules(database)
            let openSessionConfig = try readOpenSessionConfig(database)
            let updateProxyConfig = try readNetworkProxyConfig(database)
            logger.info("Loaded SQLite state from \(self.databaseURL.path, privacy: .public)")

            return PersistedState(
                pinMode: pinMode,
                completedSessionIDs: completedSessionIDs,
                trackingStartedAt: trackingStartedAt,
                panelAnchor: panelAnchor,
                promptFilterRules: promptFilterRules,
                openSessionConfig: openSessionConfig,
                updateProxyConfig: updateProxyConfig
            )
        } catch {
            logger.error("Failed to load SQLite state, using default: \(String(describing: error), privacy: .public)")
            return PersistedState()
        }
    }

    public func save(_ state: PersistedState) async {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }

            try migrate(database)
            try execute(database, "BEGIN IMMEDIATE TRANSACTION")
            do {
                try savePinMode(state.pinMode, database)
                try saveTrackingStartedAt(state.trackingStartedAt, database)
                try savePanelAnchor(state.panelAnchor, database)
                try replaceCompletedSessions(state.completedSessionIDs, database)
                try replacePromptFilterRules(state.promptFilterRules, database)
                try saveOpenSessionConfig(state.openSessionConfig, database)
                try saveNetworkProxyConfig(state.updateProxyConfig, database)
                try execute(database, "COMMIT")
                logger.info("Saved SQLite state to \(self.databaseURL.path, privacy: .public)")
            } catch {
                try? execute(database, "ROLLBACK")
                throw error
            }
        } catch {
            logger.error("Failed to save SQLite state: \(String(describing: error), privacy: .public)")
        }
    }

    private func openDatabase() throws -> OpaquePointer {
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let database else {
            throw SQLiteStoreError.openFailed(message: String(cString: sqlite3_errmsg(database)))
        }

        try executeRaw(database, "PRAGMA journal_mode = WAL")
        try executeRaw(database, "PRAGMA foreign_keys = ON")
        return database
    }

    private func migrate(_ database: OpaquePointer) throws {
        try executeRaw(database, """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """)

        try executeRaw(database, """
        CREATE TABLE IF NOT EXISTS completed_sessions (
            session_id TEXT PRIMARY KEY NOT NULL,
            completed_at REAL NOT NULL
        )
        """)

        try executeRaw(database, """
        CREATE TABLE IF NOT EXISTS filter_rules (
            id TEXT PRIMARY KEY NOT NULL,
            enabled INTEGER NOT NULL,
            field TEXT NOT NULL,
            match_type TEXT NOT NULL,
            pattern TEXT NOT NULL,
            action TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """)

        // 移除历史遗留的 name 列:规则由 pattern 直接标识,name 冗余。
        // 旧库有该列时 DROP;新库无此列,ALTER 失败可安全忽略。
        try? executeRaw(database, "ALTER TABLE filter_rules DROP COLUMN name")
    }

    private func readPinMode(_ database: OpaquePointer) throws -> PinMode? {
        try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("pin_mode")]
        ).flatMap(PinMode.init(rawValue:))
    }

    private func readCompletedSessionIDs(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "SELECT session_id FROM completed_sessions"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else {
                continue
            }
            ids.insert(String(cString: cString))
        }
        return ids
    }

    private func savePinMode(_ pinMode: PinMode, _ database: OpaquePointer) throws {
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("pin_mode"), .text(pinMode.rawValue)]
        )
    }

    /// 首次打开 app 时建立跟踪基线;基线前已完成的历史 rollout 不再刷成待办
    private func ensureTrackingStartedAt(_ database: OpaquePointer) throws -> Date {
        if let raw = try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("tracking_started_at")]
        ), let epoch = TimeInterval(raw) {
            return Date(timeIntervalSince1970: epoch)
        }

        let now = Date()
        try saveTrackingStartedAt(now, database)
        logger.info("Initialized tracking baseline at \(now.timeIntervalSince1970, privacy: .public)")
        return now
    }

    private func saveTrackingStartedAt(_ date: Date, _ database: OpaquePointer) throws {
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("tracking_started_at"), .text(String(date.timeIntervalSince1970))]
        )
    }

    /// 读取浮窗锚点:settings 表 key = panel_anchor,value 为 "x,y"(两个 Double 逗号拼接)
    private func readPanelAnchor(_ database: OpaquePointer) throws -> PanelAnchor? {
        guard let raw = try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("panel_anchor")]
        ) else {
            return nil
        }

        let parts = raw.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            logger.warning("Ignoring malformed panel_anchor value: \(raw, privacy: .public)")
            return nil
        }
        return PanelAnchor(topRightX: x, topRightY: y)
    }

    /// 写入浮窗锚点;nil 表示恢复默认位置,直接删除该行
    private func savePanelAnchor(_ anchor: PanelAnchor?, _ database: OpaquePointer) throws {
        guard let anchor else {
            try execute(
                database,
                "DELETE FROM settings WHERE key = ?",
                bindings: [.text("panel_anchor")]
            )
            return
        }

        // Swift 的 Double 文本表示保证 round-trip 精度,"x,y" 往返无损
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("panel_anchor"), .text("\(anchor.topRightX),\(anchor.topRightY)")]
        )
    }

    private func readOpenSessionConfig(_ database: OpaquePointer) throws -> OpenSessionConfig {
        let methodRaw = try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("open_session_method")]
        )
        let customCommand = try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("open_session_custom_command")]
        ) ?? ""

        guard let methodRaw else {
            return OpenSessionConfig()
        }
        guard let method = OpenSessionMethod(rawValue: methodRaw) else {
            logger.warning("Ignoring malformed open_session_method value: \(methodRaw, privacy: .public)")
            return OpenSessionConfig(customCommand: customCommand)
        }

        return OpenSessionConfig(method: method, customCommand: customCommand)
    }

    private func saveOpenSessionConfig(_ config: OpenSessionConfig, _ database: OpaquePointer) throws {
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("open_session_method"), .text(config.method.rawValue)]
        )
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("open_session_custom_command"), .text(config.customCommand)]
        )
    }

    private func readNetworkProxyConfig(_ database: OpaquePointer) throws -> NetworkProxyConfig {
        let urlString = try querySingleText(
            database,
            sql: "SELECT value FROM settings WHERE key = ?",
            bindings: [.text("update_proxy_url")]
        ) ?? ""

        let config = NetworkProxyConfig(urlString: urlString).normalized
        if !config.isEmpty && !config.isUsable {
            logger.warning("Ignoring malformed update_proxy_url value: \(urlString, privacy: .public)")
            return NetworkProxyConfig()
        }
        return config
    }

    private func saveNetworkProxyConfig(_ config: NetworkProxyConfig, _ database: OpaquePointer) throws {
        let normalized = config.normalized
        try execute(
            database,
            "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            bindings: [.text("update_proxy_url"), .text(normalized.urlString)]
        )
    }

    private func replaceCompletedSessions(_ ids: Set<String>, _ database: OpaquePointer) throws {
        try execute(database, "DELETE FROM completed_sessions")

        for id in ids {
            try execute(
                database,
                "INSERT INTO completed_sessions(session_id, completed_at) VALUES (?, ?)",
                bindings: [.text(id), .double(Date().timeIntervalSince1970)]
            )
        }
    }

    private func readPromptFilterRules(_ database: OpaquePointer) throws -> [PromptFilterRule] {
        var statement: OpaquePointer?
        let sql = """
        SELECT id, enabled, field, match_type, pattern, action, created_at, updated_at
        FROM filter_rules
        ORDER BY created_at ASC
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var rules: [PromptFilterRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = textColumn(statement, 0),
                  let field = textColumn(statement, 2).flatMap(PromptFilterField.init(rawValue:)),
                  let matchType = textColumn(statement, 3).flatMap(PromptFilterMatchType.init(rawValue:)),
                  let pattern = textColumn(statement, 4),
                  let action = textColumn(statement, 5).flatMap(PromptFilterAction.init(rawValue:)) else {
                logger.warning("Ignoring malformed filter_rules row")
                continue
            }

            rules.append(PromptFilterRule(
                id: id,
                isEnabled: sqlite3_column_int(statement, 1) != 0,
                field: field,
                matchType: matchType,
                pattern: pattern,
                action: action,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            ))
        }
        return rules
    }

    private func replacePromptFilterRules(_ rules: [PromptFilterRule], _ database: OpaquePointer) throws {
        try execute(database, "DELETE FROM filter_rules")

        for rule in rules {
            try execute(
                database,
                """
                INSERT INTO filter_rules(
                    id, enabled, field, match_type, pattern, action, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(rule.id),
                    .integer(rule.isEnabled ? 1 : 0),
                    .text(rule.field.rawValue),
                    .text(rule.matchType.rawValue),
                    .text(rule.pattern),
                    .text(rule.action.rawValue),
                    .double(rule.createdAt.timeIntervalSince1970),
                    .double(rule.updatedAt.timeIntervalSince1970)
                ]
            )
        }
    }

    private func execute(_ database: OpaquePointer, _ sql: String, bindings: [SQLiteBinding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement, database: database)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.executeFailed(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    private func querySingleText(
        _ database: OpaquePointer,
        sql: String,
        bindings: [SQLiteBinding]
    ) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement, database: database)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: cString)
    }

    private func textColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?, database: OpaquePointer) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result = switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            case let .double(value):
                sqlite3_bind_double(statement, position, value)
            case let .integer(value):
                sqlite3_bind_int64(statement, position, value)
            }

            guard result == SQLITE_OK else {
                throw SQLiteStoreError.executeFailed(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func executeRaw(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }

        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw SQLiteStoreError.executeFailed(message: message)
        }
    }
}

private enum SQLiteBinding {
    case text(String)
    case double(Double)
    case integer(Int64)
}

private enum SQLiteStoreError: Error {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case executeFailed(message: String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
