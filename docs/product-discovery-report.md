# Product Discovery Report

**Date:** 2026-09-23
**Method:** read-only. Nothing outside `~/Projects/Linumic/LinumicCommandCenter` was modified: no branch changes, no commits, no pushes, no writes to other repositories.

| Source | What was read |
|---|---|
| Local working copies | `~/Projects/{Multiplatform,Android,Desktop,Web,Research,Marketing,_Archive}`: `git remote/branch/log` (read-only), build files (`build.gradle*`, `project.yml`, `*.xcodeproj`, `package.json`, `pyproject.toml`, `pubspec.yaml`, `.firebaserc`), READMEs |
| GitHub REST API | `gh api` GET requests only: repository metadata, default-branch commit, releases, open PRs/issues, languages. Snapshot saved in `tools/inventory/evidence/github-2026-09-23.json` |
| linumic.com | Products index, the 6 product pages, About, sitemap, download links |
| App Store | Apple's public lookup API by bundle ID (US and AF storefronts) |
| App Store Connect | The owner's app-list screenshot (`tools/inventory/evidence/app-store-connect-apps-2026-09-23.png`) |
| Google Play | Public listing pages by application ID |

Every fact in Linumic OS carries its source and date, and can be regenerated with `python3 tools/inventory/build_seed.py`. Folder names were **not** used as evidence for platforms: platforms come from build configuration, store listings or release assets.

Verification states used throughout:

| State | Meaning |
|---|---|
| **VERIFIED** | A primary source states it directly (build config, GitHub API, store listing, owner) |
| **PARTIALLY VERIFIED** | Indirect or partial evidence (a README claim, or an inference from a live listing) |
| **UNKNOWN** | No evidence found. Shown as "Unknown — to be verified" |
| **CONFLICTING** | Sources disagree. Needs the owner |

---

## Confirmed Products

All 12 are on the owner's product list **and** have a repository with matching evidence.
"On linumic.com" means the product appears on the public products index.

| Product | Repositories (type) | Evidenced platforms | Public availability | On linumic.com |
|---|---|---|---|---|
| **Safe Beauty** (SafeBeauty) | `stealth-service-vault-` (monorepo), `safebeauty-privacy` (website) | Android, iOS, Web, Backend, macOS, Windows | App Store 1.0.1 (AF storefront); Google Play (listed) | Yes: enterprise + consumer |
| **Velro** (VELRO) | `velro` (monorepo) | Android ×2, iOS ×3, macOS, watchOS, Web, Backend | App Store: Ride 1.0.0, Driver 1.0.0 live, 1.0.1 pending for both; Ops iOS/macOS 1.0 pending; Android APKs at api.velro.linumic.com/app | Yes |
| **WorkTrack** (Linumic WorkTrack) | `WorkTrack` (monorepo) | Android, iOS, Web, Backend, Desktop (partial) | App Store 1.0; live web demo | Yes |
| **DukanPro** | `DukanPro` (monorepo) | Android, iOS, macOS, Backend | None found | **No** |
| **Talar** (تالار) | `talar` (monorepo), `talar-releases` (releases) | Android, Web, Backend, Desktop (partial) | APK v1.0.0 via talar-releases; sandbox demo | Yes |
| **NerkhTimes** (نرخ تایمز) | `NerkhTimes` (application), `nerkhtimes.github.io` (website) | Android, iOS, Backend (partial) | App Store 1.0; Google Play (listed) | Yes: consumer app |
| **Namazia** (Afghan Prayer Times) | `-Namazia` (application) | Android, iOS | App Store 1.0 as "Afghan Prayer Times" | **No** |
| **AfghanJama** (KhayatYar / خیاط‌یار / Tailor ERP) | `AfghanJama` (application) | Android, macOS, Windows, iOS (partial, branch only) | GitHub release v1.8.0 (apk/dmg/msi), linked from linumic.com | Yes, as "Tailor ERP" |
| **SODER-HAKEM** (سوډر حاکم) | `SODER-HAKEM` (application) | Android | Sideloaded APK 1.0 | **No** |
| **MediFlow** | `MediFlow` (application), `Marketing/marketing` (local marketing folder) | Windows, macOS (partial) | GitHub release v0.2.0 (Windows zip), linked from linumic.com | Yes |
| **Tailoring Workshop ERP** (Darzi / درزی) | `Tailoring-Workshop-ERP` (application) | Web, Backend | None | **No** (the linumic.com Tailor ERP page is AfghanJama, owner-confirmed) |
| **The Digital Infrastructure of the Pashto Language** (pashto-text) | `The-Digital-Infrastructure-of-the-Pashto-Language` (research) | Research | None | **No** |

### Focus: App Store Connect (owner's screenshot)

| App | State in App Store Connect | Public App Store |
|---|---|---|
| SafeBeauty | iOS 1.0.1 ✓ | 1.0.1 (AF storefront only) |
| VELRO Driver | iOS 1.0.1 pending (yellow clock) | 1.0.0 |
| VELRO Ride | iOS 1.0.1 pending (yellow clock) | 1.0.0 |
| Linumic WorkTrack | iOS 1.0 ✓ | 1.0 |
| VELRO Ops | iOS 1.0 + macOS 1.0 pending (yellow clock) | not public |
| Nerkh Times - نرخ تایمز | iOS 1.0 ✓ | 1.0 |
| Afghan Prayer Times | iOS 1.0 ✓ | 1.0 |

The yellow clock is recorded only as "pending". The screenshot doesn't show which review state it is.
No App Store record exists for DukanPro, Talar, KhayatYar (the site says "iPhone — in preparation"), MediFlow, SODER-HAKEM or the Pashto project.
Every App Store listing names the seller as the individual account **"AMINULLAH HASHEMI"**, not Linumic.

### Focus: Google Play Console (read in the owner's Chrome, 2026-09-23, view only)

Personal developer account "Aminullah Hashemi" with **6 apps**:

| App | Package | Production | Testing | Installed audience |
|---|---|---|---|---|
| SafeBeauty | com.security.stealthapp | **2.1.5** (code 22), live, 177 countries, Sep 23 | closed 1.9 (14), internal 1.0 (3) | 12 |
| NerkhTimes | af.market.nerkhtimes | **1.0.10** (code 10), live, 177 countries, Aug 27 | closed draft | 14 |
| Afghan Prayer Times (Namazia) | af.namazia.app | **1.1.0 (code 4) in review** since Sep 16 | closed 1.0.1 (2) | 15 |
| Linumic WorkTrack | app.worktrack | none | closed 1.2.0 (4), Sep 16 | 13 |
| VELRO Driver | af.velro.driver | none | closed and internal 1.2.3 (6), Sep 14 | 13 |
| VELRO Ride | af.velro.passenger | none | closed and internal 1.2.3 (6), Sep 14 | 13 |

**Account notices seen (critical):**
- "Ensure your apps are registered for Android developer verification by Sep 30, 2026."
- "Update your target API level by August 31, 2026 to release updates to your app" (2 apps; which ones wasn't recorded).
- SafeBeauty: "One deep link may be failing because your web domains aren't associated with your app."

Nothing was changed in Play Console.

### Focus: MediFlow

- **What it is:** an offline clinic and hospital management system for one machine: Python 3.13, PySide6, SQLite, Dari/Pashto/English with right-to-left support, 16 modules (README table; the linumic.com page says the same).
- **Version:** 0.2.0. Tag `v0.2.0`, a GitHub release on 2026-08-27 with one asset (`MediFlow-0.2.0-windows.zip`), and `pyproject.toml` all agree. The linumic.com download button points at that asset.
- **Development status:** development (partially verified). The README roadmap marks Phases 1–6 done and **Phase 7 (printing & packaging) in progress**, with A4/thermal printing and receipt/prescription/report templates still open. The site says "a double-click installer is coming in the next release".
- **Platforms:** Windows is verified (release asset). macOS is only partially verified: packaging, signing and notarisation exist in the source (commit `2080819`, 2026-09-18), but no macOS build has been released or offered on the site.
- **Engineering signals:** 26 commits since 2026-07-23. GitHub Actions CI passed on `main` on 2026-09-22. The README reports 117 passing tests; a local count found about 145 test functions in 8 files.
- **Ownership signal:** `LICENSE` reads "Copyright (c) 2026 Aminullah Hashemi", a proprietary licence held personally, not by Linumic. The README flags PySide6 being LGPL v3 as a condition to review before the first sale.
- **Marketing:** `~/Projects/Marketing/marketing` holds MediFlow posts, cards and screenshots in Dari and Pashto. It was moved out of the repository in commit `3f93267`.

### Focus: linumic.com

- The products index presents **six enterprise products**: MediFlow (Healthcare), WorkTrack (Workforce), Talar (Hospitality), Tailor ERP (Manufacturing), SafeBeauty (Marketplace) and VELRO (Transportation). It also lists **two consumer apps**, NerkhTimes and SafeBeauty, both marked "Android · free".
- It does **not** list DukanPro, Namazia, SODER-HAKEM, the Pashto project, or the Darzi Tailoring Workshop ERP.
- Download links on the site: Tailor ERP → AfghanJama `v1.8.0` (apk, msi, dmg); MediFlow → MediFlow `v0.2.0` Windows zip; Talar → talar-releases `v1.0.0` apk; VELRO → `api.velro.linumic.com/app` (both APKs, HTTP 200); SafeBeauty → Google Play and `safebeauty.web.app/get`; WorkTrack → live demo at `/what-we-do/worktrack/demo/`.
- The product pages for VELRO, WorkTrack and SafeBeauty **don't mention the iOS apps** that are live on the App Store.
- The About page names **Amin Hashemi, Founder and CEO**.

---

## Possible Products

None. Gul-E-Lala (`~/Projects/Web/Gul -E- Lala`, a Remotion motion-graphics project) was **removed at the owner's instruction** on 2026-09-23.

## Related Repositories

Repositories whose relationship to a product is unclear.

| Repository | Findings |
|---|---|
| `Radar-system` (private), **sidelined by the owner** | Created 2026-07-28. One "Initial commit" containing only `README.md` ("# Radar-system"). No local copy. |
| `Explore_Afghanistan` (private) / `Explore-Afghanistan` (public, empty), **sidelined by the owner** | 2025-08-03. A static website (index.html, js, stylesheet, images). Predates every product repository. No Linumic reference. Contents not read in depth. |

Resolved during discovery, so they are no longer open questions:

| Repository | Resolution | Evidence |
|---|---|---|
| `stealth-service-vault-` | **Is** the Safe Beauty repository | GitHub description "SafeBeauty — …", homepage linumic.com/what-we-do/safebeauty, README "# SafeBeauty" |
| `talar-releases` | Talar **release repository** (installer downloads; source is private) | GitHub description; its v1.0.0 APK is linked from linumic.com |
| `nerkhtimes.github.io` | NerkhTimes **landing and privacy pages** | GitHub description; page live |
| `safebeauty-privacy` | SafeBeauty **privacy-policy pages** | GitHub description |
| `Marketing/pipeline` (local folder) | SafeBeauty marketing image generator (partially verified) | Its README runs from `~/Documents/"SafeBeauty Marketing"` |
| `_Archive/*` | Older copies of Safe Beauty, AfghanJama, NerkhTimes, and a WorkTrack zip. **No new products.** | Same Git remotes as the active working copies |

## Non-Product Projects

| Project | Why |
|---|---|
| Coursework and learning repositories (`The-Tech-Academy*`, `python-1-to-30`, `HTML-and-CSS-Projects`, `CSS-Bootstrap`, `JavaScript-Projects`, `bootstrap4_project`, `basic-html-website`, `project`, `Six-Part-Assignment`, `myConsoleProject`, `FinalProjectModule`, `CodeFirstStudentDemo`, `Student-Portal`, `My-College`, `MyMusicSite`, `Portfolio`, `virtual_dr`, `Insurance`, `Sm_p`, `queue-appointments-en-fr`, `HTML-documents`) | Created 2025-06 → 2026-01, before any product repository. Descriptions where present say so ("HTML & CSS Course…", "About The Tech Academy"). Not inspected in depth. |
| **Kabul Signal** (kabulsignal.com, `kabul-signal-android`) | A separate organization (Kabul Signal Media Organization, a Canadian not-for-profit, per its own About and Masthead pages). **Removed from Linumic OS at the owner's instruction on 2026-09-23.** |

---

## Owner answers (2026-09-23)

| Question | Answer | Recorded as |
|---|---|---|
| Tailor ERP identity | "KhayatYar is the same as AfghanJama." | AfghanJama = Tailor ERP (owner-confirmed). The website conflict is resolved. |
| Darzi (Tailoring-Workshop-ERP) | "Move Darzi to the sidelines for now." | Priority: Sidelined. It's left out of attention lists. |
| Legal owner | "The owner is me; Linumic is only the mother (umbrella) of the projects." | Legal owner: Aminullah Hashemi, on every product |
| Gul-E-Lala | "Remove." | Removed from Linumic OS |
| Radar-system, Explore Afghanistan | "Sideline." | Sidelined. No question pending. |
| MediFlow | "A medical system; it matters." | Category: Medical. Priority: High. |
| SODER-HAKEM | "It's a book." | Category: book (reader app for the owner's Pashto book) |

## Questions Requiring Owner Confirmation (still open)

Per product, the app's Verification tab lists every item still awaiting confirmation, and
[product-inventory.md](product-inventory.md#verification-by-area-seed-revision-4) summarises them by area.

1. **Development status.** "Active" is inferred from live listings or releases for SafeBeauty, VELRO, WorkTrack, Talar,
   NerkhTimes, Namazia and AfghanJama. Please confirm, and give the status for SODER-HAKEM and the Pashto project.
2. **Product names.** Keep "AfghanJama" and "Namazia" as the record names, or use "KhayatYar" and "Afghan Prayer Times"?
3. **NerkhTimes backend.** Is the production data source the Google Apps Script plus Sheet in `admin/README.md`?
4. **Namazia and Pashto project branches.** GitHub `main` holds only "Initial commit"; the code is on a feature branch.
5. ~~**Google Play Console.**~~ Resolved: read on 2026-09-23 (view only), see "Focus: Google Play Console" above.
