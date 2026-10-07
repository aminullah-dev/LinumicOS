# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added: project oversight across every repository ("from 0 to 100")
- A new **Oversight** screen and a live **Project oversight** card on the dashboard put every repository you own
  under scrutiny, read-only, in one place: a 0–100 fleet-health score, per-repo health (critical / needs attention /
  healthy / not scanned), latest push, open pull requests and issues, CI status, and security alerts.
- `OversightSync` discovers every repository from GitHub (`GET /user/repos`, private included) and refreshes each
  one. A failed sweep never blanks the dashboard: the last good snapshot and a per-repo scan error are kept.
- Security posture per repo: open Dependabot, secret-scanning and code-scanning alerts, plus default-branch
  protection. Each is independent and best-effort — a category the token can't read stays **Unknown**, never
  reported as zero. A repository counts as healthy only when it was scanned and nothing was flagged.
- `RepositorySnapshot.Security` travels with the GitHub snapshot, so product repositories gain the same security
  read. The oversight register is persisted in a new optional `inventory.oversight` section (older files decode as
  empty). English and Dari strings included.
- 13 tests (113 in total): health classification, the 0–100 score, alert roll-ups, discovery, and
  snapshot/list-failure preservation.

### Added: local working-copy scan (uncommitted and unpushed work)
- Point Oversight at the folder that holds your repositories (Oversight → Choose folder) and it tracks
  each local checkout read-only: current branch, whether it is in sync with or diverged from `origin`,
  and the exact number of tracked files with uncommitted changes.
- The app is sandboxed and never runs `git`: it reads the `.git` directory directly through a
  security-scoped bookmark. "Uncommitted" is computed by comparing each file's git blob SHA-1 against
  the index, so it is exact, not a timestamp guess. Facts it cannot read (e.g. an unsupported index
  version) show as Unknown. Access is read-only; no repository is ever modified.
- Local status feeds the same dashboard: repos with uncommitted changes or diverged from origin count
  as "needs attention", and new "Uncommitted (local)" and "Diverged from origin" tiles appear.
- 7 more tests (120 in total) against real on-disk `.git` fixtures, including a hand-built v2 index.

### Added: automatic oversight sweep and change alerts
- Oversight now refreshes itself: on launch and every 30 minutes while the app is open, it re-scans
  every repository (GitHub, and your local folder if chosen), read-only. Toggle it in
  Settings → Integrations → Project oversight; it needs a GitHub token.
- `OversightChangeDetector` compares each sweep with the last and raises alerts: a new security alert
  appeared, CI started failing (or recovered), the default branch lost protection, uncommitted work
  showed up locally, a branch diverged from origin, or a new repository was found. The first sweep is
  silent, so populating the register never floods you.
- Changes appear in a "Recent changes" panel on the Oversight screen and as local notifications
  (new security alerts and broken CI buzz; the rest are quiet). Notifications stay on the device.
- 7 more tests (127 in total) for the change detector. English and Dari strings included.

### Added: ratings, reviews and TestFlight builds
- `StoreListing.insights`: App Store rating per storefront (public lookup, no key), the newest customer reviews and
  TestFlight builds (App Store Connect, Developer role, read-only). Stored in a new `store_listings.insights` jsonb
  column (migration 20260924020000); an older client that sends no insights keeps the stored ones.
- Alerts for a new review (1–2★ is important), a TestFlight build ready to test, and a build expiring within 7 days.
- Change detection compares versions, not labels, so relabelling ("10 (1.0.10)" → "1.0.10") isn't news.
- Google Play reviews are not read: that API needs the "Reply to reviews" permission, which isn't read-only.

### Added: automatic store refresh and change alerts
- Connected consoles are read on launch and every 30 minutes while the app is open (Settings → Integrations →
  Automatic refresh).
- `StoreChangeDetector` compares consecutive console reads: a version went live, the review phase changed
  (e.g. rejected), or a different version is waiting. Seed/screenshot data never triggers an alert.
- Changes appear in the dashboard's "Store changes" panel and as local notifications (macOS and iOS).

### Added: App Store Connect and Google Play Console (read-only)
- App Store Connect API client (ES256 JWT, GET only) and Google Play Developer API client (RS256 service
  account, releases list without edits). Keys are added in Settings → Integrations and kept in the Keychain.
- Store screens get "Refresh from App Store Connect" / "Refresh from Play Console": live and submitted
  versions and review states, each with a dated API source.
- 9 tests with generated keys and stubbed responses (83 in total).

### Added: verified product registry
- Evidence kinds for local files: Git repository, project configuration, Xcode project, package manifest and Gradle
  configuration, plus `other`. The seed (revision 4) classifies each local source by the file it read. Unknown kinds
  decode as `other` instead of failing the load.
- Derived registry accessors: product `verificationState`, `verificationBreakdown` by area and `sources`; repository
  `localPath`, `latestCommit`, `verificationState`, `source`, and the platforms evidenced by each repository.
- A Verification tab in product detail: overall state, per-area counts, items needing confirmation and every source.
- `RegistryTests`: 8 focused tests (74 in total).

### Changed: renamed to Linumic OS
- The product, app display name, Xcode project, target, scheme and product (`LinumicOS.app`), UI text, Dari
  translations, release script and docs. The GitHub repository was renamed to `aminullah-dev/LinumicOS`.
- Kept stable on purpose: bundle ID `com.linumic.commandcenter` (signing, Sign in with Apple, sandbox data), the
  Keychain service, the `Application Support/LinumicCommandCenter` folder, applied Supabase migrations, and evidence text
  recorded before the rename. In-app owner confirmations recorded under the old name are still recognised.

### Added: cloud sign-in and sync (Supabase)
- Sign in with Apple (native, nonce-protected) → Supabase session in the Keychain with auto-refresh.
- `RemoteInventoryStore` + `HybridInventoryStore`: the server is the source of truth with a local offline cache.
  The first connection uploads the local inventory, and offline edits upload at the next sync.
- Settings → Account → Cloud section (English + Dari). 11 new tests (66 total).

### Added: Supabase backend foundation
- Project `linumic-command-center` (ca-central-1, Free). Migrations in `supabase/migrations/`.
- Schema mirroring the model, with the evidence rules as database constraints, admin-only row-level security,
  an append-only audit log, and whole-inventory export/import RPCs in the app's JSON shape. All tested;
  the security advisor is clean.
- The app isn't connected yet (next: Sign in with Apple and RemoteInventoryStore).

### Added: Google Play Console data (seed revision 3)
- Read in the owner's Chrome, view only: production versions for SafeBeauty (2.1.5) and NerkhTimes (1.0.10), Afghan
  Prayer Times 1.1.0 in production review, and WorkTrack and VELRO Driver/Ride in closed testing. Each is recorded with
  a Play Console source.
- The dashboard's "Products on the App Store / Google Play" now counts only live (production) versions.

### Added
- Owner answers applied (seed revision 2): AfghanJama = KhayatYar = Tailor ERP; Darzi sidelined;
  Gul-E-Lala removed; Radar-system and Explore Afghanistan sidelined; MediFlow medical and high priority;
  SODER-HAKEM is a book; legal owner Aminullah Hashemi, with Linumic as the umbrella brand.
- New product fields: **Legal owner** and **Priority** (high / normal / low / sidelined). Sidelined
  products sink to the bottom of lists and are left out of the assistant's attention answers.
- Seed upgrades: an inventory nobody has edited is rebuilt from a newer seed (and archived first).
  An edited inventory is kept, and the user is told.
- **iOS / iPadOS**: the same target now builds for iOS 18+ (the App Sandbox entitlements are macOS-only).
- First notarised release (0.1.0) accepted by Apple on 2026-09-23. The release archive now targets macOS explicitly,
  since the multiplatform target otherwise archives for iOS.
- Signing with team 27RXPRW77S. `tools/release/build-release.sh` produces a Developer ID–signed build and
  notarises it once a `LinumicCommandCenter` notarytool profile exists.

### Added: Dari (دری) language
- A complete Dari UI (`fa-AF`): 527 strings, including enum titles, errors, empty states and
  every assistant answer template. Settings → Account → Language (System / English / دری) with relaunch.
- Right-to-left: SwiftUI content is mirrored through the environment, and AppKit (window controls,
  split view, sheets, menus) through the app-only writing-direction defaults, because macOS has no
  Persian system localization.
- Persian digits and the Solar Hijri calendar with Afghan month names via the `fa_AF` locale.
- The assistant understands Dari questions: matching removes the ZWNJ and maps Arabic ي/ك to ی/ک.
- `tools/l10n/check_catalog.py` finds untranslated strings and mismatched format specifiers.

### Fixed
- A `[String: Bool]` literal in `Product.setField` could trap on duplicate keys when "Yes" had no translation.

### Added: AI assistant (local, grounded)
- `Assistant` answers the suggested questions (attention, blocked, this week's changes, critical
  issues, readiness, planned features, market needs) and product-status questions only from
  records. Every statement is labelled Verified, Derived (rule stated) or Unknown, with its basis.
  It understands English and Persian keywords. No language model is involved.
- AI Assistant screen with suggestions, answer cards and links to products. Go → AI Assistant (⌘8).
- docs/backend-plan.md: when to build the backend, its recommended shape and a draft API contract.

### Changed
- Dashboard verification tiles stack the badge above the count so the number is never cut off.

### Added: Market intelligence and marketing
- Market Intelligence screen: sources, evidence (with source and dates) and findings (citing
  evidence; derived findings state their method). Changes that would break these rules are refused.
- Content Calendar: posts with networks, product, campaign and language, plus a workflow with
  approval tracking. Publishing is recorded by hand with the post's link, and nothing is posted.
- Social Media screen lists recorded accounts. No network is connected.

### Added: Stores
- App Store and Google Play screens list every recorded listing with its evidence.
- Public App Store refresh (`AppStoreLookupClient`, `StoreSync`): live version, seller and
  storefront from Apple's public lookup, with no credentials. Unpublished apps are reported
  and never overwritten.

### Added: GitHub integration (read-only)
- `GitHubClient` (GET only) and `RepositorySync`: repository metadata, latest commit,
  releases, open PRs and issues, languages and CI conclusion, stamped with `fetchedAt`.
- Settings → Integrations: GitHub token saved to or removed from the Keychain, plus Refresh All.
- Repositories table: CI column, fetch date, Refresh from GitHub (⌘R), failure report.
- Dashboard GitHub panel: failing CI, open PRs, last snapshot time.
- Opt-in live test against api.github.com (`GITHUB_TOKEN`).

### Fixed
- `gitHubSlug` removed every ".git" substring, so `nerkhtimes.github.io` became
  `nerkhtimeshub.io`. Now only a trailing ".git" is stripped.
- The Keychain store falls back to the login keychain when the data-protection keychain
  entitlement is missing (ad-hoc builds).

### Added: verified product inventory (schema 2)
- Evidence model: `Fact`, `Verification` (VERIFIED / PARTIALLY VERIFIED / UNKNOWN /
  CONFLICTING), `Source` (kind, reference, observed date), integrity rules and roll-up.
- Several typed repositories per product (`RepositoryType`), with a verified product link,
  a GitHub snapshot and local checkouts.
- Platform records with evidence, and store listings (several per store).
- Unresolved items (possible products, repositories with unclear ownership).
- Seed rebuilt from read-only evidence by `tools/inventory/build_seed.py`: local repositories,
  the GitHub API, linumic.com, the App Store lookup API, Google Play pages and the owner's
  App Store Connect screenshot. Evidence snapshots are in `tools/inventory/evidence/`.
- `docs/product-discovery-report.md`.
- UI: verification badges with evidence popovers on every fact, fact/platform/repository/
  listing editors that require a source, a Verification screen (needs confirmation,
  conflicts first), verification overview on the dashboard, and new list columns.
- Accessibility pass (ui-ux-pro-max): badges use icon + text with primary-color text for
  contrast, Dynamic Type sizes, and VoiceOver labels.
- Older inventory files are archived (never deleted) and replaced by the verified seed.

### Fixed
- The inventory file was never found because `URL.path()` percent-encoded the space in
  "Application Support", so the app reseeded and overwrote saved data on every launch.
  Regression test added.

### Removed
- Kabul Signal, at the owner's instruction (a separate organization).

## [0.1.0] - 2026-09-23

### Added
- Project structure, documentation and security architecture.
- `LinumicCore` package: product domain model, JSON inventory store, dashboard
  summary, Keychain secret store, repository-host integration interface.
- Seed inventory of 12 known products with GitHub repositories verified from
  local Git remotes on 2026-09-23.
- macOS app (SwiftUI, sandboxed): sidebar navigation, dashboard, product
  table with search, product detail with editable releases, repositories,
  roadmap, issues, deployments and store listings; cross-product tables for
  releases, roadmap, issues, repositories and deployments; Quick Open (⌘K),
  New Product (⌘N), Go shortcuts (⌘1–⌘6); screens for modules that aren't
  connected yet, saying plainly that no data is connected.
