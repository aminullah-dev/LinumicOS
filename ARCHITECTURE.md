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
| Mac client | SwiftUI, macOS 15+ deployment target | Native conventions, sidebar, tables, dark mode and keyboard support built in |
| Shared core | `LinumicCore` Swift package, no third-party dependencies | Reusable by iOS/iPadOS without changes; `swift test` runs without Xcode UI |
| Persistence (MVP) | Codable JSON file behind `InventoryStore` | Portable, inspectable, and the same DTO shape a future REST API returns. SwiftData was avoided so the domain model isn't tied to Apple persistence. |
| Project generation | XcodeGen (`project.yml`) | Reviewable project definition, no merge conflicts in `.pbxproj` |
| Secrets | macOS Keychain via `SecretStore` | See [docs/security.md](docs/security.md) |
| Cloud backend | **Not yet chosen, decision deferred** | Options to evaluate: Supabase (Postgres + auth + RLS), a Swift (Vapor) or Node API on managed Postgres, Firebase. Pick when multi-user or multi-device access is actually needed. |

## Modules

| # | Module | MVP state |
|---|---|---|
| 1 | Dashboard | Implemented from local data |
| 2 | Products | Implemented (list, detail, edit) |
| 3 | Version & release management | Implemented (manual records) |
| 4 | Repository management | Manual records. GitHub sync is interface only (`RepositoryHostClient`). |
| 5 | App Store / Google Play | Data fields only, no integration |
| 6 | Social media | Data fields only, no integration |
| 7 | Market intelligence | Design only ([docs/market-intelligence.md](docs/market-intelligence.md)) |
| 8 | AI assistant | Design only (see below) |

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

## AI assistant (design)

The assistant will answer over the inventory, integration snapshots and market
data. Rules:

1. It answers only from retrieved records, never from model memory, for
   anything about project status.
2. Every answer labels its statements as **Verified** (a record with a source
   and timestamp), **Derived** (computed from verified records, with the method
   stated) or **Unknown**.
3. It is read-only by default. Any action (creating an issue, drafting a post)
   produces a proposal that a person must approve.
4. Model API keys live server-side once a backend exists. Until then they go in
   the Keychain, never in source.

## Client rules

- Views hold no business logic. They call `InventoryModel` (app) which calls
  LinumicCore services.
- Nothing pushes, merges, deletes or modifies a remote repository or a store
  listing without explicit, per-action user confirmation.
