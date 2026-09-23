# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
