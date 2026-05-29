import Foundation
import os

/// Thin wrapper around os.Logger so we can pull Glack-only lines out of
/// the unified log with `log show --predicate 'subsystem == "com.github.taha-abbasi.glack"'`.
enum Log {
    static let auth     = Logger(subsystem: "com.github.taha-abbasi.glack", category: "auth")
    static let api      = Logger(subsystem: "com.github.taha-abbasi.glack", category: "api")
    static let db       = Logger(subsystem: "com.github.taha-abbasi.glack", category: "db")
    static let sync     = Logger(subsystem: "com.github.taha-abbasi.glack", category: "sync")
    static let ui       = Logger(subsystem: "com.github.taha-abbasi.glack", category: "ui")
    static let app      = Logger(subsystem: "com.github.taha-abbasi.glack", category: "app")
}
