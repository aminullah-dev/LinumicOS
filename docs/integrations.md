# Integrations

**Connected:** GitHub (read-only), the public App Store lookup (read-only, no credentials), and the WorkTrack vendor
API (read, plus licence renewals confirmed per action; the owner signs in with his vendor account), and the Talar,
SafeBeauty and VELRO admin overviews under Operations (read-only except Talar's audited hall approve/reject; the owner
signs in to each).
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

## WorkTrack customers and renewals (vendor API)

- **What it is:** WorkTrack customers (مشتریان WorkTrack) in the sidebar. Every WorkTrack customer company with its
  licence, payments and history, read from WorkTrack's own vendor console API, and a **Renew** action that changes a
  licence. Source of every route and schema: the WorkTrack repository, `main` @ `f2a9d2c` (2026-10-09):
  `backend/functions/src/routes/vendor.ts`, `middleware/vendor.ts`, `services/license.ts`, `services/plans.ts`,
  `services/billing.ts`, `services/vendor.ts`, `services/vendorInsights.ts`, `lib/errors.ts`. See also
  `research/platform-admin-apis.md` §1.
- **Code:** `FirebaseAuthREST` and `WorkTrackVendorClient` (`LinumicCore/Integrations`), the renewal builder, filters,
  reminders and action log in `LinumicCore/Services/WorkTrackCustomers.swift`, the screen in `App/Views/WorkTrackViews.swift`.
- **Environments:** Production `https://worktrack-prod.web.app/v1`, Demo `https://worktrack-demo-af.web.app/v1`, and,
  in debug builds only, Local emulator `http://127.0.0.1:5001/demo-worktrack/us-central1/api/v1` with the Auth
  emulator on `127.0.0.1:9099`. Release builds don't offer the emulator, and a stored emulator session is ignored.
- **Sign-in:** Firebase email/password over REST, no Firebase SDK: `POST identitytoolkit.googleapis.com/v1/accounts:signInWithPassword`,
  then `POST securetoken.googleapis.com/v1/token` (`grant_type=refresh_token`) whenever the one-hour ID token is
  within five minutes of expiring. The account needs the `vendor: true` claim, no customer claims (`cid`/`eid`) and a
  verified email; WorkTrack checks the token for revocation on every request (`middleware/vendor.ts:44-90`). After
  signing in, the app calls `GET /vendor/me` and keeps the session only if that succeeds.
- **Web API keys** (public by design; they identify the Firebase project, access is the ID token): production
  `web/.env.production:18`, demo `web/.env.demo:20` in the WorkTrack repository (`VITE_FIREBASE_API_KEY`; the same values
  are in `ios/WorkTrack/Core/Environment.swift:48-49`). The emulator accepts `demo-key` (`web/.env.emulator`).
- **Reads** (GET only, retried once after a 401 with a refreshed token): `/vendor/me`, `/vendor/companies`,
  `/vendor/companies/:id`, `/vendor/companies/:id/detail`, `/vendor/companies/:id/orders`, `/vendor/revenue`,
  `/vendor/plans`, `/vendor/audit`. The company list is read when the screen's data is needed: on launch, every 6
  hours while the app is open, with ⌘R, and after a renewal. WorkTrack reads several documents per company for it,
  so it is not polled more often. Nothing is cached on disk; a failed read clears the list instead of showing old
  data as current. Every number shows the environment and the time it was read; days left are WorkTrack's own
  `daysUntilExpiry` (counted from today in Kabul).
- **The one write:** `PUT /vendor/companies/:id/license`. WorkTrack's schema makes `expiresAt` optional and stores an
  omitted (or null) value as **no end date** (`setLicense` writes `input.expiresAt ?? null`, `license.ts:191`). So:
  - the request is built only by `WorkTrackRenewal.makeWrite` from the licence **as just fetched**
    (`GET /vendor/companies/:id` when the sheet opens);
  - **every** field is sent: `plan`, `deviceLimit`, `status`, `expiresAt`, `enforceDevices`, and also the optional
    `enforcePlan`, `employeeLimit`, `extraFeatures` with their current values, so nothing relies on WorkTrack's
    "omitted keeps current" rule;
  - `expiresAt` is always in the body. "No end date" is a separate choice with its own confirmation toggle, and even
    then the key is sent as an explicit `null`. Unit tests check the encoded JSON for both cases;
  - the builder refuses a day before today (Kabul), an invalid date, an unknown plan, a status WorkTrack won't
    accept, seats outside 1–100,000, and a stored feature key WorkTrack no longer accepts.
- **Renew sheet:** plan (with the price and seats from `/vendor/plans`), device seats (with "use the plan's N"),
  status (an EXPIRED licence is proposed as ACTIVE; a SUSPENDED one stays suspended unless the owner chooses
  otherwise), and the new last day: +1 month, +1 year (counted from the current last day if it is still ahead,
  otherwise today in Kabul, with WorkTrack's month clamping), a custom day, or no end date. A table shows every
  licence field before and after. Production needs the company name typed exactly; Demo and the emulator need a
  tick. Just before sending, the app reads the company again and sends nothing if the licence changed since the
  sheet opened. The PUT is sent once and never retried. Then the app reads `/detail` again, compares every field
  with what it sent, and shows "verified" or the differences.
- **Audit:** WorkTrack writes its own two trails for every licence change (the company's `auditLogs` and
  `vendorAuditLogs`, `routes/vendor.ts:239-257`); the screen shows the newest `vendorAuditLogs` entries. Linumic OS
  also keeps its own append-only log on this device, `worktrack-actions.json` next to `inventory.json`: time,
  environment, account, company, licence before, licence sent, licence read back, and outcome (verified, not
  verified, failed). Entries are never removed. It is not synced to Supabase in this phase.
- **Dashboard and reminders:** a WorkTrack customers card lists the companies whose licence ends within 30 days.
  Local notifications at 09:00, 30, 14, 7 and 1 days before a **production** customer's last day (Settings →
  Integrations → WorkTrack customers). TEST and DUPLICATE companies are listed but left out of counts and reminders,
  as WorkTrack leaves them out of revenue.
- **Not in this phase:** company deletion, purge, TEST/DUPLICATE marks, plan prices, CRM writes. None of these calls
  exist in the client.

### WorkTrack: testing against the emulator (never production)

1. Start WorkTrack's emulators (from the WorkTrack repository; `backend/functions/.env.demo-worktrack` must exist with
   `HESAB_FORWARD_URL=` empty, it is gitignored):
   `cd backend/functions && npm run build && npx firebase emulators:start --config ../../firebase.json --project demo-worktrack --only functions,firestore,auth < /dev/null`
2. Seed the sample tenant: `FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 node seed.js`.
3. From this repository, add the vendor test user and sample companies (emulator only; the script refuses to run
   without the emulator hosts): `FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 node tools/worktrack/emulator-setup.js`.
   It creates `vendor@linumic.test` (vendor, verified), `novendor@linumic.test` (no claim) and
   `unverified@linumic.test` (claim, unverified email), all with the emulator-only password in the script, and five
   companies: expiring in 10 days (SILVER with an employee cap, extra feature and both enforcement flags on),
   expired 20 days ago, a trial ending in 5 days, a TEST-marked one, and a perpetual one.
4. `LCC_WT_EMULATOR=1 swift test --package-path Packages/LinumicCore --filter liveEmulator` signs in, reads every
   endpoint, renews the 10-day company by one month with the real builder, checks the stored licence both through
   the API and directly in the emulator's Firestore (`expiresAt` set, every other field unchanged, `source` VENDOR,
   one new `license.update` audit entry), and checks the error paths (404, 422, wrong password, no vendor claim,
   unverified email, revoked refresh token).
5. In a debug build of the app, sign in with Environment "Local emulator" and the same account.

Run on 2026-10-09: all of the above passed. The emulator stored
`plan=SILVER deviceLimit=30 status=ACTIVE expiresAt=2026-11-19 enforceDevices=true enforcePlan=true employeeLimit=60 extraFeatures=[projects] source=VENDOR`
after a renewal from `expiresAt=2026-10-19`.

### راهنمای امین‌الله: مشتریان WorkTrack (دری)

- **ورود:** در نوار کنار «مشتریان WorkTrack» ← «ورود…». محیط را «Production» بگذارید، ایمیل و رمز حساب فروشندهٔ
  خود را بنویسید. این همان حسابی است که در کنسول WorkTrack (console.linumic.com) با آن وارد می‌شوید و نشان
  `vendor` دارد. رمز فقط یک بار به Firebase می‌رود و جایی ذخیره نمی‌شود؛ فقط یک refresh token در Keychain همین
  دستگاه می‌ماند. اگر رمز را در Firebase عوض کنید، نشست باطل می‌شود و دوباره وارد می‌شوید.
- **اگر خطای 403 دیدید:** حساب نشان `vendor` ندارد یا ایمیلش تأیید نشده است. در مخزن WorkTrack دستور
  `scripts/grant-vendor.ts` را برای همان ایمیل اجرا کنید (اول بدون `--apply`).
- **فهرست:** همهٔ شرکت‌ها با پلن، وضعیت لایسنس، روز آخر، روزهای باقی‌مانده، دستگاه‌ها، کارمندان و آخرین فعالیت.
  فیلترها: «ختم در ۳۰ روز»، «ختم‌شده»، «آزمایشی رایگان»، «نیاز به توجه». شرکت‌های «آزمایشی» و «تکراری» نشان دارند
  و در شمارش و یادآوری نیستند. روزها با تاریخ امروزِ کابل شمرده می‌شوند.
- **تمدید:** روی شرکت بزنید ← «تمدید یا تغییر لایسنس…». پلن، تعداد دستگاه، وضعیت و روز آخر تازه را انتخاب کنید
  (+۱ ماه، +۱ سال، تاریخ دلخواه). جدول «قبل و بعد» همهٔ خانه‌ها را نشان می‌دهد. در Production باید نام شرکت را
  دقیقاً بنویسید، بعد «فرستادن به WorkTrack». برنامه بعد از فرستادن، شرکت را دوباره می‌خواند و می‌گوید همه‌چیز
  همان است که فرستاده شد یا نه.
- **«بدون تاریخ ختم»** یعنی لایسنس دائمی؛ فقط وقتی قرارداد همین است و تیک تأیید جداگانه‌اش را بزنید.
- **ثبت کارها:** هر تمدید در دفتر همین دستگاه («فرستاده‌شده از Linumic OS») و در دفتر بازرسی خود WorkTrack ثبت
  می‌شود.
- **یادآوری:** ۳۰، ۱۴، ۷ و ۱ روز پیش از ختم لایسنس هر مشتری Production اطلاعیه می‌آید (تنظیمات ← Integrations).
- حذف یا پاک کردن شرکت در این مرحله نیست؛ برای آن از کنسول WorkTrack استفاده کنید.

## Operations: Talar, SafeBeauty and VELRO (admin overview)

- **What it is:** Operations (عملیات) in the sidebar, one tab per product, plus the dashboard card **Waiting for you**
  and a notification when a production queue goes from 0 to more than 0. Read-only. The one exception is Talar's
  hall approve/reject, which Talar audits. Every other action is an "Open admin panel" link. Research input:
  `research/platform-admin-apis.md` §2–4 (2026-10-08); every route and field below was re-checked against source on
  2026-10-09.
- **Code:** `FirestoreREST`, `FirebaseSession` (in `FirebaseAuthREST.swift`), `TalarAdminClient`, `SafeBeautyAdminClient`,
  `VelroStaffClient` (`LinumicCore/Integrations`), queues and the counts store in `LinumicCore/Services/Operations.swift`,
  `App/OperationsModel.swift`, `App/Views/OperationsViews.swift`.
- **Refresh:** on launch, every 30 minutes while the app is open, and with ⌘R. Nothing read is written to disk except
  the queue counts (for the notification rule) and the local hall-decision log `operations-actions.json`.

### Talar

- **Source:** Talar repository, `origin/main` @ `7989747` (main is production): `backend/functions/src/modules/admin/routes.ts`,
  `lib/auth.ts`, `lib/errors.ts`, `lib/audit.ts`, `modules/halls/routes.ts`, `modules/payments/routes.ts` and
  `payouts.ts`, `backend/firestore.rules`, `web/.env.production`, `web/.env.demo`, `desktop/main.js`.
- **Environments:** Production `https://asia-south1-talar-af-prod.cloudfunctions.net/api/v1`, Demo
  `https://asia-south1-talar-demo-af.cloudfunctions.net/api/v1` (runs older code than production), Local emulator
  `http://127.0.0.1:5001/demo-talar/asia-south1/api/v1` (debug builds; auth 9099, Firestore 8080 per
  `backend/firebase.json`).
- **Sign-in:** Firebase email/password over REST, then the ID token must carry `role: "admin"` (`lib/auth.ts`); the
  app also reads `/admin/dashboard` before keeping the session. Use a dedicated admin account: creating or joining an
  organisation replaces the claim (`setUserClaims`).
- **Reads:** `GET /admin/dashboard`, `/admin/halls/pending` (up to 50), `/admin/reviews` (pending, up to 50);
  organisations from Firestore `organizations` (admins may read them; field mask `name, status, commissionPct`), then
  `GET /orgs/:orgId/payments/payouts` for each active one (first 50). There is no cross-organisation payout list in Talar.
- **The write:** `POST /admin/halls/:hallId/review` `{decision: "approve"|"reject", reason?}`. Talar refuses it with 409
  unless the hall is `pending_review` and writes `hall.review_approve|reject` to `auditLogs` (best-effort: a failed
  audit write is swallowed, and the reason isn't in the audit entry). No notification to the hall owner. The app asks
  for the hall name typed in production (a tick elsewhere), sends once, never retries (not even after a 401), re-reads
  the queue and records the result in `operations-actions.json`.
- **Never called:** `payouts/run`, `payouts/:org/:id/mark-paid` (move money, no idempotency or transaction),
  `reviews/moderate`, cities, coupons, featured, bootstrap.
- **Admin panel:** `https://talar-af-prod.web.app/admin` (200 on 2026-10-09). The demo project's Hosting answered 404.

### SafeBeauty

- **Source:** SafeBeauty repository, `origin/main` @ `efe5bdf`: `public/admin/index.html` (sign-in 382-399 and
  1082-1107, stats 1203-1236, queues 1349-1402, money 3424-3497), `functions/domains/identity.js`
  (`authenticateWithPassword`, `syncUidMap`), `functions/shared.js` (`pbkdf2Hash`, `assertAdmin`),
  `functions/domains/payments.js` (`getCommissionPercent`), `firestore.rules`, `DEPLOY.md`,
  `ios/SafeBeautyCore/.../PinHasher.swift` and `PhoneUtils.swift`. Production may lag `main` (manual deploys).
- **Environments:** Production (project `safebeauty`), Staging (`safebeauty-staging`; functions deployment
  unverified, needs its own admin account), Local emulator (`--project demo-safebeauty`, ports 9099/5001/8080; debug builds).
- **Sign-in (the console's five steps):** normalise the phone (port of `PhoneUtils.normalizeForLogin`), callable
  `authenticateWithPassword {phone, password}` (must return `mode: REAL`, `role: ADMIN`), Firebase password =
  base64(PBKDF2-HMAC-SHA256("AUTH:" + password, salt, 65,536, 32 bytes)) (port of `PinHasher.deriveAuthPassword`,
  checked against SafeBeauty's own test vectors), Firebase sign-in with `firebaseEmail`, callable `syncUidMap
  {appUid}` (without it the rules can't see the admin). Login limits: 30 per IP, 10 per number, per 15 minutes.
- **Reads (Firestore REST under the rules, read-only):** counts by aggregation query: `users` kycStatus PENDING,
  `users` status PENDING, `salons` and `salons` isVerified true, `appointments` with `appointmentDate` (epoch ms) in
  Kabul's day and in the week from Saturday, `refund_requests` PENDING. Queues: `users` where kycStatus or status is
  PENDING, **field mask `name, role, status, kycStatus, createdAt`** (identity fields are never requested). Payouts
  owed: `provider_balances` above zero with the owner's name (batch get, mask `name`). Commission:
  `platform_config/general` (`commissionPercent`, `maxDiscountFraction`), shown as stored and as the server applies it
  (outside 0–100 or missing = 10%).
- **No writes.** Provider approval, salon verification and the commission are raw Firestore writes in SafeBeauty with
  no audit; `reviewKyc` and `recordProviderPayout` are callables without audit. They stay in the console.
- **Admin panel:** `https://safebeauty.web.app/admin` (the documented permanent path; 200 on 2026-10-09).

### VELRO

- **Source:** Velro repository, `main` @ `b9891a3`: `backend/ui/api/routers/auth.py`, `schemas/auth.py`,
  `application/use_cases/authenticate.py`, `ui/api/deps.py`, `ui/api/errors.py`, `ui/api/session_scope.py`,
  `ui/api/routers/admin.py`, `ui/api/opscentre.py`, `ui/api/routers/documents.py`, `infrastructure/services/settings.py`.
- **Why a port and not VelroCore:** `ios/VelroCore` lives in another private repository with no licence file and no
  published package, so depending on it would tie this app's build to a Velro checkout at a fixed path. Its
  `APIClient` is bound to URLSession (no injectable transport for fixture tests), its `KeychainSessionStore` uses its
  own Keychain service with AfterFirstUnlock and a "first launch wipes" marker, and the package exposes every write
  (approve, suspend, settings PATCH, delete account). `VelroAdmin.swift` ports only the read calls and VelroCore's
  single-refresh rule, so the read-only promise holds by construction.
- **Environments:** Production `https://api.velro.linumic.com/api/v1` (no staging exists), Local backend
  `http://127.0.0.1:8000/api/v1` (debug builds).
- **Sign-in:** `POST /auth/otp/request {phone, locale, channel: "sms", audience: "staff"}` (VELRO sends a code only to a
  number that already holds a staff role; 3 codes a minute; 5 digits, 5 minutes, 5 tries), then `POST /auth/otp/verify
  {phone, code, device_id, locale}`. A session without a staff role is refused and not kept. Access token 15 minutes,
  refresh token 180 days, **rotated on every use**.
- **Rotation handling:** one refresh in flight (concurrent requests wait for it); the new refresh token goes to the
  Keychain before the new access token is used, and only after a 200; a refused refresh (401) ends the session; a
  refresh that was sent but whose answer was lost (timeout, dropped connection, 502/504 from the proxy, or an unreadable
  200) deletes the local session instead of ever replaying the old token; a refresh that never left the device (no
  network, host not found) or that the backend refused with 429/500/503 keeps it.
- **Reads (GET only):** `/admin/dashboard` (attention, today, live, drivers, finance, network), `/admin/drivers?approval_status=PENDING`
  (phone numbers in the answer are not decoded), `/admin/drivers/:id/documents` (statuses only; operations roles),
  `/admin/trips?active_only=true`, `/admin/trips?departing_within_hours=24`, `/admin/stations`, `/admin/routes`
  (VELRO has no corridor entity; routes are the corridors), `/admin/settings` for `commission.rate_basis_points`
  (ADMIN or SUPER_ADMIN; read only, flagged if outside 0–10000).
- **Never called:** any POST/PATCH under `/admin`, `/dispatch`, settlements, `DELETE /auth/me`, `/auth/logout-all`.
- **Admin panel:** `https://admin.velro.linumic.com` (200 on 2026-10-09).

### Operations: testing locally (never production)

Each product ran from a copy of its `origin/main` source in a scratch folder (so nothing was written into the product
repositories), with test accounts created only there. All three were stopped afterwards.

1. **Talar:** `git archive origin/main backend` into a scratch folder, link `functions/node_modules`, `npx tsc`, dummy
   values in `functions/.secret.local`, then `firebase emulators:start --config <copy without predeploy> --project demo-talar --only functions,firestore,auth`.
   Talar's own seed: `FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 GCLOUD_PROJECT=demo-talar node scripts/seed.js`.
   Then `node tools/talar/emulator-setup.js` (same hosts): `admin@linumic.test` (role admin), `customer@linumic.test`,
   two halls pending review, a pending review, a pending and a paid payout.
   `LCC_TALAR_EMULATOR=1 swift test --package-path Packages/LinumicCore --filter liveTalar`.
2. **SafeBeauty:** `git archive origin/main functions firestore.rules firestore.indexes.json storage.rules`, link
   `functions/node_modules`, dummy secrets in `functions/.secret.local` and `HESAB_BASE_URL`/`HESAB_REDIRECT_BASE` in
   `functions/.env.demo-safebeauty`, a `firebase.json` with emulator ports 9099/5001/8080, then
   `firebase emulators:start --project demo-safebeauty --only functions,firestore,auth`. The repository has no seed for
   these collections, so `node tools/safebeauty/emulator-setup.js` writes accounts the way registration does (admin
   `+93700000099`, a customer, two KYC submissions with made-up identity fields, two pending approvals, three salons,
   four appointments, balances, refunds, `platform_config/general` 12%).
   `LCC_SAFEBEAUTY_EMULATOR=1 swift test --package-path Packages/LinumicCore --filter liveSafeBeauty`.
3. **VELRO:** a throw-away PostgreSQL 16 cluster on `127.0.0.1:55432`, then from `backend/` with
   `VELRO_DATABASE_URL`, a development `VELRO_JWT_SECRET`, `VELRO_STORAGE_ROOT` in the scratch folder and
   `PYTHONDONTWRITEBYTECODE=1`: `.venv/bin/python -m alembic upgrade head`, `.venv/bin/python scripts/seed.py`,
   `.venv/bin/python scripts/grant-admin.py +93700000077 --role SUPER_ADMIN`, the API with
   `VELRO_OTP_DEBUG_ECHO=true .venv/bin/python -m uvicorn --factory ui.api.app:create_app --host 127.0.0.1 --port 8000`
   (the venv's script shebangs point at an old path, so `python -m` is used). `python3 tools/velro/local-setup.py`
   registers two driver applications (refuses any non-local URL).
   `LCC_VELRO_LOCAL=1 swift test --package-path Packages/LinumicCore --filter liveVelro`.

Run on 2026-10-09, all three passed:
- Talar: dashboard `publishedHalls 4, hallsAwaitingReview 2, confirmedBookings 1, openTickets 0`; both pending halls,
  the pending review and one pending payout (net 95,000 AFN) read; approve and reject each added exactly one
  `auditLogs` entry (`hall.review_approve`, `hall.review_reject`); a second decision on the same hall got 409; wrong
  password, a non-admin account and a revoked refresh token were refused; a restored session worked.
- SafeBeauty: the five-step sign-in with the phone typed as `0700 000 099`; KYC 2, approvals 2, salons 3 (1 verified),
  bookings today 2, this week 2, payouts owed 4,200 AFN to one salon, 1 pending refund, commission 12%. Every request
  was recorded: no request asked for a tazkira or selfie field, and the only callables were the two sign-in steps.
  Wrong password, a customer account and a revoked token were refused.
- VELRO: staff sign-in with the echoed code; dashboard (2 drivers pending, 3 trips today), pending drivers with their
  missing documents, 427 stations, 78 routes, commission 1000 basis points; a forced refresh rotated the token and
  stored it first; two concurrent forced refreshes sent one request; a wrong code, the OTP rate limit (3 a minute) and a
  driver number on the staff door (no code sent) behaved as the source says.
- **Finding (VELRO backend):** replaying an already-rotated refresh token is refused (`REFRESH_TOKEN_REVOKED`), but the
  "revoke every session of this user" in `authenticate.py` is rolled back with the 401 (`session_scope.py` commits only
  responses under 400), so the user's other sessions survived. The same class of bug the OTP attempt counter already
  fixed with its own transaction (`deps.otp_attempt_recorder`). Linumic OS never replays either way.

### راهنمای امین‌الله: عملیات (دری)

- **کجاست:** نوار کنار ← «عملیات». بالای صفحه سه زبانه است: تالار، SafeBeauty و VELRO. هر کدام جدا وارد می‌شود.
- **تالار:** «ورود…» ← محیط «Production» ← ایمیل و رمز حساب مدیر تالار (حسابی که نشان `role: "admin"` دارد و مالک
  هیچ سازمانی نیست). رمز ذخیره نمی‌شود. می‌بینید: تالارهای در انتظار تأیید (با جزئیات)، نظرهای در انتظار بررسی،
  تسویه‌های در انتظار هر سازمان. روی تالار بزنید ← «تأیید…» یا «رد…»؛ در Production باید نام تالار را دقیقاً بنویسید.
  تالار این کار را در دفتر بازرسی خود ثبت می‌کند ولی به مالک تالار خبر نمی‌دهد؛ خودتان خبر بدهید. اجرای تسویه و
  «پرداخت‌شده» فقط در پنل وب تالار است.
- **SafeBeauty:** «ورود…» ← همان شمارهٔ تلفن و رمزی که در کنسول مدیریت SafeBeauty می‌زنید (0700… یا +93700…).
  نه شماره ذخیره می‌شود نه رمز. می‌بینید: صف بررسی هویت (فقط نام، نقش و وضعیت؛ تذکره و سلفی هرگز به این دستگاه
  نمی‌آیند)، صاحبان سالون در انتظار تأیید، نوبت‌های امروز و این هفته (هفته از شنبه)، پرداخت‌های بدهکار به سالون‌ها و
  کمیشن. هر تأیید و تغییر را در کنسول SafeBeauty انجام دهید (دکمهٔ «باز کردن پنل مدیریت»).
- **VELRO:** «ورود…» ← شمارهٔ تلفن کارمندی خود ← «فرستادن کد» ← کدی که با پیامک می‌آید ← «ورود». VELRO فقط به شماره‌ای
  کد می‌فرستد که نقش کارمندی دارد (با `scripts/grant-admin.py` روی سرور). شماره ذخیره نمی‌شود. می‌بینید: راننده‌های در
  انتظار تأیید و وضعیت اسنادشان، سفرهای در جریان و ۲۴ ساعت آینده، ایستگاه‌ها، مسیرها و کمیشن. VELRO محیط آزمایشی
  ندارد، پس این برنامه فقط می‌خواند؛ تأیید راننده در کنسول وب VELRO است.
- **اگر از VELRO خارج شدید:** اگر هنگام تازه کردن نشست اینترنت قطع شود، برنامه نشست همین دستگاه را پاک می‌کند تا توکن
  کهنه دوباره فرستاده نشود؛ با کد تازه دوباره وارد شوید. کنسول وب شما دست نمی‌خورد.
- **داشبورد:** کارت «منتظر شما» تعداد تالارهای در انتظار، بررسی‌های هویت و تأیید سالون‌ها، و راننده‌های در انتظار را
  با محیط و وقت خواندن نشان می‌دهد. وقتی صفی در Production از صفر بیشتر شود اطلاعیه می‌آید (تنظیمات ← Integrations ← Operations).

## Social media (Phase 5)

LinkedIn, Facebook, Instagram, X and YouTube. OAuth per network, tokens stored
on the backend. Publishing always goes through a draft → approve → publish
workflow.

## AI providers (Phase 6)

Model API keys are stored on the backend. Requests contain only the data
needed for the question. See [market-intelligence.md](market-intelligence.md)
and the AI assistant section of ARCHITECTURE.md.
