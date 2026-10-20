import Foundation

// MARK: - Products (محصولات): every product and its platforms
//
// One card per product, each platform with its live store version, its newest build, the version on the default branch
// and how far that build is behind main; then open pull requests, CI, licences and Monitor health. This file says which
// platforms each product has and where each value is read. It adds nothing the app already knows: store ids and the
// platform list come from the inventory (`Product.platforms`, `Product.storeListings`), version files from
// `PlatformCatalog`; what is new here (the tracks that group an app's platforms, a GitHub release asset per platform,
// Linumic OS itself, which is not an inventory product) carries its own source.

/// Where a platform's newest build is read.
public enum ProductBuildSource: Hashable, Sendable {
    /// The store app's newest build: App Store Connect's newest build of that platform (IOS or MAC_OS), or the highest
    /// version code on any Google Play track. Read by the Release Center.
    case store
    /// The newest of the repository's last 10 GitHub releases with an asset for this platform: a name that ends with one
    /// of `suffixes` and, when given, contains `contains` (case ignored). Read by the Platforms hub.
    case releaseAsset(repo: String, suffixes: [String], contains: String?)
    /// The build of Linumic OS running on this device (its own Info.plist).
    case runningApp
    /// Nothing builds or ships this part; the sentence says why, with its source.
    case none(String)
}

/// One platform of a product.
public struct ProductSlot: Hashable, Sendable, Identifiable {
    /// "<product>.<track>.<platform>", stable (the Desk and the palette don't use it; the views do).
    public var id: String
    public var platform: Platform
    /// What it is, as recorded ("VELRO Ride", "Company console"); a name of record, not translated.
    public var label: String
    /// Bundle id or package name: the key of its store listing in the inventory, when it has one.
    public var appIdentifier: String?
    /// The `VersionFileSpec.id` of its version on the default branch.
    public var versionSpec: String?
    /// Why it has no version file to read, with the source, when it has none.
    public var noVersionFile: String?
    public var build: ProductBuildSource
    /// Monitor target ids that check this part (web and server).
    public var monitorTargets: [String]
    /// Whether the level rule compares it (the apps people install). Web, server and desktop shells whose version is not
    /// read are listed with their health, never compared.
    public var compared: Bool
    /// Where the slot itself comes from.
    public var source: String

    public init(id: String, platform: Platform, label: String, appIdentifier: String? = nil, versionSpec: String? = nil,
                noVersionFile: String? = nil, build: ProductBuildSource, monitorTargets: [String] = [], compared: Bool, source: String) {
        self.id = id
        self.platform = platform
        self.label = label
        self.appIdentifier = appIdentifier
        self.versionSpec = versionSpec
        self.noVersionFile = noVersionFile
        self.build = build
        self.monitorTargets = monitorTargets
        self.compared = compared
        self.source = source
    }

    /// The store an app on this platform is sold in.
    public var store: AppStore? {
        switch platform {
        case .android: .googlePlay
        case .iOS, .macOS, .watchOS: .appStore
        default: nil
        }
    }

    /// App Store Connect's platform name for this slot's builds and versions.
    public var ascPlatform: String? {
        switch platform {
        case .iOS: "IOS"
        case .macOS: "MAC_OS"
        default: nil
        }
    }
}

/// The platforms of one app (or one part) that are expected to move together: VELRO Ride on Android and iOS.
public struct ProductTrack: Hashable, Sendable, Identifiable {
    public var id: String
    /// A name of record ("VELRO Ride", "Console and server").
    public var title: String
    public var slots: [ProductSlot]

    public init(id: String, title: String, slots: [ProductSlot]) {
        self.id = id
        self.title = title
        self.slots = slots
    }
}

/// A product of the company as the Products page shows it.
public struct CompanyProduct: Hashable, Sendable, Identifiable {
    public var id: String
    /// The product's own name (never translated).
    public var title: String
    /// The inventory product it is, when it is one (Linumic OS is not).
    public var inventoryID: String?
    public var licence: LicenceProduct?
    public var monitor: MonitorProduct?
    public var tracks: [ProductTrack]
    /// Code repositories beyond the inventory's (Linumic OS).
    public var extraRepos: [String]
    /// Where the product's entry comes from, beyond the inventory.
    public var source: String

    public init(id: String, title: String, inventoryID: String?, licence: LicenceProduct? = nil, monitor: MonitorProduct? = nil,
                tracks: [ProductTrack], extraRepos: [String] = [], source: String) {
        self.id = id
        self.title = title
        self.inventoryID = inventoryID
        self.licence = licence
        self.monitor = monitor
        self.tracks = tracks
        self.extraRepos = extraRepos
        self.source = source
    }

    public var slots: [ProductSlot] { tracks.flatMap(\.slots) }
    public var deskDomain: DeskDomain { .named(title) }
}

public enum ProductsCatalog {
    static let inventory = "Inventory platform record"
    static let report = "research/platform-admin-apis.md"

    /// Linumic OS's own version: project.yml sets MARKETING_VERSION and CURRENT_PROJECT_VERSION once for the project
    /// (project.yml:15-16) and builds for macOS and iOS (project.yml:24); bundle id com.linumic.commandcenter (:68).
    public static let linumicOSVersionFile = VersionFileSpec(
        repo: "aminullah-dev/LinumicOS", path: "project.yml", format: .xcodegen(bundleID: "com.linumic.commandcenter"),
        component: "macOS and iOS", platform: .macOS, appIdentifier: "com.linumic.commandcenter",
        source: CatalogSource("project.yml:15-16,24,68 in this repository", checkedAt: day("2026-10-20")))

    /// Version files read for the Products page that the Platforms hub does not read (Linumic OS is not an inventory
    /// product, so the hub has no row for it).
    public static let extraVersionFiles: [VersionFileSpec] = [linumicOSVersionFile]

    private static func day(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso + "T00:00:00Z")! }

    private static func spec(_ repo: String, _ path: String, _ component: String) -> String { "\(repo)|\(path)|\(component)" }

    private static func slot(_ product: String, _ track: String, _ platform: Platform, _ label: String, id appID: String? = nil,
                             spec: String? = nil, noVersionFile: String? = nil, build: ProductBuildSource, monitor: [String] = [],
                             compared: Bool, source: String) -> ProductSlot {
        ProductSlot(id: "\(product).\(track).\(platform.rawValue)", platform: platform, label: label, appIdentifier: appID,
                    versionSpec: spec, noVersionFile: noVersionFile, build: build, monitorTargets: monitor, compared: compared,
                    source: source)
    }

    static let noWebVersion = "No version file is catalogued for this part, and the deployed version is not published, so neither is read."
    static let noDeployedVersion = "The deployed version is not published, so it is not read."

    public static let products: [CompanyProduct] = [
        workTrack, safeBeauty, velro, talar, khayatYar, mediFlow, nerkhTimes, namazia, dukanPro, linumicOS,
    ]

    public static func product(_ id: String) -> CompanyProduct? { products.first { $0.id == id } }

    // MARK: The products

    static let workTrack: CompanyProduct = {
        let r = "aminullah-dev/WorkTrack"
        return CompanyProduct(id: "worktrack", title: "WorkTrack", inventoryID: "worktrack", monitor: .workTrack, tracks: [
            ProductTrack(id: "app", title: "WorkTrack", slots: [
                slot("worktrack", "app", .android, "Employee app", id: "app.worktrack", spec: spec(r, "app/build.gradle.kts", "Android"),
                     build: .store, compared: true, source: "\(inventory): android app.worktrack"),
                slot("worktrack", "app", .iOS, "Employee app", id: "app.worktrack", spec: spec(r, "ios/project.yml", "iOS"),
                     build: .store, compared: true, source: "\(inventory): iOS app.worktrack"),
            ]),
            ProductTrack(id: "console", title: "Console and server", slots: [
                slot("worktrack", "console", .web, "Company console", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     monitor: ["worktrack.portal", "worktrack.console"], compared: false, source: "\(inventory): web"),
                slot("worktrack", "console", .desktop, "Electron shell for the company console", noVersionFile: noWebVersion,
                     build: .none(noDeployedVersion), compared: false, source: "\(inventory): desktop"),
                slot("worktrack", "console", .backend, "Firebase Cloud Functions", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     monitor: ["worktrack.api"], compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product worktrack")
    }()

    static let safeBeauty: CompanyProduct = {
        let r = "aminullah-dev/stealth-service-vault-"
        let salonVersion = "No version file is catalogued for the salon desktop app (Electron), and its GitHub release is tagged salon-desktop, not a version."
        return CompanyProduct(id: "safebeauty", title: "SafeBeauty", inventoryID: "safe-beauty", monitor: .safeBeauty, tracks: [
            ProductTrack(id: "app", title: "SafeBeauty", slots: [
                slot("safebeauty", "app", .android, "Customer, provider and admin app", id: "com.security.stealthapp",
                     spec: spec(r, "app/build.gradle.kts", "Android"), build: .store, compared: true,
                     source: "\(inventory): android com.security.stealthapp"),
                slot("safebeauty", "app", .iOS, "iOS app", id: "com.safebeauty.app", spec: spec(r, "ios/project.yml", "iOS"),
                     build: .store, compared: true, source: "\(inventory): iOS com.safebeauty.app"),
            ]),
            // GitHub release "salon-desktop" (2026-07-16) holds SafeBeauty-Salon-mac-*.dmg and SafeBeauty-Salon-win-x64.exe.
            ProductTrack(id: "salon", title: "Salon desktop app", slots: [
                slot("safebeauty", "salon", .macOS, "Salon desktop app (Electron)", noVersionFile: salonVersion,
                     build: .releaseAsset(repo: r, suffixes: [".dmg"], contains: "salon"), compared: false,
                     source: "\(inventory): macOS; GitHub releases of \(r) (read 2026-10-20)"),
                slot("safebeauty", "salon", .windows, "Salon desktop app (Electron)", noVersionFile: salonVersion,
                     build: .releaseAsset(repo: r, suffixes: [".exe", ".msi"], contains: "salon"), compared: false,
                     source: "\(inventory): windows; GitHub releases of \(r) (read 2026-10-20)"),
            ]),
            ProductTrack(id: "web", title: "Consoles and server", slots: [
                slot("safebeauty", "web", .web, "Admin and provider consoles (Firebase Hosting)", noVersionFile: noWebVersion,
                     build: .none(noDeployedVersion),
                     monitor: ["safebeauty.app", "safebeauty.admin", "safebeauty.admin.domain", "safebeauty.salon", "safebeauty.salon.domain"],
                     compared: false, source: "\(inventory): web"),
                slot("safebeauty", "web", .backend, "Firebase Cloud Functions", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product safe-beauty")
    }()

    static let velro: CompanyProduct = {
        let r = "aminullah-dev/velro"
        func app(_ track: String, _ title: String, _ appID: String, android: Bool, macOS: Bool) -> ProductTrack {
            var slots: [ProductSlot] = []
            if android {
                slots.append(slot("velro", track, .android, title, id: appID, spec: spec(r, "mobile/gradle.properties", "Android · \(title)"),
                                  build: .store, compared: true, source: "\(inventory): android \(appID)"))
            }
            slots.append(slot("velro", track, .iOS, title, id: appID, spec: spec(r, "ios/project.yml", "iOS · \(title)"),
                              build: .store, compared: true, source: "\(inventory): iOS \(appID)"))
            if macOS {
                // The same XcodeGen target builds the Mac app (one MARKETING_VERSION for both).
                slots.append(slot("velro", track, .macOS, title, id: appID, spec: spec(r, "ios/project.yml", "iOS · \(title)"),
                                  build: .store, compared: true, source: "\(inventory): macOS \(appID)"))
            }
            return ProductTrack(id: track, title: title, slots: slots)
        }
        return CompanyProduct(id: "velro", title: "VELRO", inventoryID: "velro", monitor: .velro, tracks: [
            app("ride", "VELRO Ride", "af.velro.passenger", android: true, macOS: false),
            app("driver", "VELRO Driver", "af.velro.driver", android: true, macOS: false),
            app("ops", "VELRO Ops", "af.velro.ops", android: false, macOS: true),
            ProductTrack(id: "web", title: "Admin and server", slots: [
                slot("velro", "web", .web, "Staff admin panel (React)", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     monitor: ["velro.admin"], compared: false, source: "\(inventory): web"),
                slot("velro", "web", .backend, "FastAPI API", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     monitor: ["velro.api.live", "velro.api.ready"], compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product velro")
    }()

    static let talar: CompanyProduct = {
        CompanyProduct(id: "talar", title: "Talar", inventoryID: "talar", monitor: .talar, tracks: [
            // Sideloaded: the APK is published as a GitHub release of talar-releases (PlatformCatalog, report §2(f)).
            ProductTrack(id: "app", title: "Talar", slots: [
                slot("talar", "app", .android, "Android app", id: "af.talar",
                     spec: spec("aminullah-dev/talar", "android/app/build.gradle.kts", "Android"),
                     build: .releaseAsset(repo: "aminullah-dev/talar-releases", suffixes: [".apk"], contains: nil), compared: true,
                     source: "\(inventory): android af.talar; sideload releases in talar-releases (\(report) §2(f))"),
            ]),
            ProductTrack(id: "web", title: "Web, desktop and server", slots: [
                slot("talar", "web", .web, "Web app", noVersionFile: noWebVersion, build: .none(noDeployedVersion), monitor: ["talar.web"],
                     compared: false, source: "\(inventory): web"),
                slot("talar", "web", .desktop, "Hall-management panel (Electron)", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     compared: false, source: "\(inventory): desktop"),
                slot("talar", "web", .backend, "Firebase Cloud Functions", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     monitor: ["talar.api"], compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product talar")
    }()

    static let khayatYar: CompanyProduct = {
        let r = "aminullah-dev/AfghanJama"
        // One version for Android, Windows and macOS: gradle.properties appVersion / appVersionCode (PlatformCatalog).
        let shared = spec(r, "gradle.properties", "Android, Windows, macOS")
        return CompanyProduct(id: "khayatyar", title: "KhayatYar", inventoryID: "afghanjama", licence: .khayatyar, tracks: [
            ProductTrack(id: "app", title: "KhayatYar", slots: [
                slot("khayatyar", "app", .android, "KhayatYar Android", id: "com.afghanjama", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".apk"], contains: nil), compared: true,
                     source: "\(inventory): android com.afghanjama; releases by hand (DELIVERY.md:154-185)"),
                slot("khayatyar", "app", .macOS, "KhayatYar desktop", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".dmg"], contains: nil), compared: true, source: "\(inventory): macOS"),
                slot("khayatyar", "app", .windows, "KhayatYar desktop", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".msi", ".exe"], contains: nil), compared: true, source: "\(inventory): windows"),
                slot("khayatyar", "app", .iOS, "KhayatYar iOS", id: "com.afghanjama.khayatyar",
                     noVersionFile: "iosApp/project.yml on main sets no MARKETING_VERSION (GitHub contents API, read 2026-10-20), so there is no iOS version to read.",
                     build: .store, compared: true, source: "\(inventory): iOS com.afghanjama.khayatyar"),
            ]),
        ], source: "Inventory product afghanjama (the Tailor ERP / KhayatYar record)")
    }()

    static let mediFlow: CompanyProduct = {
        let r = "aminullah-dev/MediFlow"
        let shared = spec(r, "pyproject.toml", "Desktop (Windows, macOS)")
        return CompanyProduct(id: "mediflow", title: "MediFlow", inventoryID: "mediflow", licence: .mediflow, tracks: [
            ProductTrack(id: "app", title: "MediFlow", slots: [
                slot("mediflow", "app", .windows, "Desktop app", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".zip", ".msi", ".exe"], contains: "windows"), compared: true,
                     source: "\(inventory): windows"),
                slot("mediflow", "app", .macOS, "Desktop app", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".dmg", ".pkg", ".zip"], contains: "mac"), compared: true,
                     source: "\(inventory): macOS"),
            ]),
        ], source: "Inventory product mediflow")
    }()

    static let nerkhTimes: CompanyProduct = {
        let r = "aminullah-dev/NerkhTimes"
        return CompanyProduct(id: "nerkhtimes", title: "NerkhTimes", inventoryID: "nerkhtimes", tracks: [
            ProductTrack(id: "app", title: "NerkhTimes", slots: [
                slot("nerkhtimes", "app", .android, "Android app", id: "af.market.nerkhtimes", spec: spec(r, "app/build.gradle.kts", "Android"),
                     build: .store, compared: true, source: "\(inventory): android af.market.nerkhtimes"),
                slot("nerkhtimes", "app", .iOS, "iOS app", id: "af.market.nerkhtimes", spec: spec(r, "ios/project.yml", "iOS"),
                     build: .store, compared: true, source: "\(inventory): iOS af.market.nerkhtimes"),
            ]),
            ProductTrack(id: "server", title: "Server", slots: [
                slot("nerkhtimes", "server", .backend, "Apps Script admin/API", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product nerkhtimes")
    }()

    static let namazia: CompanyProduct = {
        let r = "aminullah-dev/-Namazia"
        return CompanyProduct(id: "namazia", title: "Namazia", inventoryID: "namazia", tracks: [
            ProductTrack(id: "app", title: "Afghan Prayer Times", slots: [
                slot("namazia", "app", .android, "Android app", id: "af.namazia.app", spec: spec(r, "app/build.gradle", "Android"),
                     build: .store, compared: true, source: "\(inventory): android af.namazia.app"),
                slot("namazia", "app", .iOS, "iOS app and widget", id: "af.namazia.app", spec: spec(r, "ios/project.yml", "iOS"),
                     build: .store, compared: true, source: "\(inventory): iOS af.namazia.app"),
            ]),
        ], source: "Inventory product namazia")
    }()

    static let dukanPro: CompanyProduct = {
        let r = "aminullah-dev/DukanPro"
        let shared = spec(r, "app/pubspec.yaml", "Flutter app (Android, iOS, macOS)")
        return CompanyProduct(id: "dukanpro", title: "DukanPro", inventoryID: "dukanpro", tracks: [
            ProductTrack(id: "app", title: "DukanPro", slots: [
                slot("dukanpro", "app", .android, "Flutter app", id: "com.dukanpro.dukanpro", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".apk", ".aab"], contains: nil), compared: true,
                     source: "\(inventory): android com.dukanpro.dukanpro"),
                slot("dukanpro", "app", .iOS, "Flutter app", id: "com.dukanpro.dukanpro", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".ipa"], contains: nil), compared: true,
                     source: "\(inventory): iOS com.dukanpro.dukanpro"),
                slot("dukanpro", "app", .macOS, "Flutter app", id: "com.dukanpro.dukanpro", spec: shared,
                     build: .releaseAsset(repo: r, suffixes: [".dmg", ".pkg"], contains: nil), compared: true,
                     source: "\(inventory): macOS com.dukanpro.dukanpro"),
                slot("dukanpro", "app", .windows, "Planned", noVersionFile: "Planned, not built yet (inventory).",
                     build: .none("Planned, not built yet (inventory)."), compared: false, source: "\(inventory): windows, planned"),
            ]),
            ProductTrack(id: "server", title: "Sync server", slots: [
                slot("dukanpro", "server", .backend, "Sync server", noVersionFile: noWebVersion, build: .none(noDeployedVersion),
                     compared: false, source: "\(inventory): backend"),
            ]),
        ], source: "Inventory product dukanpro")
    }()

    static let linumicOS: CompanyProduct = {
        let s = linumicOSVersionFile.id
        let source = "This repository (project.yml: supportedDestinations macOS and iOS); not an inventory product, not in a store"
        return CompanyProduct(id: "linumicos", title: "Linumic OS", inventoryID: nil, tracks: [
            ProductTrack(id: "app", title: "Linumic OS", slots: [
                slot("linumicos", "app", .macOS, "Mac app", id: "com.linumic.commandcenter", spec: s, build: .runningApp, compared: true, source: source),
                slot("linumicos", "app", .iOS, "iPhone and iPad app", id: "com.linumic.commandcenter", spec: s, build: .runningApp,
                     compared: true, source: source),
            ]),
        ], extraRepos: ["aminullah-dev/LinumicOS"],
        source: "ReleaseCatalog.extraRepos: git remote of ~/Projects/Multiplatform/Linumic/LinumicCommandCenter (2026-10-09)")
    }()
}
