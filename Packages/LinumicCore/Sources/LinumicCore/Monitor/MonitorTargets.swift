import Foundation

/// The products the Monitor groups its checks by.
public enum MonitorProduct: String, Codable, CaseIterable, Sendable, Identifiable {
    case velro, safeBeauty, workTrack, talar, website

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .velro: "VELRO"
        case .safeBeauty: "SafeBeauty"
        case .workTrack: "WorkTrack"
        case .talar: "Talar"
        case .website: "linumic.com"
        }
    }
}

/// How a health endpoint reports itself. Each shape is copied from the product's own source (cited on the target).
public enum MonitorHealthFormat: String, Codable, Sendable, Hashable {
    /// VELRO: `{"success":true,"data":{"status":"alive"}}` (/healthz) or `{"data":{"status":"ready","database":"ok"}}` (/readyz).
    case velroEnvelope
    /// WorkTrack: `{"data":{"status":"ok"}}`.
    case dataStatus
    /// Talar: `{"ok":true,"service":"talar-api","version":"1.0.0"}`.
    case okFlag
}

public enum MonitorCheckKind: Codable, Sendable, Hashable {
    /// A page: any 2xx or 3xx is up.
    case page
    /// A health endpoint: the status code and the parsed status must both be healthy.
    case health(MonitorHealthFormat, expected: String)
}

public enum MonitorEnvironment: String, Codable, Sendable, Hashable {
    case production, demo
}

/// One public, unauthenticated, read-only URL the Monitor fetches with a plain GET. No target needs a credential.
public struct MonitorTarget: Identifiable, Sendable, Hashable {
    public let id: String
    public let product: MonitorProduct
    /// English name; the app localizes it with `L(_:)`.
    public let name: String
    public let url: URL
    public let kind: MonitorCheckKind
    public let environment: MonitorEnvironment
    /// Where this URL comes from: `repository/path:line` in ~/Projects/Multiplatform (or ~/Projects/Web).
    public let source: String
    /// Slower than this (seconds) is "degraded". Cloud Functions get more room for a cold start.
    public let slowAfter: TimeInterval
    /// Read the caching headers of this page (linumic.com home).
    public let inspectsCache: Bool

    public init(id: String, product: MonitorProduct, name: String, url: String, kind: MonitorCheckKind = .page,
                environment: MonitorEnvironment = .production, source: String, slowAfter: TimeInterval = 3,
                inspectsCache: Bool = false) {
        self.id = id
        self.product = product
        self.name = name
        self.url = URL(string: url)!
        self.kind = kind
        self.environment = environment
        self.source = source
        self.slowAfter = slowAfter
        self.inspectsCache = inspectsCache
    }

    public var host: String { url.host() ?? url.absoluteString }
    public var isHealthEndpoint: Bool { if case .health = kind { true } else { false } }
}

/// A registrable domain whose registration expiry is read from public RDAP.
public struct MonitorDomain: Identifiable, Sendable, Hashable {
    public let name: String
    public let source: String
    public var id: String { name }

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }

    /// True when `host` is this domain or one of its subdomains.
    public func covers(host: String) -> Bool {
        let h = host.lowercased()
        return h == name || h.hasSuffix("." + name)
    }
}

/// Every target, derived from the product repositories on 2026-10-09 and probed once with curl the same day
/// (all answered 200; safebeauty.web.app's root answers 302 to /get, so /get is checked). Hosts on `web.app` and
/// `cloudfunctions.net` belong to Google: their certificates are read, their domains are not ours to renew.
public enum MonitorCatalog {
    public static let targets: [MonitorTarget] = [
        // MARK: VELRO
        // Velro/backend/ui/api/app.py:118 `@app.get("/healthz")` -> ok({"status": "alive"});
        // host from Velro/deploy/Caddyfile:6 `api.velro.linumic.com {`.
        MonitorTarget(id: "velro.api.live", product: .velro, name: "API liveness",
                      url: "https://api.velro.linumic.com/healthz", kind: .health(.velroEnvelope, expected: "alive"),
                      source: "Velro/backend/ui/api/app.py:118, Velro/deploy/Caddyfile:6"),
        // Velro/backend/ui/api/app.py:123 `@app.get("/readyz")` -> ok({"status": "ready", "database": "ok"}) after SELECT 1.
        MonitorTarget(id: "velro.api.ready", product: .velro, name: "API readiness (database)",
                      url: "https://api.velro.linumic.com/readyz", kind: .health(.velroEnvelope, expected: "ready"),
                      source: "Velro/backend/ui/api/app.py:123, Velro/deploy/Caddyfile:6"),
        // Velro/deploy/Caddyfile:24 `admin.velro.linumic.com {` (static admin panel).
        MonitorTarget(id: "velro.admin", product: .velro, name: "Admin panel",
                      url: "https://admin.velro.linumic.com/", source: "Velro/deploy/Caddyfile:24"),

        // MARK: SafeBeauty
        // Safe beauty/.firebaserc:11 hosting target app -> site "safebeauty"; Safe beauty/firebase.json:26 redirects / to /get.
        MonitorTarget(id: "safebeauty.app", product: .safeBeauty, name: "Download page",
                      url: "https://safebeauty.web.app/get", source: "Safe beauty/.firebaserc:11, Safe beauty/firebase.json:26"),
        // Safe beauty/.firebaserc:14 hosting target admin -> site "safebeauty-admin".
        MonitorTarget(id: "safebeauty.admin", product: .safeBeauty, name: "Admin console",
                      url: "https://safebeauty-admin.web.app/", source: "Safe beauty/.firebaserc:14"),
        // Safe beauty/DEPLOY.md:27 `| admin | safebeauty-admin | 9sg9ceuj.linumic.com |` (custom domain of the same site).
        MonitorTarget(id: "safebeauty.admin.domain", product: .safeBeauty, name: "Admin console (custom domain)",
                      url: "https://9sg9ceuj.linumic.com/", source: "Safe beauty/DEPLOY.md:27"),
        // Safe beauty/.firebaserc:17 hosting target salon -> site "safebeauty-salon".
        MonitorTarget(id: "safebeauty.salon", product: .safeBeauty, name: "Salon console",
                      url: "https://safebeauty-salon.web.app/", source: "Safe beauty/.firebaserc:17"),
        // Safe beauty/DEPLOY.md:28 `| salon | safebeauty-salon | salon.linumic.com |`.
        MonitorTarget(id: "safebeauty.salon.domain", product: .safeBeauty, name: "Salon console (custom domain)",
                      url: "https://salon.linumic.com/", source: "Safe beauty/DEPLOY.md:28"),

        // MARK: WorkTrack
        // WorkTrack/backend/functions/src/app.ts:57 `app.get("/v1/health")` -> {data:{status:"ok"}};
        // host from WorkTrack/backend/monitoring/setup-alerts.sh:108 `HOST="${HEALTH_HOST:-worktrack-prod.web.app}"`.
        MonitorTarget(id: "worktrack.api", product: .workTrack, name: "API health",
                      url: "https://worktrack-prod.web.app/v1/health", kind: .health(.dataStatus, expected: "ok"),
                      source: "WorkTrack/backend/functions/src/app.ts:57, WorkTrack/backend/monitoring/setup-alerts.sh:108",
                      slowAfter: 8),
        // WorkTrack/.firebaserc:3 `"default": "worktrack-prod"` (the customer portal).
        MonitorTarget(id: "worktrack.portal", product: .workTrack, name: "Customer portal",
                      url: "https://worktrack-prod.web.app/", source: "WorkTrack/.firebaserc:3"),
        // WorkTrack/web/src/console/consoleHost.ts:13 `CONSOLE_HOST = "console.linumic.com"`.
        MonitorTarget(id: "worktrack.console", product: .workTrack, name: "Vendor console",
                      url: "https://console.linumic.com/", source: "WorkTrack/web/src/console/consoleHost.ts:13"),
        // WorkTrack/app/build.gradle.kts:148 demo flavour `API_BASE_URL "https://demo.linumic.com/v1/"`, same health route.
        MonitorTarget(id: "worktrack.demo", product: .workTrack, name: "Demo API health",
                      url: "https://demo.linumic.com/v1/health", kind: .health(.dataStatus, expected: "ok"),
                      environment: .demo, source: "WorkTrack/app/build.gradle.kts:148, WorkTrack/backend/functions/src/app.ts:57",
                      slowAfter: 10),

        // MARK: Talar
        // Talar/desktop/main.js:9 `PANEL_URL = "https://talar-af-prod.web.app"` (the deployed web panel).
        MonitorTarget(id: "talar.web", product: .talar, name: "Web panel",
                      url: "https://talar-af-prod.web.app/", source: "Talar/desktop/main.js:9, Talar/web/.firebaserc:3"),
        // Talar/web/.env.production:8 `VITE_API_BASE_URL=https://asia-south1-talar-af-prod.cloudfunctions.net/api`;
        // Talar/backend/functions/src/index.ts:35 `app.get("/v1/health")` -> {ok:true, service:"talar-api"}.
        MonitorTarget(id: "talar.api", product: .talar, name: "API health",
                      url: "https://asia-south1-talar-af-prod.cloudfunctions.net/api/v1/health", kind: .health(.okFlag, expected: "ok"),
                      source: "Talar/web/.env.production:8, Talar/backend/functions/src/index.ts:35", slowAfter: 10),

        // MARK: linumic.com
        // ~/Projects/Web/Linumic-Website-Design/wordpress/tools/LANDING_SPEC.md:4 (the WordPress site, https://linumic.com/...).
        MonitorTarget(id: "website.home", product: .website, name: "Home page",
                      url: "https://linumic.com/", source: "Web/Linumic-Website-Design/wordpress/tools/LANDING_SPEC.md:4",
                      inspectsCache: true),
    ]

    /// Registrable domains the owner renews. Only linumic.com was found: every other host is a subdomain of it or
    /// Google's (`web.app`, `cloudfunctions.net`). talar.af and worktrack.af appear only in design docs and CORS
    /// examples (Talar/docs/04-api-design.md:3, WorkTrack/backend/functions/src/lib/cors.ts:28), not as live hosts,
    /// and `.af` has no RDAP service in the IANA bootstrap file.
    public static let domains: [MonitorDomain] = [
        // GoDaddy registration (RDAP, rdap.verisign.com, read 2026-10-09); the site is WordPress on GoDaddy.
        MonitorDomain(name: "linumic.com", source: "Web/Linumic-Website-Design/wordpress/tools/LANDING_SPEC.md:4"),
    ]

    /// Hosts whose TLS certificate is read, in catalog order, without repeats.
    public static var hosts: [String] {
        var seen = Set<String>()
        return targets.map(\.host).filter { seen.insert($0).inserted }
    }

    public static func domain(for host: String) -> MonitorDomain? {
        domains.first { $0.covers(host: host) }
    }
}
