import Foundation
import GRDB

/// FTS5-backed full-text search over the local message cache. The
/// `message_fts` virtual table was created in v1 with the porter unicode61
/// tokenizer + triggers that mirror message inserts/updates/deletes, so
/// this is just a query layer on top.
enum MessageSearch {
    struct Result: Identifiable, Hashable {
        let messageID: String        // "spaces/X/messages/Y"
        let spaceID: String
        let spaceDisplayName: String?
        let senderID: String?
        let createdAt: Date
        /// Snippet returned by SQLite's `snippet(...)`. Match runs are wrapped
        /// in the literal tokens `«BEGIN»` and `«END»` so the SwiftUI side
        /// can parse them into bold attributed runs.
        let snippet: String
        var id: String { messageID }
    }

    static func search(_ rawQuery: String, limit: Int = 50) async -> [Result] {
        let query = sanitize(rawQuery)
        guard !query.isEmpty else { return [] }
        do {
            return try await Database.shared.read { db -> [Result] in
                let sql = """
                    SELECT
                      m.id          AS messageID,
                      m.spaceId     AS spaceID,
                      s.displayName AS spaceDisplayName,
                      m.senderId    AS senderID,
                      m.createdAt   AS createdAt,
                      snippet(message_fts, 0, '«BEGIN»', '«END»', '…', 12) AS snippet
                    FROM message_fts
                    JOIN message m ON m.rowid = message_fts.rowid
                    JOIN space s ON s.id = m.spaceId
                    WHERE message_fts MATCH ?
                      AND m.deletedAt IS NULL
                    ORDER BY rank
                    LIMIT ?
                """
                return try Row.fetchAll(db, sql: sql, arguments: [query, limit]).compactMap { row in
                    guard let id: String = row["messageID"],
                          let spaceID: String = row["spaceID"],
                          let createdAt: Date = row["createdAt"],
                          let snippet: String = row["snippet"]
                    else { return nil }
                    return Result(
                        messageID: id,
                        spaceID: spaceID,
                        spaceDisplayName: row["spaceDisplayName"],
                        senderID: row["senderID"],
                        createdAt: createdAt,
                        snippet: snippet
                    )
                }
            }
        } catch {
            Log.db.error("MessageSearch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Turn user input into an FTS5-safe query. Strips quote characters,
    /// splits on whitespace, wraps each token in quotes (so punctuation
    /// inside doesn't blow up the parser) and appends `*` so the last
    /// token can match as a prefix — gives "search-as-you-type" feel.
    private static func sanitize(_ input: String) -> String {
        let cleaned = input
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return "" }
        let quoted = tokens.enumerated().map { idx, tok -> String in
            let s = String(tok).replacingOccurrences(of: "\"", with: "")
            let q = "\"\(s)\""
            // Only the LAST token gets the FTS5 `*` prefix wildcard so the
            // user can search-as-they-type. Earlier tokens are matched in
            // full to keep results relevant.
            return idx == tokens.count - 1 ? q + "*" : q
        }
        return quoted.joined(separator: " ")
    }
}
