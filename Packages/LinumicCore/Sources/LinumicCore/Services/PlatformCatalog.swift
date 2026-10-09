import Foundation

/// Reference facts for the platforms hub, keyed to the existing inventory products. Nothing here is a new
/// product: a profile whose product isn't in the inventory is simply not shown.
///
/// Every value cites where it came from. Version-file locations come from the research report
/// `Linumic/research/platform-admin-apis.md` (2026-10-08), or from the GitHub contents API where the report
/// names none. Each link was opened on 2026-10-09 and answered HTTP 200 with the page title quoted; links
/// that answered 404 (for example linumic.com pages for Namazia and DukanPro) are deliberately absent.
public enum PlatformCatalog {
    static let report = "research/platform-admin-apis.md"
    static let reportDate = day("2026-10-08")
    static let checked = day("2026-10-09")
    static let ownerBrief = CatalogSource("Owner brief: Linumic OS platform control, phase 2 (2026-10-09)", checkedAt: day("2026-10-09"))

    private static func day(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso + "T00:00:00Z")!
    }

    private static func fromReport(_ section: String) -> CatalogSource {
        CatalogSource("\(report) \(section)", checkedAt: reportDate)
    }

    private static func page(_ title: String, _ extra: String? = nil) -> CatalogSource {
        let base = "HTTP 200, page title \u{201C}\(title)\u{201D}, opened 2026-10-09"
        return CatalogSource(extra.map { "\(base); \($0)" } ?? base, checkedAt: checked)
    }

    private static func link(_ kind: PlatformLink.Kind, _ title: String, _ url: String, _ source: CatalogSource) -> PlatformLink {
        PlatformLink(kind: kind, title: title, url: URL(string: url)!, source: source)
    }

    public static let profiles: [PlatformProfile] = [
        PlatformProfile(
            productID: "worktrack", title: "WorkTrack", businessModel: .selfServe, businessModelSource: ownerBrief,
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/WorkTrack", path: "app/build.gradle.kts", format: .gradle, component: "Android",
                                platform: .android, appIdentifier: "app.worktrack", source: fromReport("§1(f), app/build.gradle.kts:91-92")),
                VersionFileSpec(repo: "aminullah-dev/WorkTrack", path: "ios/project.yml", format: .xcodegen(bundleID: "app.worktrack"), component: "iOS",
                                platform: .iOS, appIdentifier: "app.worktrack", source: fromReport("§1(f), ios/project.yml:19-20")),
            ],
            links: [
                link(.console, "WorkTrack vendor console", "https://console.linumic.com",
                     page("WorkTrack — پورتال مدیر", "\(report) §1(a), web/src/console/consoleHost.ts:13")),
                link(.salesPage, "linumic.com/worktrack", "https://linumic.com/worktrack/", page("WorkTrack - Linumic")),
                link(.productPage, "linumic.com/what-we-do/worktrack", "https://linumic.com/what-we-do/worktrack/", page("WorkTrack — Attendance, Shifts, Leave & Payroll")),
            ]
        ),
        PlatformProfile(
            productID: "safe-beauty", title: "SafeBeauty", businessModel: .selfServe, businessModelSource: ownerBrief,
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/stealth-service-vault-", path: "app/build.gradle.kts", format: .gradle, component: "Android",
                                platform: .android, appIdentifier: "com.security.stealthapp", releaseRepo: "aminullah-dev/stealth-service-vault-",
                                source: fromReport("§3(f), app/build.gradle.kts:62-66")),
                VersionFileSpec(repo: "aminullah-dev/stealth-service-vault-", path: "ios/project.yml", format: .xcodegen(bundleID: "com.safebeauty.app"),
                                component: "iOS", platform: .iOS, appIdentifier: "com.safebeauty.app", source: fromReport("§3(f), ios/project.yml:72-74")),
            ],
            links: [
                link(.admin, "SafeBeauty · Admin Console", "https://safebeauty.web.app/admin",
                     page("SafeBeauty · Admin Console", "\(report) §3(a), public/admin/index.html")),
                link(.console, "SafeBeauty · Salon Console", "https://safebeauty.web.app/provider", page("SafeBeauty · Salon Console")),
                link(.download, "safebeauty.web.app/get", "https://safebeauty.web.app/get/", page("SafeBeauty · دانلود", "\(report) §3(f), public/get/index.html:140")),
                link(.salesPage, "linumic.com/safebeauty", "https://linumic.com/safebeauty/", page("SafeBeauty - Linumic")),
                link(.productPage, "linumic.com/what-we-do/safebeauty", "https://linumic.com/what-we-do/safebeauty/", page("SafeBeauty — Verified Salon Booking Marketplace")),
            ]
        ),
        PlatformProfile(
            productID: "talar", title: "Talar", businessModel: .selfServe, businessModelSource: ownerBrief,
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/talar", path: "android/app/build.gradle.kts", format: .gradle, component: "Android",
                                platform: .android, appIdentifier: "af.talar", releaseRepo: "aminullah-dev/talar-releases",
                                source: fromReport("§2(f), android/app/build.gradle.kts:20-25; sideload releases in talar-releases")),
            ],
            links: [
                link(.console, "Talar panel", "https://talar-af-prod.web.app", page("تالار — پنل مدیریت", "\(report) §2(a), panel hosting")),
                link(.admin, "Talar admin", "https://talar-af-prod.web.app/admin",
                     CatalogSource("\(report) §2(f), the /admin route in web/src/pages/AdminPage.tsx; HTTP 200 on 2026-10-09", checkedAt: checked)),
                link(.salesPage, "linumic.com/talar", "https://linumic.com/talar/", page("Talar - Linumic")),
                link(.productPage, "linumic.com/what-we-do/talar", "https://linumic.com/what-we-do/talar/", page("Talar — Wedding Hall & Event Venue ERP")),
            ]
        ),
        PlatformProfile(
            productID: "velro", title: "VELRO", businessModel: .consumer,
            businessModelSource: CatalogSource("Store listings VELRO Ride and VELRO Driver (inventory); \(report) §4(f)", checkedAt: reportDate),
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/velro", path: "mobile/gradle.properties",
                                format: .properties(nameKey: "velro.versionName", codeKey: "velro.versionCode"), component: "Android · VELRO Ride",
                                platform: .android, appIdentifier: "af.velro.passenger", source: fromReport("§4(f), mobile/gradle.properties:29-30")),
                VersionFileSpec(repo: "aminullah-dev/velro", path: "mobile/gradle.properties",
                                format: .properties(nameKey: "velro.versionName", codeKey: "velro.versionCode"), component: "Android · VELRO Driver",
                                platform: .android, appIdentifier: "af.velro.driver", source: fromReport("§4(f), mobile/gradle.properties:29-30")),
                VersionFileSpec(repo: "aminullah-dev/velro", path: "ios/project.yml", format: .xcodegen(bundleID: "af.velro.passenger"),
                                component: "iOS · VELRO Ride", platform: .iOS, appIdentifier: "af.velro.passenger",
                                source: fromReport("§4(f), ios/project.yml:14-15,79")),
                VersionFileSpec(repo: "aminullah-dev/velro", path: "ios/project.yml", format: .xcodegen(bundleID: "af.velro.driver"),
                                component: "iOS · VELRO Driver", platform: .iOS, appIdentifier: "af.velro.driver",
                                source: fromReport("§4(f), ios/project.yml:159-162")),
                VersionFileSpec(repo: "aminullah-dev/velro", path: "ios/project.yml", format: .xcodegen(bundleID: "af.velro.ops"),
                                component: "iOS · VELRO Ops", platform: .iOS, appIdentifier: "af.velro.ops",
                                source: fromReport("§4(f), ios/project.yml:243-246")),
            ],
            links: [
                link(.admin, "VELRO admin console", "https://admin.velro.linumic.com", page("VELRO", "\(report) §4(a), deploy/Caddyfile:6-48")),
                link(.salesPage, "linumic.com/velro", "https://linumic.com/velro/", page("VELRO - Linumic")),
                link(.productPage, "linumic.com/what-we-do/velro", "https://linumic.com/what-we-do/velro/", page("VELRO — Intercity Ride Booking for Afghanistan")),
            ]
        ),
        PlatformProfile(
            productID: "mediflow", title: "MediFlow", businessModel: .licence,
            businessModelSource: CatalogSource("LNM1 offline licence: licensing/PROTOCOL.md; \(report) §5", checkedAt: reportDate),
            licenceProduct: .mediflow,
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/MediFlow", path: "pyproject.toml", format: .pyproject, component: "Desktop (Windows, macOS)",
                                platform: .desktop, releaseRepo: "aminullah-dev/MediFlow", source: fromReport("§5, pyproject.toml:7")),
            ],
            links: [
                link(.salesPage, "linumic.com/mediflow", "https://linumic.com/mediflow/", page("MediFlow - Linumic")),
                link(.productPage, "linumic.com/what-we-do/mediflow", "https://linumic.com/what-we-do/mediflow/", page("MediFlow — Clinic & Hospital Management System")),
            ]
        ),
        PlatformProfile(
            productID: "afghanjama", title: "Tailor ERP / KhayatYar", businessModel: .licence,
            businessModelSource: CatalogSource("LNM1 offline licence: licensing/PROTOCOL.md; \(report) §5", checkedAt: reportDate),
            licenceProduct: .khayatyar,
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/AfghanJama", path: "gradle.properties",
                                format: .properties(nameKey: "appVersion", codeKey: "appVersionCode"), component: "Android, Windows, macOS",
                                platform: .android, appIdentifier: "com.afghanjama", releaseRepo: "aminullah-dev/AfghanJama",
                                source: fromReport("§5, gradle.properties:20,25; releases by hand, DELIVERY.md:154-185")),
            ],
            links: [
                link(.salesPage, "linumic.com/tailor-erp", "https://linumic.com/tailor-erp/", page("Tailor ERP - Linumic")),
                link(.productPage, "linumic.com/what-we-do/tailor-erp", "https://linumic.com/what-we-do/tailor-erp/",
                     page("Tailor ERP — Orders, Production & Accounts")),
            ]
        ),
        PlatformProfile(
            productID: "nerkhtimes", title: "NerkhTimes", businessModel: .consumer,
            businessModelSource: CatalogSource("Store listings on the App Store and Google Play (inventory)", checkedAt: checked),
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/NerkhTimes", path: "app/build.gradle.kts", format: .gradle, component: "Android",
                                platform: .android, appIdentifier: "af.market.nerkhtimes",
                                source: CatalogSource("GitHub contents API, app/build.gradle.kts:26-27 @ main", checkedAt: checked)),
                VersionFileSpec(repo: "aminullah-dev/NerkhTimes", path: "ios/project.yml", format: .xcodegen(bundleID: "af.market.nerkhtimes"),
                                component: "iOS", platform: .iOS, appIdentifier: "af.market.nerkhtimes",
                                source: CatalogSource("GitHub contents API, ios/project.yml:11-12,29 @ main", checkedAt: checked)),
            ],
            links: [
                link(.website, "NerkhTimes website", "https://aminullah-dev.github.io/nerkhtimes.github.io/",
                     page("NerkhTimes", "the product's website fact in the inventory")),
            ]
        ),
        PlatformProfile(
            productID: "namazia", title: "Afghan Prayer Times (Namazia)", businessModel: .consumer,
            businessModelSource: CatalogSource("Store listings on the App Store and Google Play (inventory)", checkedAt: checked),
            trackingNote: "The main branch of aminullah-dev/-Namazia holds only README.md (GitHub tree, 2026-10-09), so there is no version file to read."
        ),
        PlatformProfile(
            productID: "dukanpro", title: "DukanPro", businessModel: .unknown,
            businessModelSource: CatalogSource("Not recorded: the product is still in development (inventory)", checkedAt: checked),
            versionFiles: [
                VersionFileSpec(repo: "aminullah-dev/DukanPro", path: "app/pubspec.yaml", format: .pubspec, component: "Flutter app (Android, iOS, macOS)",
                                platform: .android, appIdentifier: "com.dukanpro.dukanpro",
                                source: CatalogSource("GitHub contents API, app/pubspec.yaml:4 @ main", checkedAt: checked)),
            ]
        ),
    ]

    public static func profile(for productID: String) -> PlatformProfile? {
        profiles.first { $0.productID == productID }
    }
}
