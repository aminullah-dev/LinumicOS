import Foundation

/// Empty Vault entries added once, on first use: a title, a product, an environment and a sign-in URL, and nothing
/// else. No username, no password: the owner types his own. Each URL was found in a Linumic repository under
/// ~/Projects/Multiplatform on 2026-10-09; the citation is kept on the entry (`templateSource`) and shown in the editor.
/// Services whose sign-in page appears in no repository (GoDaddy, the Supabase dashboard) get no template.
public enum VaultTemplates {
    /// Bump when templates are added; only templates newer than the stored revision are added.
    public static let revision = 1

    public struct Template: Sendable {
        public let name: String
        public let product: VaultProduct
        public let environment: VaultEnvironment
        public let url: String
        public let loginKind: VaultLoginKind
        public let source: String
        public let addedInRevision: Int

        func entry(createdAt: Date) -> VaultEntry {
            VaultEntry(title: name, product: product, environment: environment, url: URL(string: url), loginKind: loginKind,
                       createdAt: createdAt, templateSource: source)
        }
    }

    public static let all: [Template] = [
        // WorkTrack/web/src/console/consoleHost.ts:13 `CONSOLE_HOST = "console.linumic.com"`; the same vendor account
        // signs in to "WorkTrack customers" in this app.
        Template(name: "WorkTrack vendor console", product: .worktrack, environment: .production,
                 url: "https://console.linumic.com", loginKind: .email,
                 source: "WorkTrack/web/src/console/consoleHost.ts:13", addedInRevision: 1),
        // Talar/desktop/main.js:9 `PANEL_URL = "https://talar-af-prod.web.app"`; the /admin route is
        // Talar/web/src/App.tsx:44. Same platform admin account as "Operations > Talar".
        Template(name: "Talar admin", product: .talar, environment: .production,
                 url: "https://talar-af-prod.web.app/admin", loginKind: .email,
                 source: "Talar/desktop/main.js:9 and Talar/web/src/App.tsx:44", addedInRevision: 1),
        // Safe beauty/DEPLOY.md:32 (`safebeauty.web.app/admin`), Safe beauty/public/admin/. Same phone and password as
        // "Operations > SafeBeauty".
        Template(name: "SafeBeauty admin console", product: .safeBeauty, environment: .production,
                 url: "https://safebeauty.web.app/admin", loginKind: .phone,
                 source: "Safe beauty/DEPLOY.md:32 and Safe beauty/public/admin/", addedInRevision: 1),
        // Safe beauty/public/provider/ and Safe beauty/ios/SafeBeauty/Localization/Strings.swift:944
        // ("open the salon console on a computer: safebeauty.web.app/provider").
        Template(name: "SafeBeauty salon console", product: .safeBeauty, environment: .production,
                 url: "https://safebeauty.web.app/provider", loginKind: .phone,
                 source: "Safe beauty/public/provider/ and Safe beauty/ios/SafeBeauty/Localization/Strings.swift:944",
                 addedInRevision: 1),
        // Velro/deploy/Caddyfile:24 `admin.velro.linumic.com {`. VELRO staff sign in with a phone and an SMS code.
        Template(name: "VELRO admin console", product: .velro, environment: .production,
                 url: "https://admin.velro.linumic.com", loginKind: .phone,
                 source: "Velro/deploy/Caddyfile:24", addedInRevision: 1),
        // WorkTrack/scripts/update-brochure.js:4 ("a browser tab that is signed in to linumic.com/wp-admin").
        Template(name: "linumic.com WordPress admin", product: .wordpress, environment: .production,
                 url: "https://linumic.com/wp-admin", loginKind: .username,
                 source: "WorkTrack/scripts/update-brochure.js:4", addedInRevision: 1),
        // Talar/docs/09-release-android.md:64 (link to https://play.google.com/console).
        Template(name: "Google Play Console", product: .googlePlayConsole, environment: .any,
                 url: "https://play.google.com/console", loginKind: .email,
                 source: "Talar/docs/09-release-android.md:64", addedInRevision: 1),
        // Linumic/LinumicCommandCenter/App/Views/SettingsViews.swift:228 opens appstoreconnect.apple.com.
        Template(name: "App Store Connect", product: .appStoreConnect, environment: .any,
                 url: "https://appstoreconnect.apple.com", loginKind: .email,
                 source: "Linumic/LinumicCommandCenter/App/Views/SettingsViews.swift:228", addedInRevision: 1),
        // Talar/docs/07-production-setup.md:3 (link to console.firebase.google.com).
        Template(name: "Firebase console", product: .firebase, environment: .any,
                 url: "https://console.firebase.google.com", loginKind: .email,
                 source: "Talar/docs/07-production-setup.md:3", addedInRevision: 1),
        // Every repository's remote is on github.com (this one: github.com/aminullah-dev/LinumicOS).
        Template(name: "GitHub", product: .github, environment: .any,
                 url: "https://github.com/login", loginKind: .username,
                 source: "git remote of Linumic/LinumicCommandCenter (github.com/aminullah-dev/LinumicOS)", addedInRevision: 1),
    ]
}
