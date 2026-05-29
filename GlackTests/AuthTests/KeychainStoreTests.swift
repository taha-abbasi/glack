import Testing
import Foundation
@testable import Glack

@Suite("KeychainStore")
struct KeychainStoreTests {
    /// We test against the REAL Keychain (with the real service name), so we
    /// must namespace test accounts to prefixes we control and clean them up.
    /// Refusing to ever delete entries whose account doesn't start with the
    /// test prefix is the equivalent of AskFlorence's "synthetic email gate".
    private static let testAccountPrefix = "glacktest-"

    private func cleanup(_ account: String) {
        precondition(account.hasPrefix(Self.testAccountPrefix),
                     "test account must start with \(Self.testAccountPrefix)")
        try? KeychainStore.delete(account: account)
    }

    @Test("round-trip: set then get returns the same value")
    func roundTrip() throws {
        let account = "\(Self.testAccountPrefix)round-trip"
        defer { cleanup(account) }

        try KeychainStore.set("hello-keychain", account: account)
        let read = try KeychainStore.get(account: account)
        #expect(read == "hello-keychain")
    }

    @Test("overwrite: set twice returns the latest value")
    func overwrite() throws {
        let account = "\(Self.testAccountPrefix)overwrite"
        defer { cleanup(account) }

        try KeychainStore.set("v1", account: account)
        try KeychainStore.set("v2", account: account)
        #expect(try KeychainStore.get(account: account) == "v2")
    }

    @Test("delete: missing item is a no-op (no throw)")
    func deleteMissing() throws {
        let account = "\(Self.testAccountPrefix)never-existed-\(UInt64(ProcessInfo.processInfo.processIdentifier))"
        // Must not throw.
        try KeychainStore.delete(account: account)
    }

    @Test("get: missing item returns nil")
    func getMissing() throws {
        let account = "\(Self.testAccountPrefix)missing"
        defer { cleanup(account) }
        try KeychainStore.delete(account: account)
        #expect(try KeychainStore.get(account: account) == nil)
    }

    @Test("delete: clears value")
    func deleteClears() throws {
        let account = "\(Self.testAccountPrefix)delete-clears"
        defer { cleanup(account) }

        try KeychainStore.set("temp", account: account)
        try KeychainStore.delete(account: account)
        #expect(try KeychainStore.get(account: account) == nil)
    }
}
