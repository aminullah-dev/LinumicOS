import CryptoKit
import Foundation

// MARK: - Password generator

/// Random passwords for the Vault editor. `SystemRandomNumberGenerator` is cryptographically secure on Apple
/// platforms; tests pass a seeded generator.
public enum PasswordGenerator {
    public struct Options: Sendable, Equatable {
        public var length: Int
        public var digits: Bool
        public var symbols: Bool
        /// Leaves out characters that are easy to misread when typing by hand: 0 O o 1 l I |.
        public var avoidAmbiguous: Bool

        public static let lengthRange = 12...64

        public init(length: Int = 20, digits: Bool = true, symbols: Bool = true, avoidAmbiguous: Bool = true) {
            self.length = length
            self.digits = digits
            self.symbols = symbols
            self.avoidAmbiguous = avoidAmbiguous
        }
    }

    static let ambiguous = Set("0Oo1lI|")
    static let lower = "abcdefghijklmnopqrstuvwxyz"
    static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let digitSet = "0123456789"
    // No quotes, backslash or spaces: they break pasting into shells and some web forms.
    static let symbolSet = "!#$%&*+-=?@^_~.:;"

    /// The character classes in use; the password holds at least one of each.
    static func classes(_ o: Options) -> [[Character]] {
        var sets = [lower, upper]
        if o.digits { sets.append(digitSet) }
        if o.symbols { sets.append(symbolSet) }
        return sets.map { Array($0).filter { !o.avoidAmbiguous || !ambiguous.contains($0) } }
    }

    public static func generate(_ options: Options = Options()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(options, using: &rng)
    }

    public static func generate<R: RandomNumberGenerator>(_ options: Options, using rng: inout R) -> String {
        let length = min(max(options.length, Options.lengthRange.lowerBound), Options.lengthRange.upperBound)
        let sets = classes(options)
        let all = sets.flatMap { $0 }
        var chars = sets.map { $0.randomElement(using: &rng)! }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }
}

// MARK: - Unlock window

/// How long the Vault stays unlocked after Touch ID or the device password: a short window, then it locks itself.
public struct VaultUnlockWindow: Sendable, Equatable {
    public static let defaultDuration: TimeInterval = 120
    public let duration: TimeInterval
    public private(set) var unlockedUntil: Date?

    public init(duration: TimeInterval = VaultUnlockWindow.defaultDuration) {
        self.duration = duration
    }

    public mutating func unlock(at now: Date) { unlockedUntil = now.addingTimeInterval(duration) }
    public mutating func lock() { unlockedUntil = nil }
    public func isUnlocked(at now: Date) -> Bool { unlockedUntil.map { now < $0 } ?? false }
    /// Whole seconds left, 0 when locked.
    public func remaining(at now: Date) -> Int {
        guard let until = unlockedUntil, now < until else { return 0 }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }
}

// MARK: - Clipboard

/// The system pasteboard, behind a protocol so the clearing rule can be tested.
@MainActor
public protocol VaultPasteboard: AnyObject {
    /// Increases every time anyone writes to the pasteboard.
    var changeCount: Int { get }
    /// Writes the value marked concealed and transient, so clipboard managers skip it.
    func writeConcealed(_ value: String, expiresAfter: TimeInterval)
    /// The current text, or nil when it can't be read without side effects (iOS shows a paste notice).
    func currentString() -> String?
    func clear()
}

/// Copies Vault values and clears them again after 30 seconds, but only if the pasteboard still holds what the
/// Vault put there: if the owner has copied something else since, that is left alone. Only a SHA-256 of the value
/// is kept for the check, never the value.
@MainActor
public final class ClipboardGuard {
    public static let clearAfter: TimeInterval = 30

    public struct Token: Equatable, Sendable {
        public let changeCount: Int
        let digest: Data
    }

    private let pasteboard: VaultPasteboard
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pending: Task<Void, Never>?

    public init(pasteboard: VaultPasteboard,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.pasteboard = pasteboard
        self.sleep = sleep
    }

    /// Copies the value and schedules the clear. Returns the token the clear checks against.
    @discardableResult
    public func copy(_ value: String, clearAfter delay: TimeInterval = ClipboardGuard.clearAfter) -> Token {
        pasteboard.writeConcealed(value, expiresAfter: delay)
        let token = Token(changeCount: pasteboard.changeCount, digest: Self.digest(value))
        pending?.cancel()
        let sleep = sleep
        pending = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.clearIfUnchanged(token)
        }
        return token
    }

    /// Clears the pasteboard if nothing was copied since `token` and it still holds the same value.
    @discardableResult
    public func clearIfUnchanged(_ token: Token) -> Bool {
        guard pasteboard.changeCount == token.changeCount else { return false }
        if let current = pasteboard.currentString(), Self.digest(current) != token.digest { return false }
        pasteboard.clear()
        return true
    }

    /// Waits for the scheduled clear (tests).
    public func waitForPendingClear() async { await pending?.value }

    static func digest(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
}
