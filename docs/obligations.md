# Obligations and accounts (تعهدات و حساب‌ها)

Module 3 of [company-os-roadmap.md](company-os-roadmap.md), Phase 2. The dated things no system reminds the company of,
and the accounts it depends on. Local only (`obligations.json` on this device); no network, no Supabase table until
Phase 3.

## What a row is

| Field | Meaning |
|---|---|
| title | What is due. English for the seed and live rows (shown in Dari through the catalog), the owner's own words for his rows. |
| due | The day, or **nil = date unknown**. An unknown date is its own lane and its own Desk item, never a guess. |
| consequence | What happens if it is missed, **only when a source says it**. |
| source | Where the fact comes from (file and line, a page, a reading). Never empty. |
| recordedOn | The day the fact was recorded in that source (or read). |
| leadDays | 30, 14, 7 and 1: the alert windows. |
| origin | `seed`, `owner`, `account` (a renewal) or live: `domain` (RDAP), `certificate` (TLS), `licence`, `keys`, `continuity`. |

`validate()` (`ObligationsBuilder.validate`) refuses, and the builder does not apply:

- a row or account without a source, or without the day it was recorded;
- a Done without evidence;
- a date, holder or cost set without its source;
- two rows with one id; a row without a title.

Each refusal is a high line in the Daily Brief (so it is under Today on the Desk) and a red card on the Obligations
screen. Entering one through the app is impossible: the sheets don't save without the source or the evidence.

## Lanes, lead windows and the Desk

| Timing | Lane (Obligations screen) | Severity | Desk |
|---|---|---|---|
| Past its day | Overdue | high | Today |
| Today or tomorrow (the 1-day window) | Within 7 days | high | Today |
| 2 to 7 days (the 7-day window) | Within 7 days | normal | This week |
| 8 to 14 days (the 14-day window) | Within 30 days | normal | This week |
| 15 to 30 days (the 30-day window) | Within 30 days | info | Later |
| Beyond 30 days | Later | info | Later |
| Date unknown | Date unknown | info | Later |
| No encrypted export yet (continuity) | Date unknown | normal | This week |

The Desk puts a dated item by its day and its own window, not by the focus-product rule (a SafeBeauty post time due in
12 days is this week's). The Brief's Obligations section leaves out what another section already says: a domain or a
licence inside the Monitor's or the Licences' 30-day window, the Keys & Backups reminders, and TLS certificates (they
renew by themselves; the Monitor brings one forward from 30 days before it ends). Those stay on the Obligations screen.

**Done** on an obligation needs evidence and holds for that due day only: a renewed licence, or the next period of a
yearly item, opens again. On the Desk, an obligation's Done opens the evidence sheet.

**Alerts:** one notification when an obligation enters a window (30, 14, 7, 1 days) and on or after its day, posted
after each Daily Brief round (every 30 minutes while the app runs), once per window. The key is
`obligation:<id>:<due>:<lead>`, the same key a Phase 3 server sweep would use. Live rows alert through their own
screens (Monitor, Licences) and are left out. Settings: the switch on the Obligations screen
(`LCCNotifyObligations`).

## Where the rows come from

### Live, read by the app itself

| Source | Rows |
|---|---|
| Monitor RDAP reading (`monitor.json`) | `domain.<name>`: registration end; replaces the seed's `domain.linumic.com` once read |
| Monitor TLS readings | `tls.<host>`: certificate end, monitored hosts only |
| Licence ledger | `licence.<id>`: active licences with an end day (no customer name) |
| Keys & Backups registry | `keys.restore.<backup>`: next restore test (90 days after the last), or "no restore test recorded"; `keys.second-copy` while that gap is open |
| Continuity log (`continuity.json`) | `continuity.export`: 30 days after the last verified export, or "no encrypted copy off this Mac yet" |

### Seed (`ObligationSeed`, revision 1)

Only facts already recorded with a source. NA = `~/Projects/Multiplatform/NEXT-ACTIONS-2026-10-19.md`,
M = `~/.claude/projects/-Users-aminullahhashemi/memory/`.

| Id | Due | Source |
|---|---|---|
| `signing.developer-id-certificate` | 2027-02-01 | This Mac's Keychain (below) |
| `signing.linumicos-mac-profile` | 2027-09-23 | NA:147; the installed profile (below) |
| `marketing.safebeauty-dst-pashto` | 2026-10-31 | NA:119; M/safebeauty-marketing.md:57 |
| `marketing.safebeauty-dst-reels` | 2026-11-10 | NA:119; M/safebeauty-marketing.md:57 |
| `marketing.worktrack-queue-end` | 2026-10-26 | M/worktrack-marketing.md:15; NA:117 |
| `domain.linumic.com` | 2029-08-15 | docs/integrations.md:548-551 (RDAP, 2026-10-09) |
| `stores.play-target-api` | unknown | docs/product-discovery-report.md:79 (the 2026 deadline was 31 August; the next is not recorded) |

**The 2027-09-23 date.** The roadmap's Phase 2 names "Developer ID, 2027-09-23". NA:147 says «پروفایل تا ۲۰۲۷-۰۹-۲۳
اعتبار دارد» (the profile is valid until 2027-09-23), and on this Mac (read 2026-10-19):

- `Mac Team Provisioning Profile: com.linumic.commandcenter` (a development profile) expires 2027-09-23
  (`security cms -D` of `~/Library/Developer/Xcode/UserData/Provisioning Profiles/501a3449-….provisionprofile`);
- the certificate `Developer ID Application: AMINULLAH HASHEMI (27RXPRW77S)` is not valid after
  **2027-02-01 22:12:15 GMT**, and its issuer, `Developer ID Certification Authority`, ends at the same second
  (`security find-certificate -c "Developer ID Application" -p | openssl x509 -noout -enddate`).

So both are rows: the profile with the roadmap's date, and the certificate with its own, earlier one.
`tools/release/build-release.sh` signs with that certificate. What happens to copies already signed after it ends is
not recorded in any source, so the row does not say.

### Accounts (`ObligationSeed.accounts`)

| Account | Holder | Source |
|---|---|---|
| Apple Developer Program (team 27RXPRW77S) | personal | M/linumic-command-center.md:21; docs/product-discovery-report.md:62 |
| Google Play Console (7764339598095587681) | personal | M/linumic-command-center.md:40; PRIORITIES.md:78 |
| GoDaddy (registrar, WordPress host) | not recorded | docs/integrations.md:550; M/linumic-site.md:11, :107 |
| Microsoft 365 (contact@linumic.com) | not recorded | M/linumic-site.md:107 |
| Hetzner (VELRO server) | not recorded | Velro/PRIORITIES.md:9 |
| Google Cloud and Firebase | not recorded | M/worktrack-strengthen-platform.md:13; M/safebeauty-marketing.md:49 |
| Supabase (Free plan) | not recorded | docs/backend-plan.md:9; M/linumic-command-center.md:48 |
| GitHub (aminullah-dev) | personal | GitHub API `users/aminullah-dev`: type User (read 2026-10-19); NA:67 |
| Meta ad account (act 1061522111943056) | personal | M/safebeauty-marketing.md:29 |
| ElevenLabs | not recorded | M/be-paya-game.md:17 |
| Notion | not recorded | M/linumic-licensing.md:30 |

Every renewal date and every cost starts unknown; each account's renewal is an obligation ("renewal date unknown")
until the owner enters it with its source. A cost is one amount in one currency (never converted, never added to
another currency), how often, and the bill it was read from. Never a password or a card number: sign-ins are in the
Vault. After the company is registered, the holder column is the list of what to move.

## Files

`obligations.json` next to the inventory: the owner's rows, the dates he set (with sources), Done with evidence (per
due day), his accounts and the facts he recorded about accounts (renewal, holder, cost, each with a source). The seed
and the live rows are never stored there: a corrected seed never overwrites what he entered. A file that can't be
read is reported and never overwritten.

## For the owner (دری)

- در «تعهدات و حساب‌ها» هر موعد با منبع و روز ثبتش دیده می‌شود. «انجام شد…» فقط با مدرک ذخیره می‌شود.
- تاریخ عضویت Apple و هر مبلغی را که از صورت‌حساب می‌دانید، در کارت همان حساب با «ویرایش…» و منبعش وارد کنید.
- تاریخ ۲۰۲۷-۰۹-۲۳ تاریخ پروفایل توسعه است؛ گواهی Developer ID خودش در ۲۰۲۷-۰۲-۰۱ تمام می‌شود.
