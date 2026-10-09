# Linumic OS

*Formerly "Linumic Command Center" (renamed 2026-09-23). Stable identifiers kept on purpose: bundle ID
`com.linumic.commandcenter`, the Keychain service, the `Application Support/LinumicCommandCenter` data folder,
and this local folder.*

Private management system for the Linumic software ecosystem: products,
repositories, platforms, versions, releases, roadmap, issues, deployments,
store status, social media and (later) AI-assisted market intelligence for
Afghanistan.

**Status:** MVP. Connected, read-only: GitHub (repositories, oversight, platforms hub), the public App Store
lookup, App Store Connect and Google Play (with the owner's keys), and Supabase for the shared inventory and licence
ledger. WorkTrack customers: the vendor API, read plus licence renewals confirmed per action. Operations: Talar,
SafeBeauty and VELRO admin overviews, read-only except Talar's audited hall approve/reject. Vault: the owner's own
sign-ins in this device's Keychain, with Touch ID, copy buttons and "Fill from Vault" in the sign-in sheets. See
[docs/integrations.md](docs/integrations.md) and [docs/security.md](docs/security.md).

## Layout

```text
LinumicCommandCenter/
├── project.yml                 XcodeGen spec for the macOS app (the .xcodeproj is generated)
├── App/                        SwiftUI macOS client (UI only, no business logic)
├── Packages/LinumicCore/       Platform-neutral domain models, persistence, services, tests
│   └── Sources/LinumicCore/Resources/seed-inventory.json
├── tools/inventory/            Seed generator + read-only evidence snapshots
└── docs/                       Product inventory, discovery report, integrations, security, market intelligence
```

## Requirements

- macOS 27 SDK / Xcode 27 or newer (Swift 6.4); targets macOS 15+ and iOS/iPadOS 18+
- Signing: team `27RXPRW77S` (Apple Developer Program, individual). Development builds use Apple Development, releases use Developer ID Application.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Development

```bash
# Run the core test suite
swift test --package-path Packages/LinumicCore

# Generate the Xcode project and open it
xcodegen generate && open LinumicOS.xcodeproj

# iOS / iPadOS (Simulator)
xcodegen generate && xcodebuild -project LinumicOS.xcodeproj -scheme LinumicOS \
  -destination 'generic/platform=iOS Simulator' build

# Signed, notarised macOS release (see the script header for the one-time notarytool profile)
tools/release/build-release.sh

# Or build from the command line
xcodegen generate && xcodebuild -project LinumicOS.xcodeproj \
  -scheme LinumicOS -configuration Debug build
```

The app stores its data at
`~/Library/Containers/com.linumic.commandcenter/Data/Library/Application Support/LinumicCommandCenter/inventory.json`.
On first launch it is seeded from `seed-inventory.json`, which is generated from read-only
evidence. Every fact shows its verification state and sources, and anything without
evidence shows as **Unknown — to be verified**.

## Languages

English and **Dari (دری, `fa-AF`)**. Switch in Settings → Account → Language and relaunch, or
set it per app in System Settings → General → Language & Region → Applications. In Dari the whole
app mirrors right-to-left (window, sidebar, sheets, menus), numbers use Persian digits and dates
use the Solar Hijri calendar with Afghan month names (حمل، ثور، … میزان). Recorded evidence
(quotes, sources, notes) keeps its original language. Translations live in
`App/Resources/Localizable.xcstrings`. Run `python3 tools/l10n/check_catalog.py` after a build to
find strings with no Dari translation.

## Documents

- [ARCHITECTURE.md](ARCHITECTURE.md): system design and module boundaries
- [PRODUCTS.md](PRODUCTS.md): product data model
- [ROADMAP.md](ROADMAP.md): Linumic OS roadmap
- [CHANGELOG.md](CHANGELOG.md)
- [CONTRIBUTING.md](CONTRIBUTING.md): working rules
- [docs/product-inventory.md](docs/product-inventory.md): current inventory with sources
- [docs/product-discovery-report.md](docs/product-discovery-report.md): what was found, how, and open questions
- [docs/integrations.md](docs/integrations.md)
- [docs/security.md](docs/security.md)
- [docs/market-intelligence.md](docs/market-intelligence.md)
