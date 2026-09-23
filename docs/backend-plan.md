# Backend Plan

**Status (2026-09-23):** the owner chose **Supabase**. The project is created, and the schema, security and
import/export are in place and tested. The app doesn't use it yet: the next step is Sign in with Apple, then
`RemoteInventoryStore`.

| | |
|---|---|
| Organization | `mjkdmjrjalelcmqwdwok` (Free plan) |
| Project | `linumic-command-center`, ref `mczuclgfqxffcbiwvecf`, region **ca-central-1** |
| API URL | `https://mczuclgfqxffcbiwvecf.supabase.co` |
| Migrations | `supabase/migrations/` (applied: core_schema, inventory_import_export, private_is_admin) |

### What's built
- Tables mirroring the model: products (facts as JSON, validated), repositories, platforms, store_listings, releases,
  roadmap_items, issues, deployments, unresolved_items, market_sources/evidence/findings (plus the join table),
  content_items, inventory_meta.
- **Evidence rules enforced by the database:** a VERIFIED / PARTIALLY VERIFIED fact needs a source and a date; a
  derived finding needs a method; evidence needs a source and a collection date; a published or scheduled post
  needs approval (and a link, if published). Tested: every violation is rejected.
- **Row-level security** on every table. Only users listed in `app_admins` can read or write. Tested: the anon
  key and signed-in non-admins see 0 rows, and export is refused. `private.is_admin()` isn't exposed through the API.
- **Append-only `audit_events`**, written by trigger: who, what, when, before and after.
- `export_inventory()` / `import_inventory(doc)` RPCs in the app's exact JSON shape. Import only touches rows
  that changed. Tested: two identical imports leave the audit log unchanged.
- Supabase security advisor: **0 findings**.

### App connection (implemented 2026-09-23)
- The owner enabled the Apple provider (Client ID `com.linumic.commandcenter`).
- LinumicCore: `SupabaseSessionManager` (native Sign in with Apple via the `id_token` grant with a hashed nonce,
  Keychain session, auto-refresh), `RemoteInventoryStore` (export/import RPC), and `HybridInventoryStore`
  (server + local offline cache; the first connection uploads local data; offline edits are pushed at the
  next sync). No third-party dependency. Only the publishable key is in the app (Info.plist).
- Settings → Account → Cloud: Sign in with Apple, user ID, sync status, Sync Now, Sign Out.
- Building a signed app with Sign in with Apple needs Xcode signed in to the owner's Apple ID
  (Settings → Accounts), so automatic signing can create the provisioning profile.

### Status (2026-09-23)
- The owner signed in with Apple (a personal Apple ID, not the developer account). Supabase user
  `f60cfcf6-2c35-4158-a270-8b084bb05e41` was added to `app_admins`.
- Next: press **Sync Now** in Settings → Account → Cloud. The first sync uploads the local inventory.
3. Later: scheduled GitHub and App Store syncs (Edge Functions + pg_cron); integration keys in Vault.

## When to build it

Any one of these makes the backend worth building:

1. More than one person needs the Command Center (roles, audit log).
2. The inventory is needed on a second device (iPhone/iPad or web).
3. Integrations need credentials that shouldn't live on one laptop (App Store Connect `.p8`,
   Google Play service account, social OAuth, AI provider keys).
4. Scheduled syncs are wanted, such as GitHub and store status every hour while the Mac is closed.

## Recommended shape

| Concern | Recommendation | Why |
|---|---|---|
| Database | PostgreSQL | The schema is relational: products → repositories/platforms/listings → evidence |
| Hosting | **Supabase** (Postgres, auth, row-level security, Vault) **or Firebase** (Firestore, Auth, Functions), as the owner decides | Both are managed. Supabase fits the relational schema. Firebase is already used by SafeBeauty, WorkTrack and Talar. |
| Auth | Sign in with Apple / passkeys; short-lived tokens; refresh token in the Mac Keychain | See [security.md](security.md) |
| Secrets | Server-side secret store (Supabase Vault or GCP Secret Manager) | Integration credentials leave the laptop |
| Sync jobs | Scheduled functions calling the same read-only clients (`GitHubClient`, `AppStoreLookupClient`) | The logic already exists in LinumicCore and is tested |
| Audit | Append-only `audit_events` (who, what, before/after, source: user/sync/assistant) | Required for every write and external action |

## API contract (draft)

The JSON shapes are the existing `Codable` types in LinumicCore, so the Mac app switches from
`JSONFileInventoryStore` to a `RemoteInventoryStore` behind the same `InventoryStore` protocol.

```text
GET    /v1/products                         Product[] (with facts + verification)
GET    /v1/products/{id}
PATCH  /v1/products/{id}/facts/{field}      { value, verification }   → audit event
POST   /v1/products                         Product                   → audit event
GET    /v1/unresolved                       UnresolvedItem[]
GET    /v1/market                           MarketIntelligence
POST   /v1/market/{sources|evidence|findings}   (server enforces the citation rules)
GET    /v1/content                          ContentItem[]
POST   /v1/content/{id}/transition          { to, scheduledFor?, publishedURL? }  (server enforces the workflow)
POST   /v1/sync/github                      starts a read-only refresh (admin only)
POST   /v1/sync/appstore                    starts a public lookup refresh (admin only)
GET    /v1/audit?entity=…                   AuditEvent[]
```

## Migration

1. Export the local `inventory.json` (schema 2).
2. Import it into the backend. Every fact keeps its sources and dates.
3. Switch the app to `RemoteInventoryStore`, keeping the local store as an offline cache.
