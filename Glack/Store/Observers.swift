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
            var out: [SectionGroup] = []
            for section in sections {
                let spaces = try SpaceRecord.fetchAll(db, sql: """
                    SELECT space.*
                    FROM space
                    JOIN section_item ON section_item.spaceId = space.id
                    WHERE section_item.sectionId = ?
                    ORDER BY section_item.sortOrder ASC
                """, arguments: [section.id])
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
        let observation = ValueObservation.tracking { db in
            try MessageRecord
                .filter(MessageRecord.Columns.spaceId == spaceID)
                .filter(MessageRecord.Columns.deletedAt == nil)
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
