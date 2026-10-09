import Foundation

// MARK: - Website messages (پیام‌های سایت)
//
// Contact-form entries from linumic.com. The site is WordPress with SureForms 2.12.8; the form's notification email
// does not reach the owner (checked 2026-10-09), so the app reads the entries itself.
//
// Where the entries come from (cited, not guessed):
// - SureForms' own admin routes (`GET /wp-json/sureforms/v1/entries/list`, `.../entry/{id}/details`,
//   sureforms 2.12.8 `inc/rest-api.php`, `get_endpoints()` and `get_entries_list()`) require an `X-WP-Nonce` checked
//   with `wp_verify_nonce(..., 'wp_rest')`. A nonce belongs to a browser login session, so these routes can't be used
//   with an application password. They are not used.
// - SureForms registers WordPress Abilities (WP 6.9+): `sureforms/list-entries` (`inc/abilities/entries/list-entries.php`)
//   and `sureforms/bulk-get-entries` (`inc/abilities/entries/bulk-get-entries.php`, field parsing in
//   `entry-parser.php`), both `readonly`, capability `manage_options`, `show_in_rest: true`
//   (`inc/abilities/abstract-ability.php`). They exist only while SureForms → Settings → "Enable Abilities"
//   (`srfm_abilities_api`) is on (`inc/abilities/abilities-registrar.php`).
// - WordPress core runs them at `/wp-json/wp-abilities/v1/abilities/{name}/run`; a read-only ability must be called
//   with GET and its input as the `input` query parameter, and the response is the ability's output as is
//   (wordpress-develop 6.9 `src/wp-includes/rest-api/endpoints/class-wp-rest-abilities-v1-run-controller.php`).
// - Authentication: an application password over HTTPS Basic auth (WordPress core; linumic.com's public `/wp-json/`
//   index lists the `wp-abilities/v1` namespace and `application-passwords`, read without credentials 2026-10-09).
//
// Nothing here writes to WordPress. The customer messages are kept in memory only; on this device the app stores the
// ids of entries the owner has seen and been notified about, and when it last read (`site-messages.json`).

public enum SiteMessagesSource {
    public static let site = URL(string: "https://linumic.com")!
    /// The contact form on linumic.com (SureForms "Simple Contact Form": first name, last name, email, message).
    public static let contactFormID = 1752
    public static let contactFormTitle = "Simple Contact Form"
    public static let pluginVersion = "2.12.8"
    /// The site's time zone, in which SureForms stores `created_at` (`current_time('mysql')`, `inc/form-submit.php`).
    /// Source: linumic.com `/wp-json/` `timezone_string` "Asia/Kabul", `gmt_offset` 4.5, read 2026-10-09.
    public static let siteTimeZone = TimeZone(identifier: "Asia/Kabul")!
    public static let listAbility = "sureforms/list-entries"
    public static let detailsAbility = "sureforms/bulk-get-entries"
    /// How many of the newest entries one refresh reads (bulk-get-entries allows up to 50).
    public static let pageSize = 20
    public static let detailsLimit = 50

    /// What a line's source says.
    public static var sourceText: String { L("linumic.com, SureForms entries through the WordPress Abilities API") }

    /// wp-admin → SureForms → Entries (`admin.php?page=sureforms_entries`, sureforms.php `SRFM_ENTRIES`).
    public static func entriesAdminURL(site: URL = site) -> URL {
        URL(string: site.absoluteString.trimmingSlash + "/wp-admin/admin.php?page=sureforms_entries")!
    }

    /// One entry in wp-admin. The Entries screen routes `#/entry/{id}` (SureForms `assets/build/entries.js`).
    public static func entryAdminURL(_ id: Int, site: URL = site) -> URL {
        URL(string: entriesAdminURL(site: site).absoluteString + "#/entry/\(id)")!
    }

    /// Users → Profile → Application Passwords.
    public static func applicationPasswordsURL(site: URL = site) -> URL {
        URL(string: site.absoluteString.trimmingSlash + "/wp-admin/profile.php#application-passwords-section")!
    }

    /// SureForms → Settings, where "Enable Abilities" lives.
    public static func sureFormsSettingsURL(site: URL = site) -> URL {
        URL(string: site.absoluteString.trimmingSlash + "/wp-admin/admin.php?page=sureforms_form_settings")!
    }
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

// MARK: - Credential

/// A WordPress application password for one user, stored as JSON in the Keychain (`wordpress.linumic.apppassword`).
/// Its description never contains the password, so it can't end up in a log by accident.
public struct WordPressAppPassword: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String

    /// WordPress ignores everything but letters and digits in an application password (the spaces only group it for
    /// reading; `wp_authenticate_application_password()` strips the rest), so the same is done here.
    public init(username: String, password: String) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = String(password.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public var isComplete: Bool { !username.isEmpty && !password.isEmpty }

    /// `Basic base64(username:password)`.
    public var authorizationHeader: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    public var description: String { "WordPressAppPassword(username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }

    public func encoded() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

    public static func decode(_ json: String) -> WordPressAppPassword? {
        try? JSONDecoder().decode(WordPressAppPassword.self, from: Data(json.utf8))
    }
}

// MARK: - Response shapes (SureForms ability outputs)

/// One row of `sureforms/list-entries` (`get_output_schema()`: id, form_id, form_title, status, created_at).
public struct SiteEntrySummary: Hashable, Sendable, Identifiable {
    public var id: Int
    public var formID: Int
    public var formTitle: String
    /// "read", "unread" or "trash" (SureForms entries table).
    public var status: String
    /// `created_at` as stored: "yyyy-MM-dd HH:mm:ss" in the site's time zone.
    public var createdAt: String
}

public struct SiteEntryList: Hashable, Sendable {
    public var entries: [SiteEntrySummary]
    public var total: Int
    public var totalPages: Int
    public var currentPage: Int
    public var perPage: Int
}

/// One submitted field, as `Entry_Parser::parse_entry()` returns it: decoded label, value, block name
/// ("srfm-input", "srfm-email", "srfm-textarea", …).
public struct SiteEntryField: Hashable, Sendable {
    public var label: String
    public var value: String
    public var blockName: String

    public init(label: String, value: String, blockName: String) {
        self.label = label
        self.value = value
        self.blockName = blockName
    }
}

/// One entry of `sureforms/bulk-get-entries`.
public struct SiteEntryDetail: Hashable, Sendable, Identifiable {
    public var id: Int
    public var formID: Int
    public var formName: String
    public var status: String
    public var createdAt: String
    public var fields: [SiteEntryField]
}

/// A contact-form message, ready to show.
public struct SiteMessage: Hashable, Sendable, Identifiable {
    public var id: Int
    public var formID: Int
    public var formName: String
    /// SureForms' own status ("read"/"unread"): whether someone opened it in wp-admin. Not the app's "seen".
    public var status: String
    /// As stored by WordPress, in the site's time zone.
    public var createdAtText: String
    public var createdAt: Date?
    public var name: String?
    public var email: String?
    public var message: String

    public init(id: Int, formID: Int, formName: String, status: String, createdAtText: String, createdAt: Date?,
                name: String?, email: String?, message: String) {
        self.id = id
        self.formID = formID
        self.formName = formName
        self.status = status
        self.createdAtText = createdAtText
        self.createdAt = createdAt
        self.name = name
        self.email = email
        self.message = message
    }

    /// The sender's name, else the email, else "Unknown sender".
    public var sender: String { name ?? email ?? L("Unknown sender") }
    public var excerpt: String { SiteMessageText.excerpt(message) }
    public var isUnreadInWordPress: Bool { status == "unread" }
    public func adminURL(site: URL = SiteMessagesSource.site) -> URL { SiteMessagesSource.entryAdminURL(id, site: site) }
    public var replyURL: URL? { email.flatMap { SiteMessageText.replyURL(to: $0) } }
}

// MARK: - Errors

public enum SiteMessagesError: Error, LocalizedError, Equatable, Sendable {
    /// No application password stored.
    case notConfigured
    /// 401 from WordPress: the application password was refused, or the request reached WordPress without a user
    /// (some hosts drop the Authorization header). `code` is WordPress's error code.
    case unauthorized(code: String)
    /// 403: the user is signed in but may not run the ability (it needs an Administrator, `manage_options`).
    case forbidden(code: String)
    /// 404 `rest_ability_not_found`: SureForms → Settings → "Enable Abilities" is off (nothing is registered then).
    case abilitiesOff
    /// 404 `rest_no_route`: the site has no Abilities API (WordPress older than 6.9).
    case noAbilitiesAPI
    case http(status: Int, code: String?)
    case badResponse
    /// The site address isn't HTTPS; credentials are never sent over plain HTTP.
    case insecureSite

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            L("Not connected. Add a WordPress application password in Settings → Integrations → Website messages.")
        case .unauthorized(let code) where code == "rest_ability_cannot_execute" || code == "rest_not_logged_in":
            L("WordPress saw no signed-in user (401). Check the username and application password; if they are right, the host may be dropping the Authorization header.")
        case .unauthorized(let code):
            LF("WordPress refused the application password (401, %@). Create a new one and save it again.", code)
        case .forbidden(let code):
            LF("This WordPress user may not read form entries (403, %@). Use an Administrator's application password.", code)
        case .abilitiesOff:
            L("SureForms abilities are off. In wp-admin open SureForms → Settings and turn on \u{2068}Enable Abilities\u{2069}.")
        case .noAbilitiesAPI:
            L("This WordPress has no Abilities API (it needs WordPress 6.9 or later).")
        case .http(let status, let code):
            code.map { LF("WordPress returned HTTP %d (%@).", status, $0) } ?? LF("WordPress returned HTTP %d.", status)
        case .badResponse:
            L("WordPress answered with something that isn't a SureForms entry list.")
        case .insecureSite:
            L("The site address must use HTTPS.")
        }
    }
}

// MARK: - Parsing

public enum SiteMessagesParser {
    /// `sureforms/list-entries` output.
    public static func list(_ data: Data) throws -> SiteEntryList {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["entries"] as? [[String: Any]] else { throw SiteMessagesError.badResponse }
        let entries = rows.compactMap { row -> SiteEntrySummary? in
            guard let id = int(row["id"]), id > 0 else { return nil }
            return SiteEntrySummary(id: id, formID: int(row["form_id"]) ?? 0, formTitle: string(row["form_title"]) ?? "",
                                    status: string(row["status"]) ?? "", createdAt: string(row["created_at"]) ?? "")
        }
        return SiteEntryList(entries: entries, total: int(root["total"]) ?? entries.count, totalPages: int(root["total_pages"]) ?? 1,
                             currentPage: int(root["current_page"]) ?? 1, perPage: int(root["per_page"]) ?? entries.count)
    }

    /// `sureforms/bulk-get-entries` output (`entries`, plus `errors` for ids not found, which are skipped).
    public static func details(_ data: Data) throws -> [SiteEntryDetail] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["entries"] as? [[String: Any]] else { throw SiteMessagesError.badResponse }
        return rows.compactMap { row in
            guard let id = int(row["id"]), id > 0 else { return nil }
            let fields = (row["form_data"] as? [[String: Any]] ?? []).map { f in
                SiteEntryField(label: string(f["label"]) ?? "", value: text(f["value"]), blockName: string(f["block_name"]) ?? "")
            }
            return SiteEntryDetail(id: id, formID: int(row["form_id"]) ?? 0, formName: string(row["form_name"]) ?? "",
                                   status: string(row["status"]) ?? "", createdAt: string(row["created_at"]) ?? "", fields: fields)
        }
    }

    /// A WordPress REST error (`{"code": …, "message": …, "data": {"status": …}}`) mapped to what the owner can do.
    public static func error(status: Int, data: Data) -> SiteMessagesError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = root.flatMap { string($0["code"]) }
        switch (status, code) {
        case (404, "rest_ability_not_found"?): return .abilitiesOff
        case (404, "rest_no_route"?): return .noAbilitiesAPI
        case (401, _): return .unauthorized(code: code ?? "unknown")
        case (403, _): return .forbidden(code: code ?? "unknown")
        default: return .http(status: status, code: code)
        }
    }

    /// The message a person wrote, from the submitted fields. Labels are whatever the form says, so they are matched
    /// loosely (English and Dari): first/last name, name, email, message.
    public static func message(_ d: SiteEntryDetail, timeZone: TimeZone = SiteMessagesSource.siteTimeZone) -> SiteMessage {
        func has(_ f: SiteEntryField, _ words: [String]) -> Bool {
            let l = f.label.lowercased()
            return words.contains { l.contains($0) }
        }
        let filled = d.fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let emailField = filled.first { $0.blockName == "srfm-email" && $0.value.contains("@") }
            ?? filled.first { has($0, ["email", "e-mail", "ایمیل"]) && $0.value.contains("@") }
        let last = filled.first { has($0, ["last", "surname", "family", "تخلص", "خانوادگی"]) }
        let first = filled.first { $0 != last && has($0, ["first", "given", "نام"]) }
        let plainName = filled.first { $0 != first && $0 != last && $0 != emailField && has($0, ["name", "نام"]) }
        let messageField = filled.first { $0.blockName == "srfm-textarea" }
            ?? filled.first { has($0, ["message", "comment", "enquiry", "inquiry", "پیام"]) }
            ?? filled.filter { $0 != first && $0 != last && $0 != plainName && $0 != emailField }.max { $0.value.count < $1.value.count }
        let nameParts = [first, last].compactMap { $0?.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let name = nameParts.isEmpty ? plainName?.value.trimmingCharacters(in: .whitespacesAndNewlines) : nameParts.joined(separator: " ")
        return SiteMessage(id: d.id, formID: d.formID, formName: d.formName, status: d.status, createdAtText: d.createdAt,
                           createdAt: siteDate(d.createdAt, timeZone: timeZone), name: name.flatMap { $0.isEmpty ? nil : $0 },
                           email: emailField?.value.trimmingCharacters(in: .whitespacesAndNewlines),
                           message: messageField?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// "yyyy-MM-dd HH:mm:ss" in the site's time zone.
    public static func siteDate(_ s: String, timeZone: TimeZone = SiteMessagesSource.siteTimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    /// A field value as text: strings as they are, lists joined, numbers written out.
    static func text(_ v: Any?) -> String {
        switch v {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        case let a as [Any]: a.map { text($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case let d as [String: Any]: d.keys.sorted().map { text(d[$0]) }.filter { !$0.isEmpty }.joined(separator: ", ")
        default: ""
        }
    }
}

// MARK: - Client (GET only)

/// One reading of the newest entries.
public struct SiteMessagesReading: Equatable, Sendable {
    /// Newest first.
    public var messages: [SiteMessage]
    /// All entries outside the trash, as SureForms counts them.
    public var total: Int
    public var readAt: Date

    public init(messages: [SiteMessage], total: Int, readAt: Date) {
        self.messages = messages
        self.total = total
        self.readAt = readAt
    }
}

/// Reads entries through the two read-only SureForms abilities. It has GET requests only; there is no call that
/// marks, edits or deletes an entry.
public struct SiteMessagesClient: Sendable {
    public let site: URL
    public let credential: WordPressAppPassword
    let transport: HTTPTransport

    public init(site: URL = SiteMessagesSource.site, credential: WordPressAppPassword, transport: HTTPTransport) {
        self.site = site
        self.credential = credential
        self.transport = transport
    }

    /// `/wp-json/wp-abilities/v1/abilities/{ability}/run?input[key]=value…`, brackets percent-encoded.
    public static func runURL(site: URL, ability: String, input: [(String, String)]) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let query = input.map { "\(enc("input[\($0.0)]"))=\(enc($0.1))" }.joined(separator: "&")
        let base = site.absoluteString.trimmingSlash + "/wp-json/wp-abilities/v1/abilities/\(ability)/run"
        return URL(string: query.isEmpty ? base : "\(base)?\(query)")!
    }

    func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.httpMethod = "GET"
        r.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public func listRequest(perPage: Int = SiteMessagesSource.pageSize) -> URLRequest {
        request(Self.runURL(site: site, ability: SiteMessagesSource.listAbility, input: [
            ("status", "all"), ("orderby", "created_at"), ("order", "DESC"), ("per_page", String(perPage)), ("page", "1"),
        ]))
    }

    public func detailsRequest(ids: [Int]) -> URLRequest {
        request(Self.runURL(site: site, ability: SiteMessagesSource.detailsAbility,
                            input: ids.prefix(SiteMessagesSource.detailsLimit).map { ("entry_ids][", String($0)) }))
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SiteMessagesParser.error(status: response.statusCode, data: data)
        }
        return data
    }

    /// The newest entries with their fields: one list call, then one details call for those ids.
    public func fetchRecent(now: Date = .now) async throws -> SiteMessagesReading {
        guard site.scheme == "https" else { throw SiteMessagesError.insecureSite }
        guard credential.isComplete else { throw SiteMessagesError.notConfigured }
        let list = try SiteMessagesParser.list(try await send(listRequest()))
        let ids = list.entries.filter { $0.status != "trash" }.map(\.id)
        guard !ids.isEmpty else { return SiteMessagesReading(messages: [], total: list.total, readAt: now) }
        let details = try SiteMessagesParser.details(try await send(detailsRequest(ids: ids)))
        let byID = Dictionary(details.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Keep the list's order (newest first); an entry deleted between the two calls is simply left out.
        let messages = ids.compactMap { byID[$0] }.map { SiteMessagesParser.message($0) }
        return SiteMessagesReading(messages: messages, total: list.total, readAt: now)
    }
}

// MARK: - Text

public enum SiteMessageText {
    public static let excerptLength = 140

    /// The first `limit` characters with runs of white space (line breaks too) folded to one space, and "…" when cut.
    public static func excerpt(_ text: String, limit: Int = excerptLength) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard folded.count > limit else { return folded }
        let cut = folded.prefix(limit)
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A plain address only: no spaces, no extra headers ("?cc=", "&bcc="), one "@", a dotted domain.
    public static func isPlainEmail(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9.!$'*+=^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#,
                options: .regularExpression) != nil
    }

    /// `mailto:` with a subject only, for a plain address; nil otherwise (so a crafted address can't add recipients).
    public static func replyURL(to email: String, subject: String = L("Re: your message to Linumic")) -> URL? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlainEmail(address) else { return nil }
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return c.url
    }
}

// MARK: - Seen and notified (on this device, ids only)

public struct SiteMessagesState: Codable, Equatable, Sendable {
    public static let keepIDs = 500

    /// Entries the owner marked as seen in this app.
    public var seenIDs: Set<Int>
    /// Entries a notification was already posted for.
    public var notifiedIDs: Set<Int>
    /// The last successful reading.
    public var lastReadAt: Date?
    /// How many were new at that reading (for the dashboard when the app has just opened, before the next read).
    public var lastNewCount: Int?

    public init(seenIDs: Set<Int> = [], notifiedIDs: Set<Int> = [], lastReadAt: Date? = nil, lastNewCount: Int? = nil) {
        self.seenIDs = seenIDs
        self.notifiedIDs = notifiedIDs
        self.lastReadAt = lastReadAt
        self.lastNewCount = lastNewCount
    }

    public mutating func markSeen(_ ids: some Sequence<Int>) {
        seenIDs.formUnion(ids)
        notifiedIDs.formUnion(ids)
        trim()
    }

    public mutating func markUnseen(_ id: Int) { seenIDs.remove(id) }

    /// Records a reading and returns the messages to notify about: new (not seen) and not notified before.
    /// Entries are never notified twice, and seen ones never.
    public mutating func record(_ reading: SiteMessagesReading) -> [SiteMessage] {
        let new = SiteMessagesRules.new(reading.messages, seen: seenIDs)
        let toNotify = new.filter { !notifiedIDs.contains($0.id) }
        notifiedIDs.formUnion(toNotify.map(\.id))
        lastReadAt = reading.readAt
        lastNewCount = new.count
        trim()
        return toNotify
    }

    /// Keeps the newest ids only (ids grow with time), so the file stays small.
    mutating func trim() {
        if seenIDs.count > Self.keepIDs { seenIDs = Set(seenIDs.sorted(by: >).prefix(Self.keepIDs)) }
        if notifiedIDs.count > Self.keepIDs { notifiedIDs = Set(notifiedIDs.sorted(by: >).prefix(Self.keepIDs)) }
    }
}

public enum SiteMessagesRules {
    /// Messages not marked seen, newest first.
    public static func new(_ messages: [SiteMessage], seen: Set<Int>) -> [SiteMessage] {
        messages.filter { !seen.contains($0.id) }.sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) }
    }
}

/// `site-messages.json` next to the inventory: ids and times only, never a name, address or message.
public struct SiteMessagesStateStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultFileURL() throws -> URL {
        try JSONFileInventoryStore.defaultFileURL().deletingLastPathComponent().appending(path: "site-messages.json")
    }

    public func load() -> SiteMessagesState {
        guard let data = try? Data(contentsOf: fileURL) else { return SiteMessagesState() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(SiteMessagesState.self, from: data)) ?? SiteMessagesState()
    }

    public func save(_ state: SiteMessagesState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(state).write(to: fileURL, options: .atomic)
    }
}

// MARK: - Notification wording

public enum SiteMessagesNotificationText {
    /// Title and body for new messages, or nil when there are none. Names only, never the email address.
    public static func content(_ new: [SiteMessage]) -> (title: String, body: String)? {
        guard let first = new.first else { return nil }
        if new.count == 1 {
            return (L("New message from linumic.com"), LF("%@: %@", first.sender, SiteMessageText.excerpt(first.message, limit: 100)))
        }
        let names = new.prefix(3).map(\.sender).joined(separator: ", ")
        let body = new.count > 3 ? LF("From %@ and %d more.", names, new.count - 3) : LF("From %@.", names)
        return (LF("%d new messages from linumic.com", new.count), body)
    }
}
