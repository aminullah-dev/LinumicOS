# Architecture

## Shape (2026-10-19)

```text
Mac client (SwiftUI, menu bar)       iOS/iPadOS client (same target)       Web client: not planned
        │                                      │
        └────────────── LinumicCore (Swift, shared) ──────────────┘
                                     │  InventoryStore protocol
                          HybridInventoryStore
                     ┌───────────────┴────────────────┐
             JSONFileInventoryStore            RemoteInventoryStore
             (local cache, this device)        (Supabase RPCs, Sign in with Apple)
                                                       │
                                     Supabase (Postgres, RLS, audit; licences,
                                     oversight, Sentinel: pg_cron + Edge Function)

External integrations (GitHub, App Store Connect, Google Play, WorkTrack, Talar, SafeBeauty, VELRO, WordPress) are
called from the device with the owner's keys in its Keychain, read-only except the confirmed actions listed below.
Moving their credentials server-side is still open (docs/backend-plan.md).
```

## Technology decision (2026-09-23)

Environment inspected: Xcode 27.0, Swift 6.4, macOS 27 SDK (arm64), Node 24,
npm 11, Git 2.54, GitHub CLI 2.96 (authenticated), Python 3.9, XcodeGen, gcloud.
Not installed: Docker, pnpm, Supabase CLI, AWS/Azure CLIs.

| Layer | Choice | Reason |
|---|---|---|
| Clients | One SwiftUI target for **macOS 15+ and iOS/iPadOS 18+** (the owner chose Mac + iOS for now; no web) | Native conventions on each platform; shared LinumicCore |
| Shared core | `LinumicCore` Swift package, no third-party dependencies | Reusable by iOS/iPadOS without changes; `swift test` runs without Xcode UI |
| Persistence (MVP) | Codable JSON file behind `InventoryStore` | Portable, inspectable, and the same DTO shape a future REST API returns. SwiftData was avoided so the domain model isn't tied to Apple persistence. |
| Project generation | XcodeGen (`project.yml`) | Reviewable project definition, no merge conflicts in `.pbxproj` |
| Secrets | macOS Keychain via `SecretStore` | See [docs/security.md](docs/security.md) |
| Cloud backend | **Supabase** (Postgres, RLS, audit), project `mczuclgfqxffcbiwvecf`, ca-central-1. See [docs/backend-plan.md](docs/backend-plan.md) | Relational data, server-side rules and roles; the app uses it through `HybridInventoryStore` since 2026-09-23 |

## Modules

| # | Module | MVP state |
|---|---|---|
| 0 | Project oversight | All owned repositories under read-only scrutiny: 0–100 fleet health, per-repo health, latest changes and GitHub security posture (`OversightRepo`, `OversightSync`, `OversightSummary`). Local `.git` scan is Increment 2. |
| 0a | Platforms hub | One card per product: version on `main` (GitHub contents API), latest release with download counts, CI per workflow on main, open PRs, store versions from the inventory, drift flags, business model and admin/public links with sources (`PlatformCatalog`, `PlatformSync`, `PlatformDrift`). Per-device cache `platform-hub.json`, conditional (ETag) requests. |
| 0b | Licences | LNM1 offline licences for MediFlow and KhayatYar: issue, renew, void (`LinumicCore/Licensing`), ledger on Supabase with a local cache, signing keys in the Mac Keychain. See docs/integrations.md. |
| 0c | WorkTrack customers | Vendor sign-in (Firebase REST, refresh token in the Keychain), every customer company with licence, orders, revenue and audit, and licence renewal through `PUT /vendor/companies/:id/license` with a before/after diff, typed confirmation and a re-read (`WorkTrackVendorClient`, `WorkTrackRenewal`). Local action log `worktrack-actions.json`. See docs/integrations.md. |
| 0d | Operations | Talar, SafeBeauty and VELRO admin overviews (`TalarAdminClient`, `SafeBeautyAdminClient`, `VelroStaffClient`, `FirestoreREST`), one Keychain session each, read-only except Talar's audited hall approve/reject; "Waiting for you" dashboard card and 0-to-waiting notifications from a counts-only store. Local log `operations-actions.json`. See docs/integrations.md. |
| 0e | Vault | The owner's own sign-ins in this device's Keychain only (`VaultStore`, service `com.linumic.commandcenter.vault`): Touch ID / device password before a password is shown, copied or filled, 2-minute unlock, concealed clipboard cleared after 30 s, "Fill from Vault" and "Save to Vault" in the WorkTrack, Talar, SafeBeauty and VELRO sign-in sheets (`VaultMatcher`). See docs/security.md. |
| 0f | Monitor | Live health of every public endpoint (`MonitorCatalog`, each URL cited to its repository file and line): plain GETs with no credentials, status/latency/parsed health (`MonitorEvaluator`), TLS leaf notAfter read in the App's URLSession trust challenge, linumic.com expiry from public RDAP (`RDAPClient`), home-page caching headers, 24-hour on-device history with uptime and sparkline, two-failure debounce and 30/14/7-day windows (`MonitorSnapshot`, `MonitorAlertState`), every 5 minutes with backoff. Local file `monitor.json`; Dashboard "Live status" strip. See docs/integrations.md. |
| 0g | Releases (Release Center) | One screen for every store and repository (`LinumicCore/Releases`): App Store versions with their build, release type and state mapped to phases, builds with processing state (`AppStoreConnectClient.releaseVersions`, `releaseBuilds`); Google Play tracks with status, rollout share and release-note languages through an edit that is deleted and never committed, falling back to releases.list (`GooglePlayClient.releaseCenterStatus`); open PRs with mergeability and per-commit CI rollup, CI on the default branch, last release or tag (`GitHubClient.releaseStatus`, GET only); stacked PR detection in merge order (`PullStacks`); "Waiting on you" rules (`WaitingOnYou`). One write: `AppStoreReleaseAction` (state check, `POST /v1/appStoreVersionReleaseRequests` once, read-back), confirmed per action, logged in `release-actions.json`. Last reading cached in `release-center.json`. App layer: `ReleaseCenterModel` (Keychain credentials of the existing integrations, URLSession, schedule) and `ReleaseCenterViews`. Dashboard "Releases: waiting on you" card. See docs/integrations.md. |
| 0h | Daily Brief | Local only (`LinumicCore/Brief`): `DailyBriefBuilder` turns a `BriefInput` (Monitor snapshot, Release Center snapshot, licence ledger, WorkTrack companies, Operations counts, Oversight register) into sections of `BriefLine`s, each with severity, source, read time and a `BriefDestination`; never-read sources become `.neverRead` instead of zeros. `BriefDailySnapshot`/`BriefSnapshotHistory`/`BriefDiff` keep one snapshot per day (`brief-snapshots.json`) and list what changed since the last earlier day. `BriefNotificationText` and `BriefSchedule` word and time the optional morning notification. App: `BriefModel` (collects model state, records the snapshot after each refresh round, schedules the notification) and `BriefViews`. |
| 0i | Command Palette | ⌘K (`CommandPaletteView`, replacing Quick Open): `PaletteText` normalisation (case, accents, Arabic/Persian letter forms, ZWNJ, bidi marks, digits), `FuzzyMatch` and `PaletteRanker` (multi-word, title over keywords, recent bonus) and `PaletteRecents` in `LinumicCore/Palette`. Candidates are screens, records (Vault titles only) and existing actions; choosing one navigates through `Router` (`RouterRequest` for a licence, a WorkTrack company, the issue-licence sheet, a new Vault entry or a Vault search). It never writes: actions that change something open their screen and its confirmation. |
| 0j | Keys & Backups | Registry of signing keys, licence keys and encrypted off-Mac backups, every fact with source and day (`LinumicCore/Keys`: `KeysRegistry` with the 2026-10-09 seed, corrected 2026-10-18 (seed revision 2), `KeysRegistryStore` → `keys-registry.json`). Local checks behind `KeyFileSystem` (attributes only: exists, size, modification date; `LocalKeyFileSystem` uses FileManager attributes and directory listings, never file contents): `KeyChecker` per registry path or `AuthKey_*.p8`-style pattern, `KeysScanner` by file name (`*.jks`, `*.keystore`, `*-private.pem`, `AuthKey_*.p8`; skips node_modules/build/.git and links; ignores debug.keystore) in five fixed folders, `KeyAccess` for the sandbox grants (ungranted = "not granted", never guessed). `KeysRules`: backup state per key (covered, changed on a later day than its newest backup, not backed up), unregistered key files, restore test older than 90 days, open second-copy gap, passphrase Keychain item missing. App: `KeysModel` (read-only security-scoped bookmarks plus the Oversight workspace, Keychain presence via attributes only), `KeysViews`; reminders become the Brief's Keys section; palette "Mark restore test done…" opens the sheet. iOS shows the registry only. |
| 0k | Website messages | linumic.com contact-form entries (`LinumicCore/SiteMessages`): `SiteMessagesClient` runs the read-only SureForms abilities `sureforms/list-entries` and `sureforms/bulk-get-entries` through WordPress core `/wp-json/wp-abilities/v1/abilities/{name}/run` (GET, application password, Keychain `wordpress.linumic.apppassword`); `SiteMessagesParser` (fields to name, email, message; site time Asia/Kabul), `SiteMessagesState` (seen and notified ids, `site-messages.json`), `SiteMessageText` (140-character excerpt, safe mailto), `SiteMessagesNotificationText`. App: `SiteMessagesModel`, `SiteMessagesViews`; a Daily Brief section with per-line links (`BriefLink`), a Dashboard "Waiting for you" row and palette entries. See docs/integrations.md. |
| 0l | Desk and Ledgers | Phase 1 of [docs/company-os-roadmap.md](docs/company-os-roadmap.md). The home screen (`LinumicCore/Desk`): `DeskBuilder.build(brief:ledgers:state:now:)` turns every Daily Brief line (routing through `BriefDestination`) and every open ledger item into `DeskItem`s (id `<origin>\|<subjectKey>\|<kindKey>`), grouped by product (`DeskDomain`, focus WorkTrack then SafeBeauty) into Today / This week / Later; a source not read, not granted, not found or unreadable, a part of a Brief section not read (`BriefSection.gaps`: a product not signed in, a store without a key), an old «آخرین بازبینی» and lines set aside are items of their own, never zero. Ledgers: `LedgerParser` (PRIORITIES.md: `- [ ]` at any indentation, the numbered list under «اولویت», P0 high, P1 normal, the lines indented under each item as its notes, any line break including CRLF), `NextActionsParser` (the owner's TODAY and THIS WEEK items with their «منبع: Product / slug»), `LedgerAllowList` (8 PRIORITIES.md files and the newest NEXT-ACTIONS-<day>.md, exact paths) and `LedgerReader` behind `LedgerFileSystem`. `DeskState` (Done until the next reading for Brief lines, until the line changes for ledger lines; Snooze; Waiting on others and Dismiss until the fact hash changes; a Brief mark is dropped only after a later reading of its own part) in `desk-state.json` (ids, kinds, times, hashes and reasons, no titles); `DeskAgentBrief` (Dari, file:line). App: `DeskModel` (read-only bookmarks `LCCLedgerBookmarks`, Mac only), `DeskViews`, "Ledger access" in Settings → Integrations, the `ledgers` automation job (30 min, no network, before the Brief), palette entries. |
| 0m | Automation and Sentinel | `AutomationEngine` (App) runs every job of `AutomationCatalog` on its own schedule (`AutomationScheduler`: cadence, backoff, offline, wake, pause, Low Power), one at a time, records each run in `automation.json`, notifies after 3 failures; menu bar, login item, iOS background refresh. The backup job is due again a minute after its file is gone from `Backups/` (`AutomationJobState.artifact`), and `InventoryBackup.status()` (what the folder holds, read back) feeds the Desk and the Brief, never the log alone. Sentinel on Supabase (deployed 2026-10-19): the same health checks every 10 minutes, a daily licence sweep, a weekly `inventory_snapshots`. See [docs/automation.md](docs/automation.md), [docs/sentinel.md](docs/sentinel.md). |
| 0n | Obligations and accounts | Phase 2 of the company OS roadmap (`LinumicCore/Obligations`). `Obligation` (what, due day or unknown, consequence, source, recorded day, 30/14/7/1-day lead windows), `VendorAccount` (purpose, holder personal or company, renewal, cost, each with a source), `ObligationSeed` (only facts recorded with a source), live rows from RDAP, TLS, the licence ledger, the keys registry and the continuity log, `ObligationsBuilder.validate` (no row without a source, no Done without evidence), lanes, `ObligationAlerts` (key `obligation:<id>:<due>:<lead>`), and a Daily Brief section, so the Desk shows them by due day and window. App: `ObligationsModel` (`obligations.json`), `ObligationsViews`. See [docs/obligations.md](docs/obligations.md). |
| 0o | Continuity | Phase 2 of the company OS roadmap (`LinumicCore/Continuity`). `ContinuityBundle` (inventory, obligations, accounts, licence ledger without key text, keys registry; refuses key and token patterns), `AgeFile` + `Scrypt` (age v1 with a passphrase, CryptoKit only, checked against age's test vectors), `ContinuityExporter` (write, read back, decrypt, compare), `ContinuityLog` (`continuity.json`: evidence, later checks, "opened outside this Mac"). App: `ContinuityModel` (read-write folder bookmark, passphrase never stored), `ContinuityViews`. See [docs/continuity.md](docs/continuity.md). |
| 0p | Money | Phase 4 of the company OS roadmap (`LinumicCore/Money`), read-only. `MoneyBuilder` turns what the WorkTrack and SafeBeauty models already read, plus the obligations register's accounts, into ten `MoneyFigure`s: HesabPay received, CRM invoices paid, renewals expected (forecast), CRM outstanding and past due (Kabul's date), salons owed and owing (never netted), account costs per currency and billing cycle, App Store and Google Play proceeds (always Unknown). `MoneyAmount`/`MoneyTotals` keep every amount in its own currency with no API for a sum across currencies. TEST and DUPLICATE companies are left out of CRM invoices through account, company and flags; without the marks the invoices are Unknown. Reads: `WorkTrackVendorClient.crmAccounts()`/`crmInvoices()` (`WorkTrackMoneyReader`), `SafeBeautyAdminClient.balanceTotals()` over `FirestoreREST.aggregate` (count and sum); uncached sessions. `MoneyBrief` is a Daily Brief section (lines with counts, every Unknown a gap), so the Desk shows salons to pay, invoices past due and each Unknown. App: `MoneyInput.collect`, `MoneyViews`; no model or file of its own. See [docs/money.md](docs/money.md). |
| 0q | Sales | Phase 5 of the company OS roadmap (`LinumicCore/Sales`), read-only. `SalesBuilder` turns Money's WorkTrack reading (company list and CRM accounts, whose `WTCrmAccount` now also decodes `stage`, `nextActionAt` as `WTCrmDay`, and `nextAction`), the website messages and SafeBeauty's KYC roles into a `SalesReport`: follow-ups by Kabul's day (`SalesDue`, the server's own rule), open accounts with no next step, signups with no CRM account, renewals, messages and a KYC count, each part `SalesRead` (read, or Unknown with a reason). `SalesBrief` is a Daily Brief section whose lines carry a `horizon` (`BriefLine.horizon`) instead of a device day and a `SalesKey` hash in their ids; limits and the environment are `BriefGap`s with `isDeskItem == false`. `SalesDraft` writes Dari and Pashto reminders from facts read only; `SalesDismissReason` fixes the dismiss reasons of Sales Desk items. Reads: `WorkTrackSalesReading` (`crmContacts(accountId:)`, `crmAccountsShape()` → `WTShapeReport`), on demand only. App: `SalesInput.collect`, `SalesViews`, the Sales reads and one `ClipboardGuard` on `WorkTrackModel`; no model or file of its own. See [docs/sales.md](docs/sales.md). |
| 1 | Dashboard | Implemented from local data |
| 2 | Products | Implemented, with verification and evidence on every fact |
| 3 | Version & release management | Manual records (sidebar "Release records"); live store and repository state is in Releases (0g) |
| 4 | Repository management | Typed repositories with verified links, and read-only GitHub sync (`GitHubClient`) |
| 5 | App Store / Google Play | Listings with evidence and the public App Store lookup; App Store Connect and Google Play are read with the owner's keys by the Store listings job and the Release Center (0g). |
| 6 | Social media | Content calendar with approval workflow. Networks aren't connected. |
| 7 | Market intelligence | Source → evidence → finding register with enforced citations ([docs/market-intelligence.md](docs/market-intelligence.md)) |
| 8 | AI assistant | Local, grounded answer engine (`Assistant`): Verified / Derived / Unknown labels, English and Persian questions, no language model |

## Core concepts (LinumicCore)

- `Product` and its child records (`Release`, `RepositoryRecord`, `RoadmapItem`,
  `IssueRecord`, `Deployment`, `StoreListing`, `SocialAccount`, `DocumentLink`).
  See [PRODUCTS.md](PRODUCTS.md).
- **Unknown is explicit.** An unknown fact is stored as `nil` or `.unknown` and
  never replaced with a guess. The UI shows it as "Unknown — to be verified".
- **Provenance.** Each product carries a `Provenance` (source + when it was
  recorded) so we can tell verified data apart from manual entries.
- `InventoryStore`: async load/save of the whole inventory. The MVP uses one
  file, which is fine for dozens of products. The remote store will replace it
  with per-entity endpoints behind the same service API.
- `DashboardSummary`: derived metrics computed from the inventory, so they are
  *derived analysis* and never stored as fact.
- `SecretStore`: Keychain-backed credential storage.
- `RepositoryHostClient`: read-only integration boundary for GitHub.

## AI assistant

Implemented as `Assistant` (LinumicCore/Services). It's deterministic: it classifies the
question (English or Persian keywords, or a product name), then answers only from the
inventory, GitHub and App Store snapshots, and reviewed market findings. A language model
can later be added for phrasing, but it may only restate these grounded statements. Rules:

1. It answers only from retrieved records, never from model memory, for
   anything about project status.
2. Every answer labels its statements as **Verified** (a record with a source
   and timestamp), **Derived** (computed from verified records, with the method
   stated) or **Unknown**.
3. It is read-only by default. Any action (creating an issue, drafting a post)
   produces a proposal that a person must approve.
4. The owner will buy an **Anthropic API key** later, for optional phrasing only. It goes in the
   Keychain (or on the backend once one exists), never in source. It isn't wired up yet, deliberately.

## Client rules

- Views hold no business logic. They call `InventoryModel` (app) which calls
  LinumicCore services.
- Nothing pushes, merges, deletes or modifies a remote repository or a store
  listing without explicit, per-action user confirmation.
