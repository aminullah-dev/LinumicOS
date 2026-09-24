import Foundation

/// Public, credential-free App Store status via Apple's lookup endpoint
/// (https://itunes.apple.com/lookup?bundleId=…). It shows only what's live to the public.
/// Review states and pending versions need App Store Connect, which isn't connected.
public struct AppStoreLookupClient: Sendable {
    public struct Result: Sendable, Equatable {
        public var trackName: String
        public var version: String
        public var currentVersionReleaseDate: Date?
        public var url: URL?
        public var seller: String?
        public var storefront: String
        public var averageUserRating: Double? = nil
        public var userRatingCount: Int? = nil
    }

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let trackName: String
            let version: String
            let currentVersionReleaseDate: Date?
            let trackViewUrl: String?
            let sellerName: String?
            let averageUserRatingForCurrentVersion: Double?
            let averageUserRating: Double?
            let userRatingCount: Int?
        }
        let resultCount: Int
        let results: [Item]
    }

    public static func lookupURL(bundleID: String, country: String) -> URL {
        var c = URLComponents(string: "https://itunes.apple.com/lookup")!
        c.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "country", value: country)]
        return c.url!
    }

    /// Returns nil when the app isn't publicly available in that storefront.
    public func lookup(bundleID: String, country: String) async throws -> Result? {
        var request = URLRequest(url: Self.lookupURL(bundleID: bundleID, country: country))
        request.httpMethod = "GET"
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw GitHubError.http(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let item = try decoder.decode(Response.self, from: data).results.first else { return nil }
        return Result(trackName: item.trackName, version: item.version, currentVersionReleaseDate: item.currentVersionReleaseDate,
                      url: item.trackViewUrl.flatMap(URL.init(string:)).map(Self.stripQuery), seller: item.sellerName, storefront: country,
                      averageUserRating: item.averageUserRating, userRatingCount: item.userRatingCount)
    }

    private static func stripQuery(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        return c?.url ?? url
    }
}

/// Refreshes public App Store data for every App Store listing that has a bundle ID. Read-only.
public enum StoreSync {
    public struct Report: Sendable, Equatable {
        public var updated: [String] = []
        public var notPublic: [String] = []
        public var failed: [String: String] = [:]
    }

    /// Storefront codes to try, in order. Some Linumic apps are live only in Afghanistan.
    public static let storefronts = ["us", "af"]

    /// Updates `productionVersion`, `appName`, `url`, `seller`, `storefront` and adds a dated
    /// App Store source. It never downgrades verification: an app missing from the public store
    /// may be pending review, so that's reported rather than written as a fact.
    public static func refreshAppStore(_ products: [Product], using client: AppStoreLookupClient, now: Date = .now) async -> ([Product], Report) {
        var result = products
        var report = Report()
        for (pi, product) in products.enumerated() {
            for (li, listing) in product.storeListings.enumerated() where listing.store == .appStore {
                guard let bundle = listing.appIdentifier else { continue }
                do {
                    var found: AppStoreLookupClient.Result?
                    for country in storefronts {
                        if let r = try await client.lookup(bundleID: bundle, country: country) { found = r; break }
                    }
                    guard let r = found else {
                        report.notPublic.append(bundle)
                        continue
                    }
                    var l = listing
                    // App Store Connect is the better source for versions (per platform, with review state).
                    // When it has spoken, the public lookup only adds the rating, so the two never flip-flop.
                    let fromConsole = l.verification.sources.contains { $0.reference.hasPrefix(StoreConsoleSync.ascReferencePrefix) }
                    l.appName = r.trackName
                    if !fromConsole { l.productionVersion = r.version }
                    l.url = r.url ?? l.url
                    l.seller = r.seller ?? l.seller
                    l.storefront = r.storefront.uppercased()
                    var insights = l.insights ?? StoreInsights()
                    insights.rating = r.averageUserRating
                    insights.ratingCount = r.userRatingCount
                    insights.ratingStorefront = r.storefront.uppercased()
                    insights.ratingObservedAt = now
                    l.insights = insights
                    let source = Source(kind: .appStore, reference: AppStoreLookupClient.lookupURL(bundleID: bundle, country: r.storefront).absoluteString,
                                        observedAt: now,
                                        detail: "Public version \(r.version)" + (r.currentVersionReleaseDate.map { ", released \($0.formatted(.iso8601.year().month().day()))" } ?? ""))
                    // Replace the previous automated lookup source and keep everything else, such as owner statements.
                    l.verification.sources.removeAll { $0.kind == .appStore && $0.reference.hasPrefix("https://itunes.apple.com/lookup") }
                    l.verification.sources.append(source)
                    l.verification.status = .verified
                    l.verification.verifiedAt = now
                    result[pi].storeListings[li] = l
                    report.updated.append(bundle)
                } catch {
                    report.failed[bundle] = error.localizedDescription
                }
            }
        }
        return (result, report)
    }
}
