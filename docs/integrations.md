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

## Platforms hub (versions, releases, CI, links)

- **What it is:** Platforms (پلتفرم‌ها) in the sidebar, one card per product: WorkTrack, SafeBeauty, Talar, VELRO,
  MediFlow, Tailor ERP / KhayatYar, NerkhTimes, Afghan Prayer Times (Namazia), DukanPro. Only existing inventory
  products appear; a profile whose product isn't in the inventory is skipped.
- **Reference facts** (`LinumicCore/Services/PlatformCatalog.swift`): where each product's version lives on `main`,
  its business model (self-serve sign-up, licence, consumer app, or Unknown) and its admin and public links. Every
  entry cites its source: `research/platform-admin-apis.md` (2026-10-08), the GitHub contents API, or a live check.
  Each link was opened on 2026-10-09 and answered HTTP 200 (the page title is quoted). Links that answered 404
  (linumic.com pages for Namazia, DukanPro and KhayatYar under `/khayatyar/`) are left out.
- **GitHub reads** (`GitHubClient.releaseTracking`, GET only), per code repository of each product:
  `/repos/{r}` (default branch), `/releases/latest` (404 = "no release", a fact), `/releases?per_page=10` (drafts
  dropped; asset names and download counts), `/pulls?state=open` (count), `/actions/workflows` (only
  `.github/workflows/*`, active; GitHub's dynamic Dependabot/Pages workflows are left out), then
  `/actions/workflows/{id}/runs?branch={default}&per_page=1` per workflow, and
  `/contents/{path}?ref={default}` with `Accept: application/vnd.github.raw+json` for each version file. A workflow
  that never ran on main shows "No run on main", not a status.
- **Version files:** WorkTrack `app/build.gradle.kts`, `ios/project.yml`; SafeBeauty `app/build.gradle.kts`,
  `ios/project.yml`; Talar `android/app/build.gradle.kts` (releases in `talar-releases`); VELRO
  `mobile/gradle.properties` (`velro.versionName`/`velro.versionCode`), `ios/project.yml` per bundle id (Ride,
  Driver, Ops); MediFlow `pyproject.toml`; KhayatYar `gradle.properties` (`appVersion`/`appVersionCode`);
  NerkhTimes `app/build.gradle.kts`, `ios/project.yml`; DukanPro `app/pubspec.yaml`. Namazia's `main` holds only
  `README.md`, so it has no version file. XcodeGen files are read per bundle id: the target's own
  `MARKETING_VERSION` wins, otherwise the project-wide one.
- **Drift flags** (`PlatformDrift`), computed and never guessed: *main is ahead of the latest release* (the
  version file is higher than the release tag, for components shipped as GitHub releases), *store version older
  than main* (the live version in the store listing, from App Store Connect / Play / the public lookup, is lower
  than main), *CI failing on main* (the latest run of a workflow on the default branch concluded failure, timed out
  or failed to start). A comparison is made only between two real version numbers: a tag like `android-app`, a
  store label holding two different versions, or an unknown value is never compared. Each flag lists where both
  values came from and when.
- **Rate limits:** every request is conditional. The client keeps each response's ETag (`GitHubResponseCache`) and
  sends `If-None-Match`; a 304 is answered from the cache and doesn't count against an authenticated rate limit.
  A refresh stops as soon as GitHub reports the limit, and keeps the previous data.
- **Refresh:** Platforms → Refresh from GitHub (⌘R), and automatically on launch and every 30 minutes with the
  store and oversight refresh (Settings → Integrations → Platforms). The automatic refresh needs the GitHub token;
  without one, a manual refresh reads public repositories only and the private ones show the error.
- **Storage:** `platform-hub.json` next to `inventory.json` (tracking per repository + ETags, entries older than 14
  days dropped). It's a per-device cache of observations, not synced to Supabase; the next refresh rebuilds it.
- **Licence products** (MediFlow, KhayatYar) show the ledger's active, ending-soon and expired counts and open the
  Licences screen.
- **Live check (2026-10-09):** an opt-in test (`LCC_LIVE_HUB=1 GITHUB_TOKEN=… swift test --package-path
  Packages/LinumicCore --filter liveSweep`) read all 10 repositories without a failure.

### راهنمای کوتاه (دری)

- در نوار کنار «پلتفرم‌ها» را باز کنید. برای هر محصول یک کارت است: نسخه روی main، آخرین انتشار GitHub و تعداد دانلود،
  نسخهٔ فروشگاه‌ها، CI و PR های باز. روی کارت بزنید تا جزئیات، منبع و تاریخ هر عدد را ببینید.
- «عقب‌ماندگی» فقط وقتی نشان داده می‌شود که دو نسخهٔ واقعی مقایسه شوند: main جلوتر از آخرین انتشار، نسخهٔ فروشگاه کهنه‌تر از
  main، یا CI روی main ناکام. چیزی که خوانده نشده «نامعلوم» می‌ماند.
- به‌روزرسانی خودکار هر ۳۰ دقیقه است و توکن GitHub می‌خواهد (تنظیمات ← Integrations). بدون توکن فقط مخزن‌های عمومی خوانده می‌شوند.

## Oversight register in the cloud

- Until 2026-10-09 `export_inventory()` had no `oversight` section, so a signed-in cloud load replaced the local
  register with an empty one. Migration `20261009043412_oversight_sync` adds the `oversight_repos` table (admin RLS,
  no delete policy, no audit trigger because it is a regenerated cache of GitHub observations), includes
  `oversight` in `export_inventory()`, and merges it on `import_inventory()` by slug: nothing is deleted, an entry
  only changes when the incoming copy was observed at the same time or later, and an upload without `oversight`
  changes nothing. The old functions are kept as `export_inventory_core()` / `import_inventory_core()` and wrapped.
- The client also merges (`OversightMerge` in `HybridInventoryStore.load`): union by slug, later observation wins,
  and this device's own working-copy scan is kept. If the cloud had less, the merged register is uploaded.

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
