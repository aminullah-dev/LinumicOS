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
| 1 | Dashboard | Implemented from local data |
| 2 | Products | Implemented, with verification and evidence on every fact |
| 3 | Version & release management | Implemented (manual records) |
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
