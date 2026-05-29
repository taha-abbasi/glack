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
