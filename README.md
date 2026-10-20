# Linumic OS

*Formerly "Linumic Command Center" (renamed 2026-09-23). Stable identifiers kept on purpose: bundle ID
`com.linumic.commandcenter`, the Keychain service, the `Application Support/LinumicCommandCenter` data folder,
and this local folder.*

Private management system for the Linumic software ecosystem: products,
repositories, platforms, versions, releases, roadmap, issues, deployments,
store status, social media and (later) AI-assisted market intelligence for
Afghanistan.

**Status:** MVP. **Desk** (home screen, since 2026-10-19): one list of what needs the owner today, this week and
later, grouped by product (WorkTrack first, then SafeBeauty), built on this device from the Daily Brief and the owner's
ledgers (the eight PRIORITIES.md files and the newest NEXT-ACTIONS, read-only, inside two folders granted once in
Settings → Integrations → Ledger access); a source that was not read is an item, never zero. Connected, read-only: GitHub (repositories, oversight, platforms hub), the public App Store
lookup, App Store Connect and Google Play (with the owner's keys), and Supabase for the shared inventory and licence
ledger. WorkTrack customers: the vendor API, read plus licence renewals confirmed per action. Operations: Talar,
SafeBeauty and VELRO admin overviews, read-only except Talar's audited hall approve/reject. Vault: the owner's own
sign-ins in this device's Keychain, with Touch ID, copy buttons and "Fill from Vault" in the sign-in sheets. Monitor:
live health of every public Linumic endpoint (plain GETs, no credentials) with TLS certificate and linumic.com domain
expiry, 24-hour uptime and down/expiry notifications. Releases: every app in App Store Connect and Google Play, open
PRs (stacks in merge order) and CI of every product repository, and a "Waiting on you" list, read-only except
releasing an approved App Store version after a confirmation. Daily Brief: one page (and an optional morning
notification) summarising what all of these last read, with sources, read times and "what changed since yesterday".
Command Palette (⌘K): fuzzy search over screens, records and existing actions, English and Dari. Keys & Backups:
every signing key, licence key and encrypted backup with source and date, whether each key file is still on this Mac
(existence, size and date only), whether it changed after its backup or is in no backup, the last restore test, and
a read-only restore guide; reminders feed the Daily Brief. **Automation** (since 2026-10-19): every read above runs on
its own schedule while the app runs, with or without a window (menu bar, open at login, iOS background refresh), with
retries, a run log and a notification after three failures; the daily local backup counts only as what `Backups/`
holds, read back, never the log's word. **Sentinel** on Supabase (deployed 2026-10-19) keeps the health checks, a daily
licence sweep and a weekly inventory snapshot running while the Mac is off. **Obligations & accounts** (Phase 2 of the
company OS roadmap): every dated obligation with what happens if it is missed, its source and its day (or "date
unknown"), alerts at 30, 14, 7 and 1 days, live dates from the Monitor, the licence ledger and Keys & Backups, and the
accounts the company depends on with whose name each is in; they reach the Desk by due day. **Continuity**: an
encrypted export (age, with a passphrase that is never stored) of the inventory, obligations, accounts, licence ledger
and keys registry to a folder off this Mac, read back and checked, that opens without Linumic OS. **Money** (پول,
Phase 4): who paid (HesabPay and invoices paid by hand, kept apart), what is on the way (renewals forecast, invoices
sent and past due), what we owe SafeBeauty salons and what they owe us (never netted), and what we pay (account costs
per currency and billing cycle), read-only, each figure with its source and read time, Unknown with a reason when it
was not read, amounts never converted or added across currencies; store proceeds are Unknown. **Sales** (فروش, Phase 5):
who to call today from the WorkTrack CRM by Kabul's day, open accounts with no next step, new and self-serve companies
with no CRM account, renewals, website messages and the SafeBeauty KYC count, read-only, with Dari and Pashto reminder
drafts that are only copied. **Legal & company** (حقوقی و شرکت, Phase 6): the company card (not registered, the seller
per store as the listings say it, the DSA status Unknown), and on the Mac the [TO FILL], [LAWYER] and [TO DECIDE]
markers of the legal drafts with file and line, never their text, and the Asasnama files by name and date, never opened,
through a one-time read-only grant. **Marketing queue**: each brand's queue end and the clock change as obligations
beside the brand's ledger, with Verify; it never posts. Six empty manual pages are in a collapsed **Archive**.
**Products** (محصولات, Phase 7): every product's platforms with the live store version,
newest build, version on main and commits behind it, pull requests, CI, licences and health, each with its source and
read time, and "platforms not level" on the Desk; **Agents** (ایجنت‌ها): the 20 scheduled agents and their pull requests
on GitHub, with "no pull request for more than 4 days" on the Desk. See [docs/integrations.md](docs/integrations.md)
and [docs/security.md](docs/security.md).

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

# The same suite with the Persian calendar as the device's own (as on the owner's Mac, fa_AF)
tools/test/persian-calendar.sh

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
- [docs/company-os-roadmap.md](docs/company-os-roadmap.md): running the whole company from Linumic OS (Dari); Phase 1 is the Desk and Ledgers, Phase 2 obligations and continuity, Phase 4 Money, Phase 5 Sales, Phase 6 Legal & company, the marketing queue and the Archive, Phase 7 Products and Agents
- [docs/automation.md](docs/automation.md): the automation engine, the daily backup and what counts as one
- [docs/sentinel.md](docs/sentinel.md): the server-side checks on Supabase
- [docs/obligations.md](docs/obligations.md): obligations and accounts, every seed row with its source
- [docs/continuity.md](docs/continuity.md): the encrypted export, its format and how to open it without Linumic OS
- [docs/money.md](docs/money.md): Money, every figure with its source, the Unknown reasons and the TEST-company rules
- [docs/sales.md](docs/sales.md): Sales, what is listed and from where, Kabul's day, privacy, drafts, the owner's shape check
- [docs/legal.md](docs/legal.md): Legal & company, what is read and what never is, the marker rule and its grep, the sandbox check and the grant
- [docs/products.md](docs/products.md): Products, every product's platforms with source and read time, and when they are not level
- [docs/agents.md](docs/agents.md): Agents, the registry of the scheduled agents and their pull requests on GitHub
- [docs/backend-plan.md](docs/backend-plan.md): Supabase
- [CHANGELOG.md](CHANGELOG.md)
- [CONTRIBUTING.md](CONTRIBUTING.md): working rules
- [docs/product-inventory.md](docs/product-inventory.md): current inventory with sources
- [docs/product-discovery-report.md](docs/product-discovery-report.md): what was found, how, and open questions
- [docs/integrations.md](docs/integrations.md)
- [docs/security.md](docs/security.md)
- [docs/market-intelligence.md](docs/market-intelligence.md)
