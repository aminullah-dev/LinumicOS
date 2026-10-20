import Foundation

// MARK: - Values with their source

/// A value on the Products page: read (with where from and when), read and there is none, or not read (with why).
/// Unknown is never shown as zero or as "none".
public enum Sourced<Value: Hashable & Sendable>: Hashable, Sendable {
    /// Read: the value, where it was read and when (nil only for a fact of record with no read time).
    case known(Value, source: String, readAt: Date?)
    /// Read, and there is none (no GitHub release, not in a store); the sentence says what was found and where.
    case none(String, source: String?, readAt: Date?)
    /// Not read; the sentence says why.
    case unknown(String)

    public var value: Value? { if case .known(let v, _, _) = self { v } else { nil } }
    public var isKnown: Bool { value != nil }
    public var isUnknown: Bool { if case .unknown = self { true } else { false } }

    public var source: String? {
        switch self {
        case .known(_, let s, _): s
        case .none(_, let s, _): s
        case .unknown: nil
        }
    }

    public var readAt: Date? {
        switch self {
        case .known(_, _, let t), .none(_, _, let t): t
        case .unknown: nil
        }
    }

    /// The sentence of a value that is none or unknown.
    public var reason: String? {
        switch self {
        case .known: nil
        case .none(let s, _, _), .unknown(let s): s
        }
    }
}

/// A version as one source states it: "1.4.0 (11)" with the day it was made, when the source says.
public struct VersionStamp: Hashable, Sendable {
    /// The version name, as written ("1.4.0", "v1.8.0", "salon-desktop"); nil when the source gives only a code.
    public var name: String?
    /// Build number or version code.
    public var code: String?
    /// When it was built, uploaded or published, when the source says; nil otherwise (Google Play gives no date).
    public var date: Date?
    /// What it is beside the number: a track ("production"), a phase ("Waiting for review"), a file name.
    public var detail: String?

    public init(name: String?, code: String? = nil, date: Date? = nil, detail: String? = nil) {
        self.name = name
        self.code = code
        self.date = date
        self.detail = detail
    }

    /// The name as a version number, or nil when it is not one (a tag like "android-app").
    public var semantic: SemanticVersion? { name.flatMap(SemanticVersion.init) }

    /// "1.4.0 (11)", "1.4.0", "(11)".
    public var label: String {
        switch (name, code) {
        case let (n?, c?): "\(n) (\(c))"
        case let (n?, nil): n
        case let (nil, c?): "(\(c))"
        case (nil, nil): "?"
        }
    }

    /// "1.4.0 (11) (2026-10-13)" with the day in UTC when known, as the level findings word it.
    public var labelWithDay: String {
        date.map { "\(label) (\(ProductDay.text($0)))" } ?? label
    }
}

/// Days as the level findings print them: ISO, UTC, so the sentence reads the same on every device.
public enum ProductDay {
    public static func text(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}

/// The newest commits on a repository's default branch, read once per refresh (`GET /repos/{r}/commits`). Only their
/// committer dates are kept: no message, author or e-mail.
public struct MainHistory: Codable, Hashable, Sendable {
    public var repo: String
    public var branch: String
    /// Committer dates, newest first, at most `pageSize`.
    public var commitDates: [Date]
    /// The newest commit, for the source line.
    public var newestSHA: String?
    /// True when the page held fewer than `pageSize` commits: it reaches the branch's first commit.
    public var isComplete: Bool
    public var readAt: Date

    public static let pageSize = 100

    public init(repo: String, branch: String, commitDates: [Date], newestSHA: String?, isComplete: Bool, readAt: Date) {
        self.repo = repo
        self.branch = branch
        self.commitDates = commitDates
        self.newestSHA = newestSHA
        self.isComplete = isComplete
        self.readAt = readAt
    }

    /// The newest commit's date.
    public var newest: Date? { commitDates.max() }

    /// Commits dated after `date`, and whether the true number may be higher (every commit on the page is after it and
    /// the page does not reach the first commit).
    public func commits(after date: Date) -> (count: Int, atLeast: Bool) {
        let count = commitDates.count { $0 > date }
        return (count, count == commitDates.count && !isComplete && !commitDates.isEmpty)
    }
}

/// The build of Linumic OS running on this device, from its own Info.plist.
public struct RunningBuild: Hashable, Sendable {
    public var platform: Platform
    public var version: String
    public var build: String?

    public init(platform: Platform, version: String, build: String?) {
        self.platform = platform
        self.version = version
        self.build = build
    }
}

/// Behind the default branch: by version, by commits and days, or both.
public struct BehindMain: Hashable, Sendable {
    /// Commits on the default branch dated after the build.
    public var commits: Int
    /// The true number may be higher (the page of 100 did not reach back to the build).
    public var atLeast: Bool
    /// Whole days from the build to the newest commit on the default branch.
    public var days: Int
    public var newestCommit: Date

    public init(commits: Int, atLeast: Bool, days: Int, newestCommit: Date) {
        self.commits = commits
        self.atLeast = atLeast
        self.days = days
        self.newestCommit = newestCommit
    }

    /// "23 commits", "at least 100 commits".
    public var commitsText: String {
        atLeast ? LF("at least %ld commits", commits) : LF("%ld commits", commits)
    }
}
