# Security Architecture

Linumic OS will hold credentials that can publish apps, push code and
post as Linumic, so it is treated as a production system.

## Threat model (summary)

| Asset | Threat | Control |
|---|---|---|
| Integration credentials (GitHub, ASC, Play, social, AI) | Leak through Git, logs or backups | Keychain / backend secret store, `.gitignore` patterns, never logged |
| Inventory data | Tampering, loss | Sandboxed app container, and later a backend with audit log and backups |
| Repositories and store listings | Unintended destructive action | Read-only integrations, per-action confirmation for writes |
| WorkTrack customer licences (vendor account) | Wrong or accidental licence change, perpetual licence by omission | Refresh token only in the Keychain, one write (licence PUT) built from the fetched licence with `expiresAt` always sent, diff + typed confirmation in production, stale-licence check, no retry, local and server audit |
| Talar, SafeBeauty, VELRO admin sessions (Operations) | Leaked session, accidental production write, identity documents on disk, VELRO refresh-token replay signing the owner out everywhere | Refresh token only (Keychain), read-only clients with no write calls except Talar's audited hall decision, SafeBeauty field masks that never request identity fields, VELRO rotation persisted before use and never replayed, counts the only cached data |
| Vault (the owner's own sign-ins) | Someone at the unlocked Mac reading passwords, clipboard history keeping them, a copy leaving the device | Keychain only (device-only, not synchronizable), Touch ID or device password before any password is shown, copied or filled, 2-minute unlock, concealed clipboard cleared after 30 s |
| Monitor (public health checks) | A check leaking a session or cookie, a check that changes something, a lookalike host trusted | Ephemeral URLSession with no cookies, credential storage or cache; other auth challenges refused; GET only to the cited public URLs; default TLS trust evaluation (the certificate date is only read); only states and latencies stored, on this device |
| Release Center (store and repository state) | An accidental App Store release, a Play edit committed by mistake, a credential copied into a cache | One write only (`appStoreVersionReleaseRequests`), offered only for PENDING_DEVELOPER_RELEASE, behind a confirmation naming app, version and build, state re-checked first, sent once, read back and logged; Play edits are opened to read tracks and deleted, never committed (no commit call exists); GitHub GET only; credentials read from the existing Keychain items when needed, never copied; the cache holds observations only |
| Daily Brief and Command Palette | A summary or search result exposing a secret, a palette shortcut making a write | No requests and no credentials of their own; the daily snapshot (`brief-snapshots.json`, this device) holds states, counts and PR titles only; the palette indexes Vault titles and products, never logins or passwords, keeps only chosen ids as recents, and its actions only navigate or read (writes stay behind each screen's own confirmation) |
| Keys & Backups (registry and checks) | The app reading, copying or leaking a signing key, keystore password or backup passphrase; broad file access; a stale backup trusted | No key content is ever read: only FileManager attributes (exists, size, modification date) and directory listings, inside read-only security-scoped bookmarks the owner chose (plus the Oversight workspace); the passphrase item is looked up with `kSecReturnAttributes` only, never `kSecReturnData`; the registry (`keys-registry.json`, this device) holds paths, titles, days, sizes and Drive file ids, nothing secret; restore commands make openssl prompt for the passphrase, never pass it; no network |
| Assistant | Invented status, prompt injection from ingested content | Grounded answers with verified/derived/unknown labels. Ingested text is treated as data, and actions are only proposals. |

## MVP (local app)

- **App Sandbox** is enabled. Entitlements: outgoing network (for future
  read-only integrations) and user-selected files (read-write since 2026-10-09, see below).
- **Secrets** go through `SecretStore` → `KeychainSecretStore` (Security
  framework, generic-password items, service `com.linumic.commandcenter`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synced to iCloud). The store prefers the
  data-protection keychain. Ad-hoc signed development builds lack that entitlement and fall
  back to the login keychain, which is also device-local.
- **Stored credentials:** only optional read-only ones, each added by the owner in Settings: the GitHub
  token (`github.token`), the App Store Connect API key (`appstoreconnect.key`, Developer role) and the
  Google Play service account (`googleplay.serviceaccount`, "View app information"), plus the Supabase
  session. The console clients only read: GET requests, and Play's release list needs no edit.
- **Release Center (since 2026-10-09):** uses those same three Keychain items; it has no credential of its own and
  writes none. Reads: App Store Connect GETs, GitHub GETs, and Google Play tracks through an edit that is opened
  (`POST .../edits`), read (`GET .../edits/{id}/tracks`) and deleted (`DELETE .../edits/{id}`); an uncommitted edit
  changes nothing and the client has no commit call. If Play refuses the edit (a read-only account), it falls back to
  releases.list. The single write is `POST /v1/appStoreVersionReleaseRequests` for a version in
  PENDING_DEVELOPER_RELEASE: confirmation dialog naming app, version and build; the state is read again right before
  and nothing is sent if it moved; sent once, never retried; read back; recorded in the append-only
  `release-actions.json`. Apple allows it only to Admin and App Manager keys: with the Developer key described above,
  Apple answers 403 and the app says so (nothing changes). Upgrading means creating a new App Manager key (Apple can't
  raise an existing key's role) and replacing it in Settings; the reads keep working with either. The last reading is
  cached in `release-center.json` (versions, builds, tracks, PR titles and CI states; no tokens, no keys).
- **WorkTrack vendor session:** the owner types his vendor email and password in the sign-in sheet; the password is
  sent once, in the body of Firebase's `signInWithPassword` request, and is never stored or logged; the sheet clears
  the field after each attempt. Only the Firebase refresh token is kept, in the Keychain as `worktrack.vendor.session` (JSON with the
  environment and email beside it; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable). The one-hour
  ID token lives only in memory. Signing out deletes the item. WorkTrack checks the token for revocation on every
  request, so changing the password in Firebase ends the session at once. A vendor account reaches every WorkTrack
  customer, so: the only write in the client is `PUT /vendor/companies/:id/license`; it is sent once, never retried,
  only after a before/after diff and a typed company name in production, and only if the licence hasn't changed
  since the sheet opened; `expiresAt` is always sent (an omitted value would make the licence perpetual); every
  write is recorded in the local append-only `worktrack-actions.json` and in WorkTrack's own two audit trails.
  The Firebase Web API keys in `WorkTrackEnvironment` are public identifiers (shipped in every WorkTrack client), not
  secrets. The local emulator environment exists in debug builds only and speaks plain HTTP to `127.0.0.1`.
- **Operations sessions (Talar, SafeBeauty, VELRO):** one Keychain item each, `talar.admin.session`
  (`{environment, email, refreshToken}`), `safebeauty.admin.session` (`{environment, appUID, name, refreshToken}`) and
  `velro.staff.session` (`{environment, userID, roles, refreshToken, deviceID}`), all
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable, deleted on sign-out. Never stored: passwords,
  SafeBeauty's salt or derived Firebase password, phone numbers, ID/access tokens. The Talar and SafeBeauty passwords
  are sent once (Talar: in Firebase's sign-in body; SafeBeauty: to its `authenticateWithPassword` callable, as its own
  console does, then the PBKDF2-derived password to Firebase). The VELRO phone number is sent to request and verify the
  code and kept only in the sheet's memory; the app never logs it.
  - **Read-only by construction:** the Talar client has one write (`POST /admin/halls/:id/review`, audited by Talar,
    sent once, never retried, typed confirmation in production, logged in `operations-actions.json`); the SafeBeauty
    client calls no admin callable and no Firestore write; the VELRO client has no POST/PATCH under `/admin` and no
    `DELETE /auth/me`.
  - **SafeBeauty identity documents:** the KYC queue is read with a Firestore field mask (`name, role, status,
    kycStatus, createdAt`), so tazkira numbers, photo paths, selfies, addresses and birth years are never downloaded,
    shown or cached. The phone numbers of people in the queues aren't requested either. VELRO driver phone numbers are
    returned by the API but not decoded; document images are never fetched.
  - **VELRO refresh rotation:** VELRO replaces the refresh token on every use and treats a replayed one as theft. The
    client runs one refresh at a time, writes the new token to the Keychain before using the new access token (and only
    after a 200), and, if a refresh was sent but its answer lost (timeout, dropped connection, 502/504), deletes the
    local session instead of ever sending the old token again. A refresh that never left the device keeps the session.
    Local test 2026-10-09: VELRO's own "revoke every session on replay" is rolled back with the 401 (see integrations).
  - **On disk:** only the last queue counts (UserDefaults `LCCOperationsLastCounts`, numbers with environment and time)
    for the 0 to more-than-0 notifications, and the hall-decision log. No names, no lists.
  - Local emulators/backend (plain HTTP to `127.0.0.1`) are offered in debug builds only; a stored local session is
    ignored by release builds. The Firebase Web API keys in the environments are public identifiers.
- **Vault (since 2026-10-09):** the owner's own sign-in details for Linumic products and services (WorkTrack, Talar,
  SafeBeauty, VELRO, MediFlow, KhayatYar, linumic.com, GoDaddy, Play Console, App Store Connect, GitHub, Supabase,
  Firebase, other), typed in by the owner. It is separate from the sessions above: those keep only refresh tokens, and
  the Vault never feeds them on its own; it only fills a sign-in form when the owner picks an entry.
  - **Where:** only this device's Keychain, through `KeychainSecretStore` in its own service
    `com.linumic.commandcenter.vault`: `vault.index` holds the metadata of every entry (title, product, environment,
    sign-in URL, login, login type, notes, dates) and `vault.password.<entry id>` holds each password, one item each.
    All items are `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and not synchronizable, so they are never in iCloud
    Keychain or an unencrypted backup. Metadata stays in the Keychain too rather than in a file, because a login (an
    email or phone number) together with a sign-in URL is half a credential. Nothing goes to Supabase, UserDefaults, a
    file or a log. Passwords are written before the index, so the index never claims a password that isn't stored; a
    failed index write removes a new password again; an index that can't be read is never overwritten.
  - **Unlock:** showing, copying or filling a password, and replacing, removing or deleting a stored one, needs
    LocalAuthentication `deviceOwnerAuthentication` (Touch ID, Face ID or the device password). The Vault then stays
    unlocked for 2 minutes and locks itself; it also locks at once when the Mac sleeps, the screen sleeps or locks, the
    user session switches, the app is hidden, or (iPhone/iPad) the app goes to the background. Switching to another
    app on the Mac does not lock it, so the owner can paste into a browser. Revealed passwords are held in memory only
    while unlocked and dropped on lock. Logins and URLs are shown without unlocking.
  - **Limit:** the unlock is enforced by the app, not by a Keychain access-control flag: `SecAccessControl` with
    `.userPresence` needs the data-protection keychain, which ad-hoc development builds fall back from. Other apps can't
    read the items either way; a process running as the owner with this app's signature could.
  - **Clipboard:** a copied login or password is marked `org.nspasteboard.ConcealedType` and
    `org.nspasteboard.TransientType` on the Mac (clipboard managers skip it) and local-only with a 30-second expiry
    on iOS (never to Universal Clipboard). After 30 seconds the app clears it if the pasteboard has not changed since
    (same change count and, on the Mac, the same value by SHA-256; the value itself is not kept for the check).
  - **Sign-in assist:** the WorkTrack, Talar, SafeBeauty and VELRO sign-in sheets have "Fill from Vault" (entries of
    the same product and environment, or "any environment"). After a successful sign-in that the Vault doesn't hold
    yet, the sheet asks "Save to Vault?"; the typed password stays in the sheet's memory only until the owner answers.
    Saving fills a matching empty template or same-login entry and never replaces a stored password.
  - **Templates:** empty entries (no login, no password) for sign-in URLs found in the product repositories, each
    with its citation (`VaultTemplates.swift`). No secret was read or migrated from anywhere on the Mac.
- **Keys & Backups (since 2026-10-09):** a registry of where each signing key, licence key and App Store Connect key
  lives and which encrypted backup holds it, in `keys-registry.json` next to `inventory.json` (titles, home-relative
  paths, days, sizes, Google Drive file ids, restore-test records; no key material, no hash, no passphrase).
  - **What is read on the Mac:** for each registry path, and for files found by name in `~/Projects`, `~/Keys`,
    `~/.velro-keys`, `~/.linumic/license-keys` and `~/.appstoreconnect` (skipping node_modules, build, .git and
    symbolic links), only `attributesOfItem` (type, size, modification date) and `contentsOfDirectory`. No file is
    opened. Not read: key and keystore contents, `.storepass`, `keystore.properties`, `.env`, the `.p8`/`.pem` files and
    `~/.linumic/license-backup-passphrase.txt` (listed in the registry so its existence is visible; never opened).
  - **Sandbox:** the app can only see folders the owner picked in an open panel. Those grants are stored as
    security-scoped bookmarks created with `.securityScopeAllowOnlyReadAccess` (UserDefaults `LCCKeysBookmarks`);
    the Oversight workspace bookmark is reused. A location outside every grant is shown as "not granted — choose
    folder" and produces no finding. "Remove access" forgets the Keys grants.
  - **Passphrase:** the app checks only that the Keychain item "Linumic license backup passphrase" exists
    (`SecItemCopyMatching` with `kSecReturnAttributes`, never `kSecReturnData`, login keychain). It never reads it.
  - **Restore guide:** shown, never run. `openssl enc -d … | tar -x(z)` prompts for the passphrase; the guide restores
    into an empty `0700` folder and deletes it after.
  - On iPhone and iPad the checks don't exist; the registry is shown with its facts only.
- **Licence signing keys (MediFlow, KhayatYar):** imported by the owner on the Mac only, checked against the
  production public key built into the app, then stored in the Keychain (`licence.signing.<product>`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable` false). They are never logged, never
  written to the ledger, `licences.json` or `inventory.json`, and never sent to Supabase or iCloud. The master
  copies stay in `~/.linumic/license-keys/` with their encrypted backup (see `licensing/MAP.md`); the app does not
  read that folder. Removing a key from the app doesn't affect issued licences.
- **Licence ledger:** Supabase `licences` holds customer, machine code, dates, edition, features, the issued
  key text, status and notes. Admin-only RLS, no delete policy, an audit trigger, and a guard trigger that makes
  the signed fields immutable. The issued key text is not a secret (the customer holds it); a private key is.
- **Sandbox:** user-selected files are read-write (not read-only) since 2026-10-09, so the owner can save
  `.lnmlic` and CSV files with the save panel. The app still reads or writes only files the owner picks.
- **No secrets in source or Git.** `.gitignore` blocks `.env*`, `*.p8`, `*.p12`,
  `*.pem`, `*.key`, keystores, provisioning profiles and service-account JSON.
  Check `git diff --cached` before each commit.
- **Transport:** HTTPS only. App Transport Security stays at its default (no
  exceptions).
- **Local data** (`inventory.json`) sits inside the sandbox container and is
  protected by FileVault at rest. It holds no secrets.
- **Platforms cache** (`platform-hub.json`, same folder) keeps GitHub responses for conditional requests,
  including version files of private repositories (build settings such as `gradle.properties`). Never the token.
  Entries older than 14 days are dropped; deleting the file only costs one full refresh.

## Backend (Supabase, created 2026-09-23)

- Row-level security on every table. Only `app_admins` members can read or write. The admin check lives in the
  non-exposed `private` schema.
- Data rules are enforced in the database (see backend-plan.md). The client can't bypass them.
- `audit_events` is append-only (no update/delete policies) and written by a security-definer trigger.
- Keys: the app will use only the **publishable** key and the user's session. The service-role key is never put in
  the app or the repository.

## Backend phase (design)

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
