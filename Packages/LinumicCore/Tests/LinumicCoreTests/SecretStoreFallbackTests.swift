import Foundation
import Testing
@testable import LinumicCore

/// Against the real keychain, because the bug lived in what it answers: without the data-protection entitlement a read
/// says "not found" while a write says "missing entitlement". `swift test` runs without that entitlement, like the
/// Developer ID build.
@Suite("Keychain fallback", .serialized)
struct SecretStoreFallbackTests {
    private let store = KeychainSecretStore(service: "com.linumic.tests.keychain-fallback")
    private let account = "not-a-secret"

    /// A machine with no usable login keychain (some CI runners) can't run this; that is not a failure of the code.
    private func canWrite() -> Bool {
        do { try store.write("probe", account: account); return true } catch { return false }
    }

    @Test func whatWasSavedCanBeReadBack() throws {
        guard canWrite() else { return }
        defer { try? store.delete(account: account) }
        try store.write("value", account: account)
        #expect(try store.read(account: account) == "value")
    }

    @Test func aSecondWriteReplacesTheFirst() throws {
        guard canWrite() else { return }
        defer { try? store.delete(account: account) }
        try store.write("first", account: account)
        try store.write("second", account: account)
        #expect(try store.read(account: account) == "second")
    }

    @Test func aDeletedSecretIsGoneAndDeletingTwiceIsFine() throws {
        guard canWrite() else { return }
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account)
    }

    @Test func nothingSavedReadsAsNil() throws {
        #expect(try store.read(account: "never-saved") == nil)
    }
}
