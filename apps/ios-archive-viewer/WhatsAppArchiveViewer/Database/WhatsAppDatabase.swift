import Foundation
import SQLite3
import UniformTypeIdentifiers

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct MediaSchema {
    let columns: Set<String>

    var canJoinMessages: Bool {
        columns.contains("ZMESSAGE")
    }

    func select(_ column: String, as alias: String) -> String {
        if columns.contains(column) {
            return "mi.\(column) AS \(alias)"
        }
        return "NULL AS \(alias)"
    }
}

private struct MediaPathResolution {
    let relativePath: String?
    let fileName: String?
    let existsInArchive: Bool
}

enum WhatsAppDatabaseError: LocalizedError {
    case missingDatabase(URL)
    case invalidSchema(String)
    case openFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase(let url):
            return "Missing ChatStorage.sqlite at \(url.path)"
        case .invalidSchema(let message):
            return "Invalid WhatsApp database schema: \(message)"
        case .openFailed(let message):
            return "Could not open ChatStorage.sqlite read-only: \(message)"
        case .queryFailed(let message):
            return "SQLite query failed: \(message)"
        }
    }
}

final class WhatsAppDatabase {
    private let databaseURL: URL
    private let archiveRootURL: URL
    private let securityScopedURL: URL?
    private let didStartSecurityScope: Bool
    private var database: OpaquePointer?
    private var mediaSchema: MediaSchema?

    init(databaseURL: URL, archiveRootURL: URL? = nil, securityScopedURL: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.archiveRootURL = archiveRootURL ?? databaseURL.deletingLastPathComponent()
        self.securityScopedURL = securityScopedURL
        self.didStartSecurityScope = securityScopedURL?.startAccessingSecurityScopedResource() ?? false

        do {
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                throw WhatsAppDatabaseError.missingDatabase(databaseURL)
            }

            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            var connection: OpaquePointer?
            let result = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)
            guard result == SQLITE_OK, let connection else {
                let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                if let connection {
                    sqlite3_close(connection)
                }
                throw WhatsAppDatabaseError.openFailed(message)
            }

            database = connection
            try execute("PRAGMA query_only = ON")
            try validateSchema()
            mediaSchema = try discoverMediaSchema()
        } catch {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
            if didStartSecurityScope {
                securityScopedURL?.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
        if didStartSecurityScope {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    func fetchChats() throws -> [ChatSummary] {
        let sql = """
            SELECT
                c.Z_PK,
                c.ZCONTACTJID,
                c.ZCONTACTIDENTIFIER,
                c.ZPARTNERNAME,
                c.ZLASTMESSAGEDATE,
                c.ZMESSAGECOUNTER,
                COUNT(m.Z_PK) AS message_count,
                MAX(m.ZMESSAGEDATE) AS latest_message_date
            FROM ZWACHATSESSION c
            LEFT JOIN ZWAMESSAGE m ON m.ZCHATSESSION = c.Z_PK
            GROUP BY
                c.Z_PK,
                c.ZCONTACTJID,
                c.ZCONTACTIDENTIFIER,
                c.ZPARTNERNAME,
                c.ZLASTMESSAGEDATE,
                c.ZMESSAGECOUNTER
            ORDER BY COALESCE(latest_message_date, c.ZLASTMESSAGEDATE, 0) DESC, c.Z_PK ASC
            """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var chats: [ChatSummary] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let contactJID = string(statement, 1)
            let contactIdentifier = string(statement, 2)
            let partnerName = string(statement, 3)
            let fallbackTitle = "Chat \(id)"
            let title = [partnerName, contactIdentifier, contactJID]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .first ?? fallbackTitle

            let latestMessageDate = date(statement, 7) ?? date(statement, 4)
            chats.append(
                ChatSummary(
                    id: id,
                    contactJID: contactJID,
                    contactIdentifier: contactIdentifier,
                    partnerName: partnerName,
                    title: title,
                    messageCount: Int(sqlite3_column_int64(statement, 6)),
                    latestMessageDate: latestMessageDate
                )
            )
            stepResult = sqlite3_step(statement)
        }

        try throwIfStatementFailed(stepResult)
        return chats
    }

    func fetchMessages(chatID: Int64, limit: Int = 500) throws -> [MessageRow] {
        let mediaSelectColumns = mediaSelectSQL()
        let mediaJoin = mediaJoinSQL()
        let sql = """
            SELECT *
            FROM (
                SELECT
                    m.Z_PK,
                    m.ZISFROMME,
                    m.ZFROMJID,
                    m.ZPUSHNAME,
                    m.ZTEXT,
                    m.ZMESSAGEDATE,
                    m.ZMESSAGETYPE,
                    \(mediaSelectColumns)
                FROM ZWAMESSAGE m
                \(mediaJoin)
                WHERE m.ZCHATSESSION = ?
                ORDER BY m.ZMESSAGEDATE DESC, m.Z_PK DESC
                LIMIT ?
            )
            ORDER BY ZMESSAGEDATE ASC, Z_PK ASC
            """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, chatID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var messages: [MessageRow] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            let media = mediaMetadata(from: statement, startingAt: 7)
            messages.append(
                MessageRow(
                    id: sqlite3_column_int64(statement, 0),
                    isFromMe: sqlite3_column_int(statement, 1) != 0,
                    senderJID: string(statement, 2),
                    pushName: string(statement, 3),
                    text: string(statement, 4),
                    messageDate: date(statement, 5),
                    messageType: int(statement, 6),
                    media: media
                )
            )
            stepResult = sqlite3_step(statement)
        }

        try throwIfStatementFailed(stepResult)
        return messages
    }

    private func validateSchema() throws {
        let requiredColumns: [String: Set<String>] = [
            "ZWACHATSESSION": [
                "Z_PK",
                "ZCONTACTJID",
                "ZCONTACTIDENTIFIER",
                "ZPARTNERNAME",
                "ZLASTMESSAGEDATE",
                "ZMESSAGECOUNTER"
            ],
            "ZWAMESSAGE": [
                "Z_PK",
                "ZCHATSESSION",
                "ZISFROMME",
                "ZFROMJID",
                "ZPUSHNAME",
                "ZTEXT",
                "ZMESSAGETYPE",
                "ZMESSAGEDATE"
            ]
        ]

        for (table, required) in requiredColumns {
            guard try tableExists(table) else {
                throw WhatsAppDatabaseError.invalidSchema("missing table \(table)")
            }

            let actualColumns = try columns(in: table)
            let missingColumns = required.subtracting(actualColumns).sorted()
            if !missingColumns.isEmpty {
                throw WhatsAppDatabaseError.invalidSchema(
                    "\(table) missing columns \(missingColumns.joined(separator: ", "))"
                )
            }
        }
    }

    private func discoverMediaSchema() throws -> MediaSchema? {
        guard try tableExists("ZWAMEDIAITEM") else {
            return nil
        }
        return MediaSchema(columns: try columns(in: "ZWAMEDIAITEM"))
    }

    private func mediaSelectSQL() -> String {
        guard let mediaSchema else {
            return [
                "NULL AS media_item_id",
                "NULL AS media_local_path",
                "NULL AS media_title",
                "NULL AS media_file_size",
                "NULL AS media_url"
            ].joined(separator: ",\n                    ")
        }

        return [
            mediaSchema.select("Z_PK", as: "media_item_id"),
            mediaSchema.select("ZMEDIALOCALPATH", as: "media_local_path"),
            mediaSchema.select("ZTITLE", as: "media_title"),
            mediaSchema.select("ZFILESIZE", as: "media_file_size"),
            mediaSchema.select("ZMEDIAURL", as: "media_url")
        ].joined(separator: ",\n                    ")
    }

    private func mediaJoinSQL() -> String {
        guard mediaSchema?.canJoinMessages == true else {
            return ""
        }
        return "LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK"
    }

    private func mediaMetadata(from statement: OpaquePointer, startingAt index: Int32) -> MediaMetadata? {
        let itemID = int64(statement, index)
        let localPath = string(statement, index + 1)
        let title = string(statement, index + 2)
        let fileSize = int64(statement, index + 3)
        let mediaURL = string(statement, index + 4)

        guard itemID != nil || localPath != nil || title != nil || fileSize != nil || mediaURL != nil else {
            return nil
        }

        let resolution = resolveMediaPath(localPath)
        let fileName = resolution.fileName ?? fileName(from: mediaURL) ?? title
        let mimeType = inferMimeType(fileName: fileName, localPath: localPath, mediaURL: mediaURL)
        let kind = inferMediaKind(mimeType: mimeType, fileName: fileName, localPath: localPath, mediaURL: mediaURL)

        return MediaMetadata(
            itemID: itemID,
            localPath: resolution.relativePath ?? localPath,
            fileName: fileName,
            title: title,
            mimeType: mimeType,
            fileSize: fileSize,
            isFileAvailableInArchive: resolution.existsInArchive,
            kind: kind
        )
    }

    private func resolveMediaPath(_ localPath: String?) -> MediaPathResolution {
        guard let relativePath = normalizedRelativeMediaPath(from: localPath) else {
            return MediaPathResolution(relativePath: nil, fileName: nil, existsInArchive: false)
        }

        let archiveRoot = archiveRootURL.standardizedFileURL
        let candidate = archiveRoot.appendingPathComponent(relativePath).standardizedFileURL
        let archiveRootPath = archiveRoot.path.hasSuffix("/") ? archiveRoot.path : archiveRoot.path + "/"
        let isInsideArchive = candidate.path.hasPrefix(archiveRootPath)
        let exists = isInsideArchive && FileManager.default.fileExists(atPath: candidate.path)

        return MediaPathResolution(
            relativePath: relativePath,
            fileName: candidate.lastPathComponent,
            existsInArchive: exists
        )
    }

    private func normalizedRelativeMediaPath(from value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), url.isFileURL {
            value = url.path
        }

        let normalizedValue = value.replacingOccurrences(of: "\\", with: "/")
        var components = normalizedValue.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let mediaIndex = components.firstIndex(where: { $0 == "Media" || $0 == "Message" }) {
            components = Array(components[mediaIndex...])
        }

        guard !components.isEmpty, !components.contains("..") else {
            return nil
        }

        return components.joined(separator: "/")
    }

    private func inferMimeType(fileName: String?, localPath: String?, mediaURL: String?) -> String? {
        guard let fileExtension = fileExtension(fileName: fileName, localPath: localPath, mediaURL: mediaURL) else {
            return nil
        }
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType
    }

    private func inferMediaKind(
        mimeType: String?,
        fileName: String?,
        localPath: String?,
        mediaURL: String?
    ) -> MediaAttachmentKind {
        if let mimeType {
            if mimeType.hasPrefix("image/") {
                return .photo
            }
            if mimeType.hasPrefix("video/") {
                return .video
            }
            if mimeType.hasPrefix("audio/") {
                return .audio
            }
        }

        guard let fileExtension = fileExtension(fileName: fileName, localPath: localPath, mediaURL: mediaURL) else {
            return .media
        }

        switch fileExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return .photo
        case "mp4", "mov", "m4v":
            return .video
        case "aac", "caf", "m4a", "mp3", "ogg", "opus", "wav":
            return .audio
        default:
            return .media
        }
    }

    private func fileExtension(fileName: String?, localPath: String?, mediaURL: String?) -> String? {
        for value in [fileName, localPath, mediaURL] {
            guard let value, !value.isEmpty else { continue }
            let pathExtension = URL(fileURLWithPath: value).pathExtension
            if !pathExtension.isEmpty {
                return pathExtension
            }
        }
        return nil
    }

    private func fileName(from value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let fileName = URL(fileURLWithPath: value).lastPathComponent
        return fileName.isEmpty ? nil : fileName
    }

    private func tableExists(_ table: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            return true
        }
        if result == SQLITE_DONE {
            return false
        }
        throw WhatsAppDatabaseError.queryFailed(lastErrorMessage)
    }

    private func columns(in table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let column = string(statement, 1) {
                columns.insert(column)
            }
            stepResult = sqlite3_step(statement)
        }

        try throwIfStatementFailed(stepResult)
        return columns
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw WhatsAppDatabaseError.queryFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw WhatsAppDatabaseError.queryFailed(lastErrorMessage)
        }
        return statement
    }

    private func throwIfStatementFailed(_ result: Int32) throws {
        guard result == SQLITE_DONE else {
            throw WhatsAppDatabaseError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
    }

    private var lastErrorMessage: String {
        guard let database else { return "database is not open" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func int(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int(statement, index))
    }

    private func int64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, index)
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, index))
    }
}
