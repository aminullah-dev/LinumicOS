# Architecture

## Target shape

```text
Mac Client (SwiftUI)        iOS/iPadOS client (later)      Web client (later)
        │                            │                            │
        └──────────── LinumicCore (Swift, shared) ────────────────┘
                                     │  InventoryStore protocol
                     ┌───────────────┴────────────────┐
             JSONFileInventoryStore            RemoteInventoryStore (later)
             (local, MVP)                              │
                                               API / Cloud Backend (later)
                                                       │
                                                   Database
                                                       │
                                     External integrations (GitHub, App Store
                                     Connect, Google Play, social, AI), called
                                     server-side only
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
| Cloud backend | **Supabase** (Postgres, RLS, audit), project `mczuclgfqxffcbiwvecf`, ca-central-1. See [docs/backend-plan.md](docs/backend-plan.md) | Relational data, server-side rules and roles; the app will switch to it through `InventoryStore` |

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
| 0j | Keys & Backups | Registry of signing keys, licence keys and encrypted off-Mac backups, every fact with source and day (`LinumicCore/Keys`: `KeysRegistry` with the 2026-10-09 seed, `KeysRegistryStore` → `keys-registry.json`). Local checks behind `KeyFileSystem` (attributes only: exists, size, modification date; `LocalKeyFileSystem` uses FileManager attributes and directory listings, never file contents): `KeyChecker` per registry path or `AuthKey_*.p8`-style pattern, `KeysScanner` by file name (`*.jks`, `*.keystore`, `*-private.pem`, `AuthKey_*.p8`; skips node_modules/build/.git and links; ignores debug.keystore) in five fixed folders, `KeyAccess` for the sandbox grants (ungranted = "not granted", never guessed). `KeysRules`: backup state per key (covered, changed on a later day than its newest backup, not backed up), unregistered key files, restore test older than 90 days, open second-copy gap, passphrase Keychain item missing. App: `KeysModel` (read-only security-scoped bookmarks plus the Oversight workspace, Keychain presence via attributes only), `KeysViews`; reminders become the Brief's Keys section; palette "Mark restore test done…" opens the sheet. iOS shows the registry only. |
| 1 | Dashboard | Implemented from local data |
| 2 | Products | Implemented, with verification and evidence on every fact |
| 3 | Version & release management | Manual records (sidebar "Release records"); live store and repository state is in Releases (0g) |
| 4 | Repository management | Typed repositories with verified links, and read-only GitHub sync (`GitHubClient`) |
| 5 | App Store / Google Play | Listings with evidence, plus the public App Store lookup refresh. Store consoles aren't connected. |
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
