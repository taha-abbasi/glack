import Foundation
import GRDB
import Observation

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
