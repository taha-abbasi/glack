import Foundation
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1-initial") { db in
            try db.create(table: "space") { t in
                t.column("id", .text).primaryKey()
                t.column("spaceType", .text).notNull()
                t.column("displayName", .text)
                t.column("threaded", .boolean).notNull().defaults(to: false)
                t.column("lastActivityAt", .datetime)
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("lastReadAt", .datetime)
                t.column("backfillOldestSeenId", .text)
                t.column("backfillCompleteAt", .datetime)
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(indexOn: "space", columns: ["lastActivityAt"])

            try db.create(table: "message") { t in
                t.column("id", .text).primaryKey()
                t.column("spaceId", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("senderId", .text)
                t.column("senderName", .text)
                t.column("text", .text)
                t.column("textPlain", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime)
                t.column("threadId", .text)
                t.column("deletedAt", .datetime)
                t.column("attachmentCount", .integer).notNull().defaults(to: 0)
                t.column("rawJson", .text)
            }
            try db.create(indexOn: "message", columns: ["spaceId", "createdAt"])
            try db.create(indexOn: "message", columns: ["threadId"])
            try db.create(indexOn: "message", columns: ["senderId", "createdAt"])
            try db.create(indexOn: "message", columns: ["deletedAt"])

            try db.create(table: "member") { t in
                t.column("spaceId", .text).notNull()
                    .references("space", onDelete: .cascade)
                t.column("userId", .text).notNull()
                t.column("displayName", .text)
                t.column("avatarUrl", .text)
                t.primaryKey(["spaceId", "userId"])
            }

            // FTS5 over message.textPlain, external content (no row duplication).
            // Created here, populated continuously via triggers from Phase 2 onward,
            // queried in Phase 6.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    textPlain,
                    content='message',
                    content_rowid='rowid',
                    tokenize='porter unicode61 remove_diacritics 2'
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER message_after_insert AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, textPlain) VALUES (new.rowid, new.textPlain);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER message_after_delete AFTER DELETE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, textPlain)
                    VALUES ('delete', old.rowid, old.textPlain);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER message_after_update AFTER UPDATE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, textPlain)
                    VALUES ('delete', old.rowid, old.textPlain);
                    INSERT INTO message_fts(rowid, textPlain) VALUES (new.rowid, new.textPlain);
                END
            """)
        }

        m.registerMigration("v2-space-classification-fields") { db in
            try db.alter(table: "space") { t in
                t.add(column: "spaceHistoryState", .text)
                t.add(column: "spaceUri", .text)
                t.add(column: "externalUserAllowed", .boolean)
                t.add(column: "singleUserBotDm", .boolean)
                t.add(column: "importMode", .boolean)
                t.add(column: "adminInstalled", .boolean)
                t.add(column: "predefinedPermissionSettings", .text)
                t.add(column: "accessState", .text)
                t.add(column: "membershipCountHumans", .integer)
                t.add(column: "membershipCountGroups", .integer)
            }
        }

        m.registerMigration("v3-user-directory-cache") { db in
            try db.create(table: "user") { t in
                t.column("id", .text).primaryKey()        // "users/{numeric-id}"
                t.column("displayName", .text)
                t.column("givenName", .text)
                t.column("familyName", .text)
                t.column("photoUrl", .text)
                t.column("email", .text)
                t.column("lastSyncedAt", .datetime).notNull()
            }
            try db.create(indexOn: "user", columns: ["email"])
        }

        return m
    }
}
