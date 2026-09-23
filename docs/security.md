# Security Architecture

The Command Center will hold credentials that can publish apps, push code and
post as Linumic, so it is treated as a production system.

## Threat model (summary)

| Asset | Threat | Control |
|---|---|---|
| Integration credentials (GitHub, ASC, Play, social, AI) | Leak through Git, logs or backups | Keychain / backend secret store, `.gitignore` patterns, never logged |
| Inventory data | Tampering, loss | Sandboxed app container, and later a backend with audit log and backups |
| Repositories and store listings | Unintended destructive action | Read-only integrations, per-action confirmation for writes |
| Assistant | Invented status, prompt injection from ingested content | Grounded answers with verified/derived/unknown labels. Ingested text is treated as data, and actions are only proposals. |

## MVP (local app)

- **App Sandbox** is enabled. Entitlements: outgoing network (for future
  read-only integrations) and user-selected files (read-only).
- **Secrets** go through `SecretStore` → `KeychainSecretStore` (Security
  framework, generic-password items, service `com.linumic.commandcenter`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synced to iCloud). The store prefers the
  data-protection keychain. Ad-hoc signed development builds lack that entitlement and fall
  back to the login keychain, which is also device-local.
- **Stored credentials today:** at most one, the optional read-only GitHub token (`github.token`).
- **No secrets in source or Git.** `.gitignore` blocks `.env*`, `*.p8`, `*.p12`,
  `*.pem`, `*.key`, keystores, provisioning profiles and service-account JSON.
  Check `git diff --cached` before each commit.
- **Transport:** HTTPS only. App Transport Security stays at its default (no
  exceptions).
- **Local data** (`inventory.json`) sits inside the sandbox container and is
  protected by FileVault at rest. It holds no secrets.

## Backend phase

- **Authentication:** Sign in with Apple or passkeys for Linumic staff, with
  short-lived access tokens. The Mac client keeps its refresh token in the Keychain.
- **Role-based access:** `owner`, `admin`, `developer`, `marketing`, `viewer`.
  Permissions are checked on the server (row-level security or API middleware),
  never only in the client.
- **Least privilege:** each integration uses its own credential with the
  narrowest scope (read-only first), and credentials stay server-side.
- **Secrets management:** a managed secret store (for example, GCP Secret Manager
  or Supabase Vault, decided alongside the backend). Rotation is documented per
  credential.
- **Audit log:** append-only, recording who, what, when, before/after and source
  (user, sync, assistant) for every write and every external action.
- **Encryption:** TLS 1.2+ in transit, and provider encryption at rest for the
  database and backups.

## Rules for contributors

1. Never hard-code a credential, even temporarily.
2. Never paste real credentials into issues, docs, commits or AI prompts.
3. Anything that writes to an external system needs explicit per-action user
   confirmation and an audit entry.
