# Integrations

**Connected:** GitHub (read-only) and the public App Store lookup (read-only, no credentials).
**Built, waiting for the owner's keys:** App Store Connect and Google Play Console (both read-only, both free).
**Not connected:** social networks, AI providers. Each one is added
only when explicit credentials and authorization are provided.

## Principles

- **Read-only first.** Every integration starts by reading data only. Writes
  (creating issues, submitting builds, publishing posts) come later, each one
  confirmed by a person.
- **Snapshots with provenance.** Integration data is stored as snapshots with
  `source` and `fetchedAt`, kept separate from manually entered facts.
- **Credentials** are held in the Keychain (MVP) or on the backend (later). They
  are never in source code or Git. See [security.md](security.md).
- **Failure is visible.** A failed sync shows an error state and never keeps
  showing stale data as if it were current.

## GitHub (implemented, read-only)

- **Code:** `GitHubClient` (`Packages/LinumicCore/Sources/LinumicCore/Integrations/GitHubClient.swift`)
  implements `RepositoryHostClient`. It sends GET requests only, and a test asserts that every
  request is a body-less GET to api.github.com.
- **What it reads:** repository metadata (visibility, description, homepage, default branch),
  the latest commit on the default branch, published releases (drafts excluded), open PRs,
  open issues (PRs excluded), languages, and the latest GitHub Actions run on the default
  branch. Lists read one page of 100 items.
- **Sync:** `RepositorySync.refresh` replaces only each repository's `gitHub` snapshot, stamped
  with `fetchedAt`. It never changes repository links, types or verification. Failures are
  reported per repository, and the toolbar shows how many failed and why.
- **In the app:** Development → Repositories → **Refresh from GitHub** (⌘R), or Settings →
  Integrations. Without a token only public repositories can be read (60 requests/hour).
- **Token:** Settings → Integrations → GitHub. Use a **fine-grained** personal access token
  limited to the Linumic repositories with read-only *Metadata, Contents, Issues, Pull
  requests, Actions*. It's stored in the Keychain as `github.token` (service
  `com.linumic.commandcenter`) and never written to disk, logs or the inventory.
  Don't reuse a GitHub CLI token: those carry write scopes.
- **Verified live on 2026-09-23:** an opt-in test (`GITHUB_TOKEN=… swift test --filter
  liveReadOnlySnapshot`) read the private MediFlow and public DukanPro repositories. The
  sandboxed app refreshed the public repositories without a token.
- **Not yet:** local working-copy status (branch, uncommitted changes). The sandboxed app needs
  a user-granted, security-scoped folder bookmark before it can run `git` read-only against
  `~/Projects`.
- **Forbidden without explicit per-action approval:** push, merge, delete branch, close issue,
  edit settings. None of these exist in the code.

## App Store public lookup (implemented, read-only)

- `AppStoreLookupClient` + `StoreSync.refreshAppStore` call
  `https://itunes.apple.com/lookup?bundleId=…&country=…` (US first, then AF) for each App
  Store listing's bundle ID. They update the live version, app name, URL, seller and
  storefront, and add a dated App Store source. Owner evidence is kept.
- An app missing from the public store (for example, still in review) is **reported, never
  written as a fact**, and its record is left unchanged.
- In the app: Stores → App Store → **Refresh Public Status** (⌘R).
- Limits: public data only. There are no review states, no pending versions and no TestFlight;
  those need App Store Connect.

## Apple App Store Connect (implemented, read-only; needs the owner's key)

- `AppStoreConnectClient` signs a 15-minute ES256 JWT with a team API key and makes only `GET`
  requests: `/v1/apps?filter[bundleId]=…` and `/v1/apps/{id}/appStoreVersions`.
- Key: App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys,
  role **Developer** (the least privilege that can read versions). Free with the developer membership.
- Settings → Integrations takes the Issuer ID, Key ID and the `.p8` file. They're stored together in
  the Keychain (`appstoreconnect.key`); the file itself is never copied or committed (`*.p8` is ignored).
- For each App Store listing: the live version per platform → `productionVersion`; the newest version
  that isn't live or superseded → `latestSubmittedVersion` and `reviewStatus` (e.g. "Waiting for review").
  A dated source "App Store Connect API /v1/apps/{id}/appStoreVersions" replaces the previous one.

## Google Play Console (implemented, read-only; needs the owner's service account)

- `GooglePlayClient` exchanges an RS256 JWT for an access token (scope `androidpublisher`), then calls
  `GET applications/{package}/tracks/{track}/releases` for production, beta, alpha and internal.
  This endpoint needs **no edit**, so nothing is ever drafted or committed.
- Service account: Google Cloud → service account + JSON key, enable the Google Play Android Developer
  API; Play Console → Users and permissions → invite its email with **View app information (read-only)**.
  Free.
- The JSON key is stored only in the Keychain (`googleplay.serviceaccount`); `*service-account*.json` is ignored.
- For each Google Play listing: the published production release → `productionVersion`; every other
  release is listed in `reviewStatus` with its track and lifecycle state (draft, in review, approved…).
- Custom closed-testing tracks aren't read yet; closed testing on the default `alpha` track is.

## Ratings, reviews and TestFlight builds

- App Store rating and count: Apple's public lookup (no key), per storefront, on each automatic refresh.
- Newest 10 customer reviews and newest 5 TestFlight builds: App Store Connect (`customerReviews`,
  `builds` with `preReleaseVersion`), GET only, Developer role.
- The console is authoritative for versions: once App Store Connect has been read, the public lookup only adds
  the rating.
- Google Play reviews need the "Reply to reviews" permission, which also allows writing; not read for now.

## Automatic refresh and store change alerts

- With either console connected, the app reads it on launch and every 30 minutes while open
  (toggle in Settings → Integrations). Reads only.
- Each read is compared with the previous console read of the same listing (`StoreChangeDetector`).
  Only console-to-console differences count, so the first read after seed or screenshot data is silent.
- Changes are listed in the dashboard ("Store changes", kept per device) and posted as local
  notifications, which never leave the device.

## Licences (LNM1, MediFlow and KhayatYar)

- **Protocol:** `licensing/PROTOCOL.md` next to this repository. `LinumicCore/Licensing` implements it in Swift
  with CryptoKit and produces the same keys as `linumic_license.py` (canonical JSON byte-identical, ECDSA P-256 /
  SHA-256, DER signature, base64url without padding). The production **public** keys are embedded in
  `LicenceProduct.productionPublicKeyPEM` (copied from `licensing/public/*.pem` on 2026-10-08; a test pins their
  SHA-256 fingerprints).
- **Signing keys:** imported by the owner on the Mac (Licences → Signing keys → Import Signing Key…). The key is
  refused unless its public half equals the embedded production public key. It is stored in the Keychain as
  `licence.signing.mediflow` / `licence.signing.khayatyar`. Issuing is Mac-only; iOS shows the ledger.
- **Ledger:** Supabase table `licences` (admin-only RLS, no delete policy, audit trigger, guard trigger). The app
  calls `export_licences()` and `upsert_licences(rows)`; it keeps a local copy (`licences.json` next to
  `inventory.json`) so it works offline. Sync merges record by record and never deletes: a status only moves
  forward (active → superseded → void), a known key never changes, notes come from the copy edited last. A
  licence id reused with different signed contents is refused by the server and shown as a conflict.
- **What is in Supabase:** customer name, machine code, dates, edition, features, the issued licence key (the
  customer already holds it), status, notes, who recorded it. **Never in Supabase:** private signing keys or the
  backup passphrase.
- **Import / export:** `issued.csv` from `~/.linumic/licenses/` (picked by the owner; the sandbox can't read it
  otherwise). That file has no key or features, so they stay Unknown until the matching `.lnmlic` files are
  imported too; each key is verified before it is attached. Export CSV writes the whole ledger.
- **Reminders:** local notifications at 09:00 30, 14, 7 and 1 days before the last valid day of each active licence.
- **Dev check:** `tools/licensing/python_crosscheck.sh` signs with the TEST key in Swift and verifies with Python
  `cryptography` from the licensing venv. Not a CI dependency.

### راهنمای کوتاه برای امین‌الله (دری)

- **یک بار، روی مک:** Linumic OS ← «لایسنس‌ها» ← «کلیدهای امضا» ← «وارد کردن کلید امضا…» و فایل
  `~/.linumic/license-keys/mediflow-private.pem` را انتخاب کنید. همین کار را برای خیاط‌یار با
  `khayatyar-private.pem` بکنید. برنامه کلید را با کلید عمومیِ داخل خودش مقایسه می‌کند؛ اگر نخواند، چیزی ذخیره
  نمی‌شود. کلید فقط در Keychain همین مک می‌ماند و هرگز به Supabase نمی‌رود.
- **لایسنس تازه:** «صدور لایسنس» (دکمهٔ +)، محصول، نام مشتری و کد دستگاه را بنویسید، دائمی یا تا یک تاریخ
  (دکمهٔ «+۱ سال»)، بعد «امضا و صدور». کلید را کاپی کنید، فایل `.lnmlic` ذخیره کنید یا مستقیم بفرستید.
- **تمدید یا عوض شدن دستگاه:** روی لایسنس بزنید ← «تمدید یا صدور دوباره…». شمارهٔ تازه می‌گیرد و قبلی
  «جایگزین‌شده» می‌شود.
- **باطل:** فقط در دفتر شما علامت می‌خورد. کلید آفلاین پس گرفته نمی‌شود و تا ختم اعتبارش در برنامهٔ مشتری کار می‌کند.
- **لایسنس‌های قبلی:** «بیشتر» ← «وارد کردن issued.csv…» و فایل `~/.linumic/licenses/issued.csv` را (و اگر خواستید
  فایل‌های `.lnmlic` کنارش را) انتخاب کنید. بدون فایل `.lnmlic`، کلید آن لایسنس «نامعلوم» می‌ماند.
- **یادآوری:** ۳۰، ۱۴، ۷ و ۱ روز پیش از ختم هر لایسنس اطلاعیه می‌آید. روی آیفون فقط دفتر دیده می‌شود؛ صدور فقط روی مک است.

## Social media (Phase 5)

LinkedIn, Facebook, Instagram, X and YouTube. OAuth per network, tokens stored
on the backend. Publishing always goes through a draft → approve → publish
workflow.

## AI providers (Phase 6)

Model API keys are stored on the backend. Requests contain only the data
needed for the question. See [market-intelligence.md](market-intelligence.md)
and the AI assistant section of ARCHITECTURE.md.
