import Foundation
import GRDB

/// Singleton owner of the on-disk SQLite DB. Opened in WAL mode (DatabasePool)
/// so the UI can read while Sync writes.
enum Database {
    static let shared: DatabasePool = {
        do {
            let url = try storeURL()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            Log.db.info("opening DB at \(url.path, privacy: .public)")

            var config = Configuration()
            config.label = "glack.db"
            #if DEBUG
            config.publicStatementArguments = false
            #endif

            let pool = try DatabasePool(path: url.path, configuration: config)
            try Schema.migrator.migrate(pool)
            Log.db.info("DB ready")
            return pool
        } catch {
            Log.db.fault("failed to open DB: \(String(describing: error), privacy: .public)")
            fatalError("Failed to open Glack database: \(error)")
        }
    }()

    static func storeURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Glack/glack.db")
    }
}
