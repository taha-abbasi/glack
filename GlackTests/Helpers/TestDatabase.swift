import GRDB
@testable import Glack

/// Builds a fresh in-memory SQLite database with Glack's schema applied,
/// for use in StoreTests. Each test gets its own DB — no shared state.
enum TestDatabase {
    static func makeInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue)
        return queue
    }
}
