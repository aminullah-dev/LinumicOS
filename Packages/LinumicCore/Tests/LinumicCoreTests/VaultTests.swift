import Foundation
import Testing
@testable import LinumicCore

// TEST FIXTURES only: sample logins and passwords made up for these tests, never real credentials.

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

private func makeStore(_ secrets: InMemoryAccountSecretStore = InMemoryAccountSecretStore(), clock: Clock = Clock()) -> VaultStore {
    VaultStore(secrets: secrets, now: { clock.now })
}

/// Fails every write after `failAfter` successful ones.
private final class FailingSecrets: AccountSecretStore, @unchecked Sendable {
    let inner = InMemoryAccountSecretStore()
    var failIndexWrites = false
    func read(account: String) throws -> String? { try inner.read(account: account) }
    func write(_ value: String, account: String) throws {
        if failIndexWrites, account == VaultStore.indexAccount { throw KeychainError(status: -25293) }
        try inner.write(value, account: account)
    }
    func delete(account: String) throws { try inner.delete(account: account) }
}

@Suite("Vault store")
struct VaultStoreTests {
    @Test func firstLoadAddsEmptyTemplatesOnce() throws {
        let secrets = InMemoryAccountSecretStore()
        let store = makeStore(secrets)
        let first = try store.load()
        #expect(first.entries.count == VaultTemplates.all.count)
        #expect(first.templatesRevision == VaultTemplates.revision)
        #expect(first.entries.allSatisfy { $0.isEmpty && $0.login == nil && !$0.hasPassword && $0.templateSource != nil && $0.url != nil })
        // No password item was created for a template.
        #expect(secrets.accounts == [VaultStore.indexAccount])

        // A deleted template doesn't come back.
        try store.delete(id: first.entries[0].id)
        let second = try store.load()
        #expect(second.entries.count == VaultTemplates.all.count - 1)
        #expect(!second.entries.contains { $0.id == first.entries[0].id })
    }

    @Test func templateURLsAreHTTPSAndCited() {
        for t in VaultTemplates.all {
            #expect(URL(string: t.url)?.scheme == "https", "\(t.title)")
            #expect(!t.source.isEmpty)
        }
    }

    @Test func createReadUpdateDeleteRoundTrip() throws {
        let secrets = InMemoryAccountSecretStore()
        let clock = Clock()
        let store = makeStore(secrets, clock: clock)
        _ = try store.load()

        let draft = VaultEntry(title: "  Talar demo admin  ", product: .talar, environment: .demo,
                               url: URL(string: "https://example.com/admin"), login: " owner@example.com ", notes: "test")
        let saved = try store.save(draft, password: .set("sample-pass-1"))
        #expect(saved.title == "Talar demo admin")
        #expect(saved.login == "owner@example.com")
        #expect(saved.hasPassword)
        #expect(saved.passwordChangedAt == clock.now)
        #expect(try store.password(for: saved.id) == "sample-pass-1")

        // Reloading gives exactly what was saved, and the index never holds the password.
        let reloaded = try store.load()
        #expect(reloaded.entries.first { $0.id == saved.id } == saved)
        let indexText = try #require(try secrets.read(account: VaultStore.indexAccount))
        #expect(!indexText.contains("sample-pass-1"))

        // Editing metadata keeps the password and its date.
        clock.advance(60)
        var edited = saved
        edited.notes = "changed"
        let kept = try store.save(edited)
        #expect(kept.hasPassword && kept.passwordChangedAt == saved.passwordChangedAt && kept.updatedAt == clock.now)
        #expect(kept.createdAt == saved.createdAt)
        #expect(try store.password(for: saved.id) == "sample-pass-1")

        // A new password moves the date.
        clock.advance(60)
        let changed = try store.save(kept, password: .set("sample-pass-2"))
        #expect(changed.passwordChangedAt == clock.now)
        #expect(try store.password(for: saved.id) == "sample-pass-2")

        // Removing the password deletes its item.
        let removed = try store.save(changed, password: .remove)
        #expect(!removed.hasPassword && removed.passwordChangedAt == nil)
        #expect(try store.password(for: saved.id) == nil)

        // Delete removes the entry and its password item.
        _ = try store.save(removed, password: .set("sample-pass-3"))
        try store.delete(id: saved.id)
        #expect(try store.load().entries.contains { $0.id == saved.id } == false)
        #expect(secrets.accounts == [VaultStore.indexAccount])
    }

    @Test func callerCannotForgePasswordFlagOrDates() throws {
        let store = makeStore()
        var e = VaultEntry(title: "X", product: .other, hasPassword: true, passwordChangedAt: .distantPast)
        e = try store.save(e)
        #expect(!e.hasPassword && e.passwordChangedAt == nil)
        // An empty password is the same as removing it.
        let empty = try store.save(e, password: .set(""))
        #expect(!empty.hasPassword)
    }

    @Test func titleIsRequired() throws {
        let store = makeStore()
        #expect(throws: VaultError.missingTitle) { try store.save(VaultEntry(title: "   ", product: .other), password: .set("x")) }
    }

    @Test func unreadableIndexIsNeverOverwritten() throws {
        let secrets = InMemoryAccountSecretStore()
        try secrets.write("not json", account: VaultStore.indexAccount)
        let store = makeStore(secrets)
        #expect(throws: VaultError.unreadableIndex) { try store.load() }
        #expect(throws: VaultError.unreadableIndex) { try store.save(VaultEntry(title: "A", product: .other)) }
        #expect(try secrets.read(account: VaultStore.indexAccount) == "not json")
    }

    @Test func failedIndexWriteLeavesNoOrphanPassword() throws {
        let secrets = FailingSecrets()
        let store = VaultStore(secrets: secrets)
        _ = try store.load()
        secrets.failIndexWrites = true
        #expect(throws: KeychainError.self) { try store.save(VaultEntry(title: "New", product: .other), password: .set("sample")) }
        #expect(secrets.inner.accounts == [VaultStore.indexAccount])
    }
}

@Suite("Vault matching")
struct VaultMatchingTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ product: VaultProduct, _ env: VaultEnvironment, login: String?, kind: VaultLoginKind = .email,
                       password: Bool = true, age: TimeInterval = 0) -> VaultEntry {
        VaultEntry(title: "\(product.rawValue) \(env.rawValue)", product: product, environment: env, login: login, loginKind: kind,
                   hasPassword: password, createdAt: t0, updatedAt: t0.addingTimeInterval(-age))
    }

    @Test func environmentMapping() {
        #expect(WorkTrackEnvironment.demo.vaultEnvironment == .demo)
        #expect(TalarEnvironment.localEmulator.vaultEnvironment == .local)
        #expect(SafeBeautyEnvironment.staging.vaultEnvironment == .staging)
        #expect(VelroEnvironment.production.vaultEnvironment == .production)
        #expect(VaultSignInForm.velro(.production).needsPassword == false)
        #expect(VaultSignInForm.safeBeauty(.production).loginKind == .phone)
    }

    @Test func candidatesMatchProductAndEnvironmentBestFirst() {
        let prod = entry(.talar, .production, login: "a@example.com")
        let anyEnv = entry(.talar, .any, login: "b@example.com")
        let olderProd = entry(.talar, .production, login: "c@example.com", age: 100)
        let partial = entry(.talar, .production, login: "d@example.com", password: false)
        let demo = entry(.talar, .demo, login: "e@example.com")
        let other = entry(.worktrack, .production, login: "f@example.com")
        let template = entry(.talar, .production, login: nil, password: false)
        let all = [anyEnv, demo, partial, olderProd, other, template, prod]

        let result = VaultMatcher.candidates(all, for: .talar(.production))
        #expect(result.map(\.id) == [prod.id, olderProd.id, partial.id, anyEnv.id])
        #expect(VaultMatcher.candidates(all, for: .talar(.demo)).map(\.id) == [demo.id, anyEnv.id])
        #expect(VaultMatcher.candidates(all, for: .talar(.localEmulator)).map(\.id) == [anyEnv.id])
    }

    @Test func phoneFormsAreNotOfferedEmails() {
        let phone = entry(.safeBeauty, .production, login: "0700000000", kind: .phone)
        let email = entry(.safeBeauty, .production, login: "x@example.com", kind: .email)
        #expect(VaultMatcher.candidates([phone, email], for: .safeBeauty(.production)).map(\.id) == [phone.id])
        // VELRO needs no password, so a phone without one still fills the form.
        let velro = entry(.velro, .production, login: "+93700000000", kind: .phone, password: false)
        #expect(VaultMatcher.candidates([velro], for: .velro(.production)).map(\.id) == [velro.id])
    }

    @Test func storedCheckNormalisesLogins() {
        let entries = [entry(.safeBeauty, .production, login: "0700 123 456", kind: .phone),
                       entry(.worktrack, .production, login: "Owner@Example.com")]
        #expect(VaultMatcher.isStored(entries, form: .safeBeauty(.production), login: "+93700123456"))
        #expect(VaultMatcher.isStored(entries, form: .safeBeauty(.production), login: "700123456"))
        #expect(VaultMatcher.isStored(entries, form: .safeBeauty(.production), login: "0093700123456"))
        #expect(!VaultMatcher.isStored(entries, form: .safeBeauty(.staging), login: "0700123456"))
        #expect(VaultMatcher.isStored(entries, form: .worktrack(.production), login: " owner@example.COM "))
        #expect(!VaultMatcher.isStored(entries, form: .worktrack(.demo), login: "owner@example.com"))
        // Same login without a password isn't "stored" for a password form.
        let noPass = [entry(.talar, .production, login: "a@example.com", password: false)]
        #expect(!VaultMatcher.isStored(noPass, form: .talar(.production), login: "a@example.com"))
    }

    @Test func saveFillsTheTemplateOrTheSameLoginBeforeAddingNew() {
        let template = entry(.worktrack, .production, login: nil, password: false)
        let sameLogin = entry(.talar, .production, login: "a@example.com", password: false)

        let fromTemplate = VaultMatcher.entryToSave([template], form: .worktrack(.production), login: " v@example.com ")
        #expect(fromTemplate.id == template.id && fromTemplate.login == "v@example.com")

        let fromSame = VaultMatcher.entryToSave([sameLogin, entry(.talar, .production, login: nil, password: false)],
                                                form: .talar(.production), login: "A@example.com")
        #expect(fromSame.id == sameLogin.id)

        let fresh = VaultMatcher.entryToSave([template], form: .worktrack(.demo), login: "v@example.com")
        #expect(fresh.id != template.id && fresh.environment == .demo && fresh.product == .worktrack && fresh.login == "v@example.com")
    }

    @Test func groupsFollowProductOrderWithProductionFirst() {
        let entries = [entry(.github, .any, login: "x"), entry(.talar, .demo, login: "y"), entry(.talar, .production, login: "z")]
        let groups = vaultGroups(entries)
        #expect(groups.map(\.product) == [.talar, .github])
        #expect(groups[0].entries.map(\.environment) == [.production, .demo])
    }

    @Test func searchCoversMetadataOnly() {
        let e = VaultEntry(title: "Talar admin", product: .talar, url: URL(string: "https://talar-af-prod.web.app/admin"),
                           login: "owner@example.com", notes: "platform admin")
        #expect(e.matches(search: "talar-af"))
        #expect(e.matches(search: "OWNER"))
        #expect(e.matches(search: "platform"))
        #expect(!e.matches(search: "zzz"))
        #expect(e.matches(search: "  "))
    }
}

/// SplitMix64: deterministic generator for the password tests.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Vault password generator")
struct PasswordGeneratorTests {
    @Test func holdsEveryClassAndLength() {
        var rng = SeededGenerator(state: 7)
        for length in [12, 20, 64] {
            let p = PasswordGenerator.generate(.init(length: length), using: &rng)
            #expect(p.count == length)
            #expect(p.contains { $0.isLowercase } && p.contains { $0.isUppercase } && p.contains { $0.isNumber })
            #expect(p.contains { PasswordGenerator.symbolSet.contains($0) })
            #expect(!p.contains { PasswordGenerator.ambiguous.contains($0) })
        }
    }

    @Test func respectsOptionsAndClampsLength() {
        var rng = SeededGenerator(state: 42)
        let p = PasswordGenerator.generate(.init(length: 3, digits: false, symbols: false), using: &rng)
        #expect(p.count == PasswordGenerator.Options.lengthRange.lowerBound)
        #expect(p.allSatisfy { $0.isLetter })
        #expect(PasswordGenerator.generate(.init(length: 500)).count == 64)
    }

    @Test func systemGeneratorDoesNotRepeat() {
        let a = Set((0..<50).map { _ in PasswordGenerator.generate() })
        #expect(a.count == 50)
    }
}

@Suite("Vault unlock window")
struct VaultUnlockWindowTests {
    @Test func locksAfterTwoMinutesOrWhenAsked() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        var w = VaultUnlockWindow()
        #expect(!w.isUnlocked(at: t))
        w.unlock(at: t)
        #expect(w.isUnlocked(at: t.addingTimeInterval(119)))
        #expect(w.remaining(at: t.addingTimeInterval(60)) == 60)
        #expect(!w.isUnlocked(at: t.addingTimeInterval(120)))
        #expect(w.remaining(at: t.addingTimeInterval(500)) == 0)
        w.unlock(at: t)
        w.lock()
        #expect(!w.isUnlocked(at: t))
    }
}

@MainActor
private final class FakePasteboard: VaultPasteboard {
    var changeCount = 0
    var value: String?
    var readable = true
    var lastConcealedExpiry: TimeInterval?
    func writeConcealed(_ value: String, expiresAfter: TimeInterval) { changeCount += 1; self.value = value; lastConcealedExpiry = expiresAfter }
    func currentString() -> String? { readable ? value : nil }
    func clear() { changeCount += 1; value = nil }
    func ownerCopies(_ s: String) { changeCount += 1; value = s }
}

@Suite("Vault clipboard")
@MainActor
struct ClipboardGuardTests {
    @Test func clearsOnlyIfStillTheSameValue() {
        let pb = FakePasteboard()
        let guardian = ClipboardGuard(pasteboard: pb, sleep: { _ in await Task.yield() })
        let token = guardian.copy("sample-secret")
        #expect(pb.value == "sample-secret" && pb.lastConcealedExpiry == 30)
        #expect(guardian.clearIfUnchanged(token))
        #expect(pb.value == nil)

        // The owner copied something else since: leave it alone.
        let token2 = guardian.copy("sample-secret")
        pb.ownerCopies("my note")
        #expect(!guardian.clearIfUnchanged(token2))
        #expect(pb.value == "my note")
    }

    @Test func sameChangeCountButDifferentTextIsLeftAlone() {
        let pb = FakePasteboard()
        let guardian = ClipboardGuard(pasteboard: pb, sleep: { _ in })
        let token = guardian.copy("a")
        pb.value = "b"   // a writer that didn't bump changeCount
        #expect(!guardian.clearIfUnchanged(token))
        // When the text can't be read (iOS), the change count alone decides.
        pb.value = "a"; pb.readable = false
        #expect(guardian.clearIfUnchanged(token))
    }

    @Test func scheduledClearRunsAfterTheDelay() async {
        let pb = FakePasteboard()
        let guardian = ClipboardGuard(pasteboard: pb, sleep: { _ in })
        guardian.copy("sample-secret", clearAfter: 30)
        await guardian.waitForPendingClear()
        #expect(pb.value == nil)
    }

    @Test func aNewCopyReplacesThePendingClear() async {
        let pb = FakePasteboard()
        let guardian = ClipboardGuard(pasteboard: pb, sleep: { _ in try? await Task.sleep(for: .milliseconds(20)) })
        guardian.copy("first")
        guardian.copy("second")
        await guardian.waitForPendingClear()
        #expect(pb.value == nil)
        #expect(pb.changeCount == 3)   // two writes, one clear: the first copy's clear was cancelled
    }
}
