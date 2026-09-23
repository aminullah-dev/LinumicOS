# Backend Plan

**Status:** planned, not built. On 2026-09-23 the owner said not to start the cloud backend yet.
Until then the Mac app stores everything locally (sandboxed JSON file plus Keychain).

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
| Hosting | Managed Postgres + a small API service (Supabase is the leading candidate: Postgres, auth, row-level security, Vault) | Least operations for a small team; RLS gives server-side role checks |
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
