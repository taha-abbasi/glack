import Testing
import GRDB
@testable import Glack

@Suite("Model records")
struct ModelsTests {
    @Test("SpaceRecord.type maps the spaceType column to the enum")
    func spaceTypeMapping() {
        #expect(Fixtures.space(type: .directMessage).type == .directMessage)
        #expect(Fixtures.space(type: .groupChat).type == .groupChat)
        #expect(Fixtures.space(type: .space).type == .space)

        var unknown = Fixtures.space()
        unknown.spaceType = "UNRECOGNIZED_FUTURE_VALUE"
        #expect(unknown.type == .unknown)
    }

    @Test("SpaceRecord save and fetch round-trips through SQLite")
    func spaceRoundTrip() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var s = Fixtures.space(id: "spaces/RT", displayName: "round-trip")
            try s.save(db)
        }
        try db.read { db in
            let fetched = try SpaceRecord.fetchOne(db, key: "spaces/RT")
            #expect(fetched?.displayName == "round-trip")
            #expect(fetched?.type == .space)
        }
    }

    @Test("MessageRecord with nil sender survives a round-trip")
    func messageNilFields() throws {
        let db = try TestDatabase.makeInMemory()
        try db.write { db in
            var space = Fixtures.space(id: "spaces/X")
            try space.save(db)
            var msg = Fixtures.message(
                id: "spaces/X/messages/M0",
                spaceID: "spaces/X"
            )
            msg.senderId = nil
            msg.senderName = nil
            try msg.save(db)
        }
        try db.read { db in
            let m = try MessageRecord.fetchOne(db, key: "spaces/X/messages/M0")
            #expect(m != nil)
            #expect(m?.senderId == nil)
            #expect(m?.senderName == nil)
        }
    }
}
