# Automation

Linumic OS runs every read it knows on its own schedule, with or without a window, and records each run.
Nothing new is written to any product: each job calls the same read its screen's Refresh button calls, with the
credentials already in this device's Keychain.

## Layers

| Layer | Where | Runs when | Status |
|---|---|---|---|
| Automation engine | This Mac (menu bar) or iPhone | The app runs; at login if enabled | Implemented (this document) |
| Sentinel | Supabase (pg_cron + Edge Function) | Always, every 10 minutes | Deployed 2026-10-19 00:57 UTC: [sentinel.md](sentinel.md) |
| CI | GitHub Actions | Every pull request and push to main | `.github/workflows/ci.yml` (PR #12) |

## Jobs (`AutomationCatalog`)

| Job | Every | Needs | Notes |
|---|---|---|---|
| Monitor | 5 min (longer after silent rounds) | network | public GETs only |
| Server watch | 10 min | cloud sign-in | reads the Sentinel RPCs; notifies new server events; says "not deployed" only if the server side is missing |
| Store listings | 30 min | network | console reads only with saved keys; switch in Settings → Integrations |
| Oversight sweep | 30 min | GitHub token | plus local working copies when a folder is granted |
| Platforms | 30 min | GitHub token | |
| Release Center | 30 min | any of ASC key, Play account, GitHub | |
| Licence sync | 30 min | cloud sign-in | |
| WorkTrack customers | 6 h | vendor sign-in | several reads per company, so not more often; then Money's revenue, CRM accounts and CRM invoices (GET), one at a time, so invoices are filtered with the TEST marks of the same reading; a Money failure makes the run partial, not failed ([money.md](money.md)) |
| Operations | 30 min | sign-in per product | VELRO counts are expensive; SafeBeauty counts are billed; also SafeBeauty's balance totals for Money (two aggregation queries, after the snapshot, separately; a failure makes the run partial) |
| Website messages | 30 min | WordPress application password | |
| Keys & Backups | 1 h | a granted folder (Mac only) | attributes only, never contents |
| Local inventory backup | 24 h, or a minute after its file is gone | nothing | see below |
| Ledgers | 30 min | a granted ledger folder (Mac only) | the PRIORITIES.md files and the newest NEXT-ACTIONS for the Desk, read-only; runs just before the Brief; without a grant it still records each ledger as "not granted" for the Desk |
| Daily Brief | 30 min | nothing | runs last: summarises what the others read, reads `Backups/`, posts obligation alerts ([obligations.md](obligations.md)) |

## Scheduling (`AutomationScheduler`, pure and tested)

- **Due:** never run, or one cadence after the last run finished. Low Power Mode doubles every cadence.
- **Failure:** retried after `retryAfter` (2 minutes for most jobs), doubling with each failure in a row, never
  slower than the cadence. A success resets the count.
- **Skipped** runs (offline, not connected, turned off, already running from its screen) count as neither failure nor
  success and wait a full cadence.
- **Offline:** network jobs simply wait; the engine runs them when `NWPathMonitor` reports the network back.
- **Wake:** the Mac waking (or the iPhone app returning to the front) wakes the loop at once.
- **Pause:** 1 hour, 3 hours or until 08:00 tomorrow; "Run now" still works while paused.
- **One at a time:** every run, scheduled or manual, goes through one serial queue, so two refreshes never overlap.

## Run log

`automation.json` next to the inventory (Application Support/LinumicCommandCenter): per-job state, the newest 500 runs
(none older than 14 days), disabled jobs, the pause, quiet hours. Unknown job ids from another version are dropped on
load, not treated as corruption.

Health: **ok**, **attention** (a job's last run failed), **failing** (a job failed 3 times in a row). Failing posts one
notification ("… keeps failing") and one when it recovers. Health appears in the menu bar, the dashboard strip, the
Automation screen and as an Automation section of the Daily Brief.

## Quiet hours

Default 23:00–07:00. During them, alerts (Monitor, stores, oversight, operations, website messages, automation) are
delivered silently to Notification Center: no banner, no sound. Scheduled reminders the owner chose a time for
(licence and WorkTrack expiry, the morning Brief) are not changed.

## Local inventory backup (`InventoryBackup`)

Daily copy of `inventory.json` to `Backups/inventory-YYYY-MM-DD.json` (Gregorian date, local time zone, whatever
calendar the Mac uses). Each copy is decoded after writing with the same decoder a restore uses, so a backup counts only
when it is proven to restore. A copy identical to the newest one is not written again. The newest 30 are kept. This
covers the local file on this Mac only; the cloud copy is the Sentinel's weekly `inventory_snapshots` (same Supabase
project), and the copy off this Mac is the encrypted continuity export ([continuity.md](continuity.md)).

### What `Backups/` holds, not what the log says (2026-10-19)

On 2026-10-19 the run log said "Copy saved and read back: 12 products" (00:00:01Z) while `Backups/` was empty. The
folder's own times tell what happened: it was created by that run (birth 2026-10-18 20:00:01 EDT) and changed again at
20:01:06, 65 seconds later, when the file in it was removed; the app removes a backup only beyond the newest 30. Nothing
looked at the folder again, so the job was not due for 24 hours and every screen showed a green run.

Now:

- Each run that did the work records the file it wrote or confirmed (`AutomationJobState.artifact`). On every look of
  the loop the engine lists `Backups/`; when that file is gone, the job is due **one minute after the run**
  (`AutomationScheduler.artifactRecheck`) instead of a day later, so it runs at the loop's next look: within the
  loop's longest sleep, 5 minutes (`AutomationScheduler.maxSleep`), while the job is on and automation is not paused.
  After a failure the usual backoff holds, so it can't spin. A run log from before this change has no artifact: then
  the file counts as gone when no file in the folder is named for the day that run ran (an empty folder, or only older
  copies left), which costs at most one extra run.
- `InventoryBackup.status()` reads the folder (newest file, its day, decoded as a restore would, same as the inventory
  now or not, or why it can't be listed) at launch, after each backup run and before each Brief.
- The Desk shows a "Daily backup" line from that reading, and the backup job's card shows the folder beside its log.
  The Brief's Automation section (and so the Desk) has a **high** item for an empty folder after a "succeeded" run or a
  newest copy that does not restore, and a normal one for no backup yet, a newest copy older than 2 days, or a recorded
  file that is gone while others remain. A run that found the inventory unchanged writes no new file but confirms the
  newest one: when it vouched for that very file and the file still holds the inventory as it is now, the copy's age is
  counted from that run, not from the day in its name. The empty-folder line says when the job runs again: at the
  next look (within 5 minutes), or that it is turned off, or that automation is paused until a given time; a job that ran while the folder was not looked at is a part not read, never
  "all clear".
- The run note names the file: "inventory-2026-10-19.json saved and read back: 12 products".

## Mac: menu bar, login item, Dock

- **Menu bar** (on by default): health, Monitor counts, the top "Waiting on you" items, jobs that need a look with
  Run now, Run all, Pause, Open Linumic OS, Quit.
- **Open at login:** `SMAppService.mainApp`. If macOS asks for approval, the screen links to Login Items.
- **Hide the Dock icon when no window is open** and **Start in the menu bar** (both off by default).
- Closing the last window no longer quits the app.

## iPhone and iPad

`BGAppRefreshTask` `com.linumic.commandcenter.refresh` (Info.plist `BGTaskSchedulerPermittedIdentifiers`, background
mode `fetch`). iOS decides when, or whether, it runs; the app asks for one about every 30 minutes when it goes to the
background. Only light jobs run there: Monitor, Server watch and the Daily Brief. Server watch is what brings an
outage the server saw while the Mac was off to the iPhone as a notification, without a push service.

## For the owner (دری)

- برنامه حالا خودش کار می‌کند، حتی وقتی پنجره بسته است. آیکون آن در نوار منوی بالای صفحه است.
- برای اینکه با روشن شدن مک خودش باز شود: «خودکارسازی» ← «باز شدن هنگام ورود به مک». اگر macOS اجازه خواست، دکمهٔ «باز کردن Login Items» را بزنید و Linumic OS را روشن کنید.
- هر کار با یک کلید روشن و خاموش می‌شود و «اجرا همین حالا» دارد. تاریخچهٔ همهٔ اجراها پایین همان صفحه است.
- اگر کاری سه بار پشت سر هم ناکام شود، یک اعلان می‌آید. شب‌ها (۱۱ شب تا ۷ صبح) اعلان‌ها بی‌صدا می‌آیند.
- «پیام‌های سایت» تا وقتی «Enable Abilities» در SureForms روشن نشود «وصل نیست» ثبت می‌شود (نه ناکام؛ از PR #18). برای خواندن پیام‌ها آن را روشن کنید و رمز برنامهٔ WordPress را در تنظیمات بگذارید.
- پشتیبان روزانه همان است که در پوشهٔ Backups/ هست، نه آنچه دفتر اجرا می‌گوید. اگر فایل پاک شود، کار پشتیبان در سرکشی بعدی خودکارسازی (تا ۵ دقیقه) دوباره اجرا می‌شود، به شرطی که روشن باشد و خودکارسازی متوقف نباشد؛ «میز کار» تا آن وقت آن را «امروز» نشان می‌دهد. اگر کار پشتیبان خاموش یا خودکارسازی متوقف باشد، همان سطر همین را می‌گوید.
