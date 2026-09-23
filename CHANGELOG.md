# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
