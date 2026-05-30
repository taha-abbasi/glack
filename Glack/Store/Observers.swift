import Foundation
import GRDB
import Observation

/// Live aggregate of unread state across all spaces. Drives the dock
/// badge + the sidebar per-row badges.
@MainActor
@Observable
final class UnreadObserver {
    private(set) var totalUnread: Int = 0
    private(set) var perSpace: [String: Int] = [:]
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        let observation = ValueObservation.tracking { db -> [(String, Int)] in
            try Row.fetchAll(db, sql: "SELECT id, unreadCount FROM space WHERE unreadCount > 0")
                .compactMap { row in
                    guard let id: String = row["id"], let n: Int = row["unreadCount"] else { return nil }
                    return (id, n)
                }
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    var map: [String: Int] = [:]
                    var total = 0
                    for (id, n) in rows {
                        map[id] = n
                        total += n
                    }
                    self?.perSpace = map
                    self?.totalUnread = total
                    NotificationManager.shared.updateDockBadge(total)
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        NotificationManager.shared.updateDockBadge(0)
    }
}

/// Live list of all spaces, sorted by lastActivityAt desc.
/// Backed by GRDB's ValueObservation so the UI updates automatically when Sync writes.
@MainActor
@Observable
final class SpacesObserver {
    private(set) var spaces: [SpaceRecord] = []
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        let observation = ValueObservation.tracking { db in
            try SpaceRecord
                .order(SQL("COALESCE(lastActivityAt, addedAt) DESC"))
                .fetchAll(db)
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    self?.spaces = rows
                }
            } catch {
                // Observation can fail if DB is closed; fine.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Live cache of the directory-people user table, keyed by user ID.
/// Updated whenever syncDirectoryPeople writes new rows.
@MainActor
@Observable
final class UsersObserver {
    private(set) var users: [String: UserRecord] = [:]
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        let observation = ValueObservation.tracking { db in
            try UserRecord.fetchAll(db)
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    var map: [String: UserRecord] = [:]
                    for u in rows { map[u.id] = u }
                    self?.users = map
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func displayName(for userID: String?) -> String? {
        guard let id = userID, let u = users[id], let dn = u.displayName, !dn.isEmpty else { return nil }
        return dn
    }

    func photoURL(for userID: String?) -> URL? {
        guard let id = userID, let s = users[id]?.photoUrl else { return nil }
        return URL(string: s)
    }
}

/// One section + the ordered spaces assigned to it. The unit the sidebar renders.
struct SectionGroup: Hashable, Identifiable {
    var section: SectionRecord
    var spaces: [SpaceRecord]
    var id: String { section.id }
}

/// Live sidebar section structure — system + custom sections from Chat API,
/// joined to local space rows, ordered by sortOrder.
@MainActor
@Observable
final class SectionsObserver {
    private(set) var groups: [SectionGroup] = []
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        let observation = ValueObservation.tracking { db -> [SectionGroup] in
            let sections = try SectionRecord.order(SectionRecord.Columns.sortOrder).fetchAll(db)

            // Build a per-system-type bucket of orphans — spaces that exist
            // in the local cache but aren't claimed by any section_item row.
            // Chat's sections API doesn't cover every space (Daily Standup
            // auto-spaces, freshly-joined rooms before the section sync runs,
            // etc.) so without this they'd never render. Bucket by what we
            // think the system section SHOULD be based on the space's type.
            let orphans = try SpaceRecord.fetchAll(db, sql: """
                SELECT space.*
                FROM space
                LEFT JOIN section_item ON section_item.spaceId = space.id
                WHERE section_item.spaceId IS NULL
            """)
            var orphansBySystemType: [String: [SpaceRecord]] = [:]
            for s in orphans {
                let key: String
                if s.singleUserBotDm == true {
                    key = "DEFAULT_APPS"
                } else {
                    switch s.type {
                    case .directMessage, .groupChat: key = "DEFAULT_DIRECT_MESSAGES"
                    case .space, .unknown:           key = "DEFAULT_SPACES"
                    }
                }
                orphansBySystemType[key, default: []].append(s)
            }

            var out: [SectionGroup] = []
            for section in sections {
                var spaces = try SpaceRecord.fetchAll(db, sql: """
                    SELECT space.*
                    FROM space
                    JOIN section_item ON section_item.spaceId = space.id
                    WHERE section_item.sectionId = ?
                    ORDER BY section_item.sortOrder ASC
                """, arguments: [section.id])
                // Append orphans whose default system section matches this row.
                if let key = section.systemSectionType,
                   let extras = orphansBySystemType[key] {
                    spaces.append(contentsOf: extras)
                }
                out.append(SectionGroup(section: section, spaces: spaces))
            }
            return out
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    self?.groups = rows
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

extension SectionRecord {
    enum Columns {
        static let sortOrder = Column("sortOrder")
    }
}

/// Live membership cache — [spaceID: [userIDs]] — used to derive DM display
/// names from "the other person(s) in the room".
@MainActor
@Observable
final class MembersObserver {
    private(set) var membersBySpace: [String: [String]] = [:]
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        let observation = ValueObservation.tracking { db in
            try MemberRecord.fetchAll(db)
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    var grouped: [String: [String]] = [:]
                    for r in rows {
                        grouped[r.spaceId, default: []].append(r.userId)
                    }
                    self?.membersBySpace = grouped
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Per-thread reply counts for a single space. Drives the "Replies (N)"
/// affordance on the parent message in the conversation view.
@MainActor
@Observable
final class ThreadCountsObserver {
    /// `[threadId: total messages in that thread (including parent)]`.
    private(set) var counts: [String: Int] = [:]
    private(set) var spaceID: String?
    private var task: Task<Void, Never>?

    func observe(spaceID: String) {
        guard self.spaceID != spaceID else { return }
        self.spaceID = spaceID
        counts = [:]
        task?.cancel()
        let observation = ValueObservation.tracking { db -> [String: Int] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadId, COUNT(*) AS n
                FROM message
                WHERE spaceId = ? AND threadId IS NOT NULL AND deletedAt IS NULL
                GROUP BY threadId
            """, arguments: [spaceID])
            var map: [String: Int] = [:]
            for r in rows {
                guard let id: String = r["threadId"], let n: Int = r["n"] else { continue }
                map[id] = n
            }
            return map
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    self?.counts = rows
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        spaceID = nil
        counts = [:]
    }
}

/// Live messages within a single thread, in chronological order. Used by
/// the thread side panel.
@MainActor
@Observable
final class ThreadMessagesObserver {
    private(set) var messages: [MessageRecord] = []
    private(set) var threadID: String?
    private var task: Task<Void, Never>?

    func observe(threadID: String) {
        guard self.threadID != threadID else { return }
        self.threadID = threadID
        messages = []
        task?.cancel()
        let observation = ValueObservation.tracking { db in
            try MessageRecord
                .filter(MessageRecord.Columns.threadId == threadID)
                .filter(MessageRecord.Columns.deletedAt == nil)
                .order(MessageRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    self?.messages = rows
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        threadID = nil
        messages = []
    }
}

/// Live messages for a single space, sorted by createTime asc, deleted excluded.
@MainActor
@Observable
final class MessagesObserver {
    private(set) var messages: [MessageRecord] = []
    private(set) var spaceID: String?
    private var task: Task<Void, Never>?

    func observe(spaceID: String) {
        guard self.spaceID != spaceID else { return }
        self.spaceID = spaceID
        messages = []
        task?.cancel()
        // Hide thread replies from the main view — replies live in the
        // thread side panel only, exactly like Slack and Chat web. Parents
        // are kept (their id matches `messages/{base}.{base}` where base is
        // the thread's suffix). Pending optimistic sends are kept so the
        // sender still sees their message land.
        let observation = ValueObservation.tracking { db in
            try MessageRecord
                .filter(MessageRecord.Columns.spaceId == spaceID)
                .filter(MessageRecord.Columns.deletedAt == nil)
                .filter(SQL("""
                    threadId IS NULL
                    OR id LIKE 'pending-%'
                    OR id = REPLACE(threadId, '/threads/', '/messages/') || '.'
                          || substr(threadId, instr(threadId, '/threads/') + 9)
                """))
                .order(MessageRecord.Columns.createdAt.asc)
                .limit(500)
                .fetchAll(db)
        }
        task = Task { [weak self] in
            do {
                for try await rows in observation.values(in: Database.shared) {
                    self?.messages = rows
                }
            } catch {
                // Observation can fail if DB is closed; fine.
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        spaceID = nil
        messages = []
    }
}
