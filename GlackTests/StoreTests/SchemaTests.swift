import Testing
import GRDB
@testable import Glack

@Suite("Schema + FTS triggers")
struct SchemaTests {
    @Test("migrator creates all tables on a fresh DB")
    func migrationsCreateTables() throws {
        let db = try TestDatabase.makeInMemory()
        try db.read { db in
            let tables = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            #expect(tables.contains("space"))
            #expect(tables.contains("message"))
            #expect(tables.contains("member"))
            #expect(tables.contains("message_fts"))
        }
    }

    @Test("FTS5 trigger indexes message text on insert")
    func ftsInsertTrigger() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var space = Fixtures.space(id: "spaces/ZZZ")
            try space.save(db)
            var msg = Fixtures.message(
                id: "spaces/ZZZ/messages/M1",
                spaceID: "spaces/ZZZ",
                text: "the rain in spain falls mainly on the plain"
            )
            try msg.save(db)
        }

        try db.read { db in
            let hits = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["spain"])
            #expect(hits == 1)

            let none = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["nonexistent"])
            #expect(none == 0)
        }
    }

    @Test("FTS5 trigger removes entries on delete")
    func ftsDeleteTrigger() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var space = Fixtures.space(id: "spaces/DEL")
            try space.save(db)
            var msg = Fixtures.message(
                id: "spaces/DEL/messages/M1",
                spaceID: "spaces/DEL",
                text: "ephemeral phrase that should vanish"
            )
            try msg.save(db)
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM message WHERE id = ?",
                           arguments: ["spaces/DEL/messages/M1"])
        }
        try db.read { db in
            let hits = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["ephemeral"])
            #expect(hits == 0, "FTS should not retain deleted rows")
        }
    }

    @Test("FTS5 update trigger reindexes edited text")
    func ftsUpdateTrigger() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var space = Fixtures.space(id: "spaces/UPD")
            try space.save(db)
            var msg = Fixtures.message(
                id: "spaces/UPD/messages/M1",
                spaceID: "spaces/UPD",
                text: "original wording here"
            )
            try msg.save(db)
        }
        try db.write { db in
            try db.execute(sql:
                "UPDATE message SET textPlain = ? WHERE id = ?",
                arguments: ["completely different content", "spaces/UPD/messages/M1"])
        }
        try db.read { db in
            let original = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["original"])
            let different = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH ?",
                arguments: ["different"])
            #expect(original == 0)
            #expect(different == 1)
        }
    }

    @Test("space cascade-deletes its messages and members")
    func spaceCascadeDelete() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var space = Fixtures.space(id: "spaces/CASCADE")
            try space.save(db)
            var msg = Fixtures.message(
                id: "spaces/CASCADE/messages/M1", spaceID: "spaces/CASCADE")
            try msg.save(db)
            var member = MemberRecord(
                spaceId: "spaces/CASCADE", userId: "users/U1",
                displayName: "Alice", avatarUrl: nil)
            try member.save(db)
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM space WHERE id = ?",
                           arguments: ["spaces/CASCADE"])
        }
        try db.read { db in
            let msgCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM message WHERE spaceId = ?",
                arguments: ["spaces/CASCADE"])
            let memberCount = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM member WHERE spaceId = ?",
                arguments: ["spaces/CASCADE"])
            #expect(msgCount == 0)
            #expect(memberCount == 0)
        }
    }
}
