# Sales (فروش)

Phase 5 of [company-os-roadmap.md](company-os-roadmap.md), module 6: **who do I call today**, WorkTrack first.
Read-only. Sales reuses what the app already reads (WorkTrack's company list and CRM accounts, the website messages,
SafeBeauty's KYC queue) and adds no key, no automation job and no Supabase migration. Linumic OS never writes to the
CRM: dates and stages are changed in the WorkTrack console. A part that was not read is **Unknown** with its reason,
never an empty list or a zero.

Code: `LinumicCore/Sales` (`SalesInput`, `SalesBuilder`, `SalesBrief`, `SalesDraft`, `SalesDismissReason`), the CRM
reads in `LinumicCore/Integrations` (`WorkTrackVendor.swift`: the widened `WTCrmAccount`, `crmContacts(accountId:)`,
`crmAccountsShape()`, `WorkTrackSalesReading`; `WorkTrackCRMShape.swift`), `App/SalesCollect.swift`,
`App/Views/SalesViews.swift` and the Sales reads in `App/WorkTrackModel.swift`. Tests: `SalesTests.swift`,
`SalesDraftTests.swift`, `SalesReadOnlyTests.swift`.

Sources were read at WorkTrack `origin/main` 0403fd0 and SafeBeauty `origin/main` 3688474. Paths under WorkTrack are
relative to `backend/functions/src/` unless they start with `web/`.

## What Sales lists, and from where

| Item | Source | On the Desk? |
|---|---|---|
| **Call today**: follow-ups whose `nextActionAt` is today or earlier in Kabul, any stage (as WorkTrack's own dashboard) | `GET /v1/vendor/crm/accounts`, already read by the WorkTrack refresh for Money (`routes/vendor.ts:339-345`, `services/crm.ts:198-206`, `:252-272`) | Yes, a Sales item in **Today** (`sales.followup.<hash>`) |
| **This week**: follow-ups in the next 7 days | the same | Yes, in **This week** (information) |
| **Date could not be read**: a `nextActionAt` that is not a real day (`2026-02-31`, `2026-1-5`) or not a string | the same | Yes, normal (Today, WorkTrack) |
| **No next step**: open accounts (LEAD, CONTACTED, DEMO, QUOTED, or an unknown stage) with no `nextActionAt` | the same | Yes, one item `sales.nodate` (Today, WorkTrack): WorkTrack's own Today tab never shows such a lead (`crm.ts:264`) |
| **Later**: follow-ups more than 7 days away | the same | No, the page only (a note in the Brief) |
| **New signups without a CRM account**: a company created in the last 14 Kabul days (`TRIAL_DAYS`, `services/plans.ts:101`) or one that bought a plan itself (`license.source == "SELF_SERVE"`, `services/billing.ts:386`), with no CRM account | `GET /v1/vendor/companies` (same refresh) and the accounts | A self-serve or non-trial signup: yes (`sales.signup.<hash>`). A new trial is already a WorkTrack "trial ending" item: page only, never a second item |
| Other companies with no CRM account | the same | One information item `sales.nocrm` (Later) |
| **Renewals and trials ending** within 30 days, or ended | the company list (`WTCustomersSummary`, TEST and DUPLICATE left out) | Already WorkTrack customers items: page only |
| **Website messages** not marked seen | the existing reading (`SiteMessagesModel`) | Already Website messages items: page only |
| **SafeBeauty: providers waiting for KYC**: a count, never names | the existing Operations snapshot: `kycQueue` roles (`role == "PROVIDER"`, SafeBeauty `functions/lib/registration.js:39-41`) and `kycPendingCount` | Already the Operations item `ops.safeBeautyKYC`: page only |

"SELF_SERVE" is not a signup marker on its own: `license.source` says who last wrote the licence, a new trial is written
as `VENDOR` (`services/signup.ts:22-33`), and any vendor licence write sets it back to `VENDOR` (`services/license.ts:176-197`).
Each signup row says why it is listed ("signed up …" or "bought a plan itself").

**Has a CRM account** means that an account row, in any stage, has `companyId` equal to the company's. One exception: the
WON account WorkTrack opens by itself on a company's first support ticket (`routes/support.ts:49-68`) does not count
while the company is still on its trial, so a trial that wrote in is still a signup. A company with a scheduled deletion
(`services/vendor.ts:124-126`) is not listed at all.

**The only new requests**, both GET and both started by the owner:

- `GET /v1/vendor/crm/contacts?accountId=<id>` when the owner opens **Contacts** on one account (or reads contacts for a
  draft's greeting). An empty id is refused in the client before any request: the server reads an empty `accountId` as
  no filter and would answer every contact (`routes/vendor.ts:342`).
- One `GET /v1/vendor/crm/accounts` for the owner's **response-shape check** (below).

Every other read is the WorkTrack refresh that already runs at launch, every 6 hours while the app is open, and on
**Read now** (Sales' Read now runs the WorkTrack refresh and the website messages, not SafeBeauty, whose counts are
billed per query).

## Kabul's day, as the server counts it

The server's "today" is the Gregorian date in `Asia/Kabul` (`routes/vendor.ts:52-54`); stored dates are `YYYY-MM-DD`
(`crm.ts:48`). Due now: `nextActionAt <= today` (text comparison, every stage, overdue without limit). Due soon:
`today < nextActionAt <= today + 7`, counted at UTC midnight (`crm.ts:260-272`). Sales computes the same from the
accounts it already read (`SalesBuilder.due`), and a test compares it with a copy of the server's rule for every pair
of days in October and November 2026.

| `nextActionAt` (today 2026-10-20) | Sales | Server |
|---|---|---|
| absent or `null` | no date | not listed |
| `2026-10-20` | Call today | dueNow |
| `2026-10-01` | 19 days overdue | dueNow |
| `2026-10-21` / `2026-10-27` | this week, in 1 / 7 days | dueSoon (the 7th day included) |
| `2026-10-28` | later (8 days) | not listed |
| `2026-02-31` | **date could not be read** | dueNow (text comparison): the one deliberate difference; the console's Today tab may list it |
| `2026-1-5` | date could not be read | refused on write by the regex; only a hand edit makes it |
| `20261020` (a number) | date could not be read | not listed |

**The Desk does not use this device's day for Sales.** A Sales line carries a `horizon` (`BriefLine.horizon`: Today for
due now, This week for due soon) and no `due`, so the Desk never compares it with the device's own date. The same
follow-up is in the same Desk list in America/Toronto, Asia/Kabul, Pacific/Kiritimati (UTC+14) and Pacific/Pago_Pago
(UTC−11); a test checks all four. Days are **shown** in the device's calendar (Solar Hijri on the owner's Mac) through
one formatter fixed to UTC (`WorkTrackDates.displayText`), which Money now uses too, so UTC+14 never shows the next day.

## TEST companies, limits and links

The rule is the server's and Money's: any mark (`flags != nil`, TEST or DUPLICATE) leaves a company out
(`services/vendor.ts:127`). CRM records have no mark of their own; they reach a company only through `companyId`.

| Case | Sales does |
|---|---|
| Account linked to a TEST or DUPLICATE company | Left out of every list and every Desk item; counted in a note; names in the collapsed "Left out" card |
| Account linked to a company that is **not in the list** (deleted, purged, or past the 500 limit; purge keeps CRM records, `crm.ts:8-11`) | Kept, with "whether it is a TEST company is unknown". It stays on the Desk by its day, but as information: it is **not** counted in the morning notification |
| No `companyId` (absent, null or blank) | A prospect, kept |
| Company list not read or failed | The whole WorkTrack part is Unknown: nothing is shown unfiltered |
| `rows + skipped >= 2000` (`crm.ts:204`: no order, ULID ids, so the newest accounts are the ones missing) | Signups and the no-CRM count are Unknown; a note (Money already raises this limit as a Desk item); marks on Sales lines are kept |
| An account set aside (`skipped > 0`) | One Desk item (Later): "N CRM accounts could not be read; their follow-ups, and whether a company has a CRM account, are unknown"; signups Unknown; marks kept |
| 500 companies (`services/vendor.ts:201`) | Signups found are listed; counts say "at least"; a note (Money raises it) |
| Not production | Every line is information with no horizon, so nothing reaches Today or the notification; a note (WorkTrack customers raises it) |

## Unknown reasons (each one a sentence, never a zero)

- Not signed in to WorkTrack, so who to call is unknown.
- The WorkTrack company list could not be read (WorkTrack customers says why), so who to call is unknown.
- Signed in, but the CRM accounts have not been read yet.
- The CRM accounts could not be read: <the error>.
- N CRM accounts could not be read, so whether a company has a CRM account is unknown.
- WorkTrack sent 2000 CRM accounts, the most it sends, so whether a company has a CRM account is unknown.
- WorkTrack reads at most 500 companies; signups past that are unknown.
- Read from the <environment> environment, not production.
- Renewals: not signed in, the company list failed, or not read yet (the WorkTrack customers sentences).
- Website messages: not connected, the last read failed, or not read yet (the Website messages sentences).
- SafeBeauty: not signed in, could not be read, or its queues not read yet.

On the Desk, one cause is one item. Not signed in, a failed company list and "not read yet" are one Sales item in the
shared group (Later), because the WorkTrack customers section already puts its own item in Today. A failed accounts read
is one item (This week). The limits and the environment are notes (`BriefGap.isDeskItem == false`, `isCaveat == true`):
they keep marks on Sales lines but make no second Desk item, since Money and WorkTrack customers raise them.

## The Desk and the notification

- Line ids: `brief.sales|sales.followup.<16 hex>|fact`, `…|sales.signup.<16 hex>|fact`, `…|sales.nodate|fact`,
  `…|sales.nocrm|fact`, `brief.sales|part.<key>|not-read`, `brief.sales|section|not-read` or `|unavailable`. The hex
  is `SalesKey` (`DeskHash.of("sales.account", id)` or `("sales.company", id)`), never the CRM's or WorkTrack's id.
- The fact: a moved `nextActionAt` is a new fact (Waiting or Dismiss falls away, Done reopens); a changed note is not.
  The two counts hash their members, so a new lead without a date is a new fact.
- A mark on a Sales line that is gone (account deleted, date cleared, company marked TEST) is dropped once the accounts
  were read after the mark, unless accounts were set aside or a limit was reached (`SalesBrief.readGapKeys`). Not
  production does not keep a mark. A "not read" section never drops one. A part's item (`part.worktrack.accounts.skipped`)
  is gone once the accounts are read whole.
- **Done here does not change the CRM.** Done hides a fact until the next reading; if the follow-up is still due, it
  comes back "still open". To clear it, move the date or the stage in the WorkTrack console.
- **Dismiss reasons are fixed** for every Sales item: "Called; the date is moved in the WorkTrack console", "Handled in
  the WorkTrack console", "Not someone to call", "A test or duplicate record", "Another reason (not written down)". A
  dismiss reason is synced to Supabase as written and kept in `audit_events`, and a typed one could name the customer:
  `DeskState.dismiss` refuses any other text for a Sales item, and `DeskCloudMapping.localMarks` sends anything else as
  "another reason". Other Desk items keep the owner's own words.
- **Morning notification:** Sales lines are folded into counts at the place of the first one: "N WorkTrack follow-ups
  are due" counts only follow-ups due today or overdue (by Kabul's day) in production whose company is not missing from
  the list; every other Sales line (a date that could not be read, accounts with no next step, a signup) is "N other
  Sales items need you" (or "N Sales items need you"). The total count is unchanged. No name reaches the lock screen.
- **Copy agent brief** for a Sales fact carries the hash only (`DeskAgentBrief.customerSections[.sales]`).

## Privacy: what never leaves the device

| Data | Held | Leaves the device? |
|---|---|---|
| Account name | memory (the WorkTrack model's money reading) | No. Page, Brief and Desk on this device only; not in the notification, the agent brief, Supabase or any file |
| Account id, company id | memory | Only as `SalesKey` hashes inside Desk ids (`desk-state.json`, and `desk_state` once synced) |
| Stage, `nextActionAt`, `nextAction` (the owner's note) | memory | No. The date is hashed into the fact hash; the note is shown in the Desk detail, which is never uploaded |
| `notes`, `city`, `industry`, `source`, `employeesEstimate`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt` | **never decoded** | They cross the wire (the API has no field mask) and are dropped while decoding |
| Contacts (name, role, phone, primary) | the popover or draft sheet while it is open | No. A number leaves only when the owner taps **Copy number** |
| Draft text | built on tap | Only by the owner's **Copy** |
| Shape report | the sheet while it is open | It holds key names, types and counts, never a value |
| KYC | the existing Operations snapshot | A count of roles only; names stay on the Operations screen |
| Dismiss reasons on Sales items | `desk-state.json`, synced | Only the fixed tokens (`sales.reason.*`) |

The WorkTrack client's session keeps no URL cache, so no CRM answer is stored on disk. Copy (a draft or a number) goes
through one `ClipboardGuard` owned by the WorkTrack model: on the Mac the text is marked concealed and transient (clipboard
managers skip it), on iPhone and iPad it is local only (never Universal Clipboard) and expires, and it is cleared after
two minutes if the clipboard still holds it. Phone numbers are not selectable text, so they can't be copied the ordinary
way.

## Reminder drafts (Dari and Pashto), copied only

A draft says only what the app read: the company's or account's name, a contact the owner read and picked, and the
licence's last day (`license.expiresAt`). It never uses the owner's note, the stage, a price, a phone number, a claim
about an earlier call, a promise or a discount. Words are the ones WorkTrack's customers already see (Dari «لایسنس»،
«آزمایشی»، «ورک‌ترک»، «لینومیک»; Pashto «جواز»، «ازمایښتي»، «ورک‌ټرک»، «لینومیک»: WorkTrack `web/src/i18n/strings.ts:437, 439,
452, 639` and `:1533, 1535, 1548, 1735`). Dates are Solar Hijri in the language's own month names and digits ("۲۸ میزان ۱۴۰۵",
"۲۸ تله ۱۴۰۵"). The Pashto avoids past-tense transitive verbs; its only past form is the copula «وه» with the feminine «ورځ».
Signed «لینومیک». Nothing is sent: there is no `sms:`, WhatsApp or `mailto:` link for a draft.

| Kind | Offered when |
|---|---|
| Ask for a call | every account row and renewal row |
| Licence ending / Trial ending | the licence is **ACTIVE** and its last day is 0 to 30 days from Kabul's today, **counted again** from `expiresAt` when the draft is built (not the server's `daysUntilExpiry`, which can be hours old) |
| Licence ended / Trial ended | the last day, counted again, is **before** Kabul's today |
| Welcome | a signup row |

A SUSPENDED licence never gets "valid until", an EXPIRED one whose last day is still ahead never gets "the last day was",
and a perpetual licence gets no dated draft. `SalesDraft.text` checks the same rule again and returns no draft when a
fact is missing or no longer holds.

## The response-shape check (the roadmap's "one GET")

**Check the CRM answer (one GET)…** (in the Sales page's Unknown card, and in Settings → Integrations → WorkTrack
customers) reads `GET /v1/vendor/crm/accounts` once and keeps only key names, JSON types and counts
(`WTShapeReport`). Expected: `id`, `name`, `stage` a string in every row; `createdAt`, `updatedAt` a string or null in
every row; `companyId`, `city`, `industry`, `source`, `nextActionAt`, `nextAction`, `notes`, `createdBy`, `updatedBy` a
string, null or absent (the console saves a cleared field as null, `web/src/pages/vendor/AccountDetail.tsx:72-83`);
`employeesEstimate` a number, null or absent. Differences are listed in red, with stages WorkTrack does not define,
next-action dates that are not a real day, unexpected key names, and whether the 2000 limit was reached.

### Shape

To be filled from the owner's one check on production (counts only, no values):

| Read on | Rows | Differences | Unknown stages | Dates not a real day | Unexpected keys | 2000 limit |
|---|---|---|---|---|---|---|
| | | | | | | |

## Owner steps

1. Sign in to WorkTrack once on each device that should show Sales (the vendor session from Phase 4 is the same).
2. In `console.linumic.com`, register each tailoring workshop as an account: stage LEAD (the default), «اقدام بعدی»
   and **its date** (today, or the day to call).
3. In Linumic OS, open **Sales** and press **Read now**. The LEAD is under **Call today** and on the Desk in Today,
   WorkTrack. Without a date it is under **No next step** and in the Desk item "N open CRM accounts have no next-action
   date". This is the done criterion "on the Desk the same day".
4. Press **Check the CRM answer (one GET)…** once on production and record the counts in the Shape table above (or send
   them, without values, to an agent). This is the one step agents never run against production.
5. Proof that no CRM data is in Supabase (Phase 3's tables are live since 2026-10-20). In the Supabase SQL editor this
   read-only query must return `0 | 0`; it checks the ids and the dismiss reasons of every Sales mark, now and in their
   history:

   ```sql
   select
     (select count(*) from public.desk_state
       where id like 'brief.sales|%'
         and (id !~ '^brief\.sales\|(section|part\.[A-Za-z0-9._-]+|sales\.(followup|signup)\.[0-9a-f]{16}|sales\.(nodate|nocrm))\|[A-Za-z0-9._-]+$'
              or coalesce(reason, '') !~ '^(sales\.reason\.(called|console|notToCall|test|other))?$')) as rows_not_clean,
     (select count(*) from public.audit_events
       where table_name = 'desk_state'
         and coalesce(new_row->>'id', old_row->>'id') like 'brief.sales|%'
         and (coalesce(new_row->>'id', old_row->>'id') !~ '^brief\.sales\|(section|part\.[A-Za-z0-9._-]+|sales\.(followup|signup)\.[0-9a-f]{16}|sales\.(nodate|nocrm))\|[A-Za-z0-9._-]+$'
              or coalesce(new_row->>'reason', '') !~ '^(sales\.reason\.(called|console|notToCall|test|other))?$'
              or coalesce(old_row->>'reason', '') !~ '^(sales\.reason\.(called|console|notToCall|test|other))?$')) as history_not_clean;
   ```

   It was checked on a throwaway local Postgres with every migration: `0 | 0` after clean Sales marks, `1 | 1` after a
   typed reason, `2 | 2` after an id in clear. `desk_items` never holds Daily Brief lines.

## Owner questions (each with the default this change ships)

| # | Question | Default |
|---|---|---|
| Q1 | Customer names in the morning notification for Sales lines? | No: counts only |
| Q2 | Reach the Desk faster than the 6-hour job (a lighter hourly accounts read)? | No new read: launch, Read now, and the 6-hour job |
| Q3 | Should the server refuse a `brief.sales` id that is not hashed, or a Sales reason that is not a preset? | No migration in Phase 5; ids are hashed and reasons fixed in Core and proven by tests. The proposal is below |
| Q4 | Show the console's next-action note in the Desk detail too? | Yes, on this device only |
| Q5 | A `tel:` call link beside a number? | No: **Copy number** only |
| Q6 | How long a copied draft or number stays on the clipboard? | 2 minutes |
| Q7 | Who is a "new signup"? | Created in the last 14 Kabul days (day 14 included, day 15 not), or bought a plan itself, with no CRM account; a support-ticket WON account on a trial does not count; scheduled deletions left out |
| Q8 | List WON, LOST and DORMANT accounts that have a due date? | Yes, as WorkTrack's own dashboard does, with the stage pill |
| Q9 | Are the Dari and Pashto drafts right? | Shipped as written in `SalesDraft.swift`; changes are text-only |
| Q10 | Leave out DUPLICATE companies' follow-ups like TEST ones? | Yes (`flags != nil`) |
| Q11 | Sign drafts «لینومیک» or with your name? | «لینومیک» only |
| Q12 | Where does Sales sit in the sidebar? | Right after Money, no ⌘ shortcut (all nine are taken) |
| Q13 | The five fixed dismiss reasons for Sales items? | As listed above |
| Q14 | A follow-up whose company is missing from the list (maybe a purged TEST company)? | Listed with the caveat and on the Desk by its day, but not counted in the morning notification |

Proposal for Q3 (not applied; a migration needs the owner's approval):

```sql
alter table public.desk_state add constraint desk_state_sales_ids check (
  id !~ '^brief\.sales\|'
  or (id ~ '^brief\.sales\|(section|part\.[A-Za-z0-9._-]+|sales\.(followup|signup)\.[0-9a-f]{16}|sales\.(nodate|nocrm))\|[A-Za-z0-9._-]+$'
      and (reason is null or reason ~ '^sales\.reason\.(called|console|notToCall|test|other)$')));
```

`brief.sales` is deliberately **not** in `DeskCloudKey.hashedOrigins`: its subjects are already hashes, and adding it later
would change the cloud ids of marks already synced.

## WorkTrack follow-ups (found by Phase 5, not fixed here)

Text for the agent to add under `## P1` of `~/Projects/Multiplatform/WorkTrack/PRIORITIES.md` (the Desk takes a leading
`**title**:` as the item's title, `Desk/LedgerParser.swift`), with a dated line in the shared
`~/Projects/Multiplatform/PRIORITIES.md`. This change does not edit the WorkTrack repository or either ledger.

```markdown
- [ ] **CRM: PUT ناقص مرحله را LEAD می‌کند**: (۲۰۲۶-۱۰-۲۰، از فاز ۵ Linumic OS) `PUT /v1/vendor/crm/{entity}/:id` بدنه را با schema کامل ساخت می‌خواند (backend/functions/src/routes/vendor.ts:369)، پس `stage: z.enum(...).default("LEAD")` (backend/functions/src/services/crm.ts:38) برای stage جاافتاده "LEAD" می‌گذارد و `update()` آن را با `set({...data}, {merge: true})` روی مرحلهٔ ذخیره‌شده می‌نویسد (crm.ts:178). همین برای هر فیلد پیش‌فرض‌دار هست: contact.primary→false (crm.ts:64)، activity.kind→NOTE (:74)، deal.status→DRAFT و plan→STANDARD و term→YEARLY (:86-92)، invoice.status→DRAFT (:105)، ticket.status→OPEN و priority→NORMAL (:124-125). کنسول امروز همیشه فرم کامل را می‌فرستد (web/src/pages/vendor/AccountDetail.tsx:72-83) و تست‌ها فقط با stage، PUT می‌کنند (backend/functions/src/routes/crm.integration.test.ts:106-110، :220)، پس هنوز دیده نشده. اصلاح پیشنهادی: برای PUT یک schema بدون default (همان فیلدها با `.optional()` و بدون `.default`) و یک تست integration که PUT بدون stage مرحله را نگه دارد؛ و یک پیش‌شرط `updatedAt` (شرط نقشهٔ راه Linumic OS برای هر نوشتن از آن‌جا).
- [ ] **CRM: plan در deal با planهای واقعی یکی نیست**: (۲۰۲۶-۱۰-۲۰، از فاز ۵ Linumic OS) `dealWriteSchema.plan` فقط `FREE|STANDARD|ENTERPRISE` می‌پذیرد (backend/functions/src/services/crm.ts:87)، ولی planهای واقعی `TRIAL|BRONZE|SILVER|GOLD` است (backend/functions/src/services/plans.ts:36-38) و نام‌های قدیمی فقط هنگام خواندن نگاشت می‌شوند (plans.ts:128-142). نتیجه: deal با `SILVER` با 422 رد می‌شود؛ `FREE` برای Bronze پولی ذخیره می‌شود؛ نوع کنسول `Deal.plan: License["plan"]` غلط است (web/src/pages/vendor/types.ts:242) در حالی که فرم نام‌های قدیمی را می‌فرستد (web/src/pages/vendor/AccountDetail.tsx:565، :579)؛ و `term: ONE_OFF` (crm.ts:92) در کاتالوگ قیمت ندارد (plans.ts:113-117). اصلاح پیشنهادی: plan در deal را `planIdSchema` کنید (plans.ts:121)، dealهای قدیمی را یک بار با `normalizePlan` (plans.ts:134-142) migrate کنید، و نوع کنسول را درست کنید.
```

In short: (1) an incomplete PUT resets the stage to LEAD (`crm.ts:38, 178`): Linumic OS never writes, so it cannot cause
this, but any future tool or script that sends a partial PUT would turn accounts back into leads, and Sales would then
list them under "No next step"; (2) deal plans don't match the real plans (`crm.ts:87`). Also noted, not a follow-up of its
own: `DELETE /crm/accounts/:id` answers 204 and writes an audit entry even for an account that does not exist
(`routes/vendor.ts:378-391`).

## Risks and limits

- "The same day" depends on the app being open (launch, Read now, every 6 hours); on iPhone the WorkTrack job runs in the
  foreground only.
- The 2000-account cap drops the newest accounts first and is detected only as `rows + skipped >= 2000`.
- A next-action note may hold a phone number or a name: it is shown on this device only.
- A date that is not a real day is listed by WorkTrack's console Today tab but as "date could not be read" here.
- The Solar Hijri month names of the drafts come from the system's ICU data (checked on macOS 27); another system could
  name them differently.
- Drafts are as old as the last reading; the sheet shows the read time and counts the days again from Kabul's today.

## Tests

`SalesTests` (30 tests), `SalesDraftTests` (6) and `SalesReadOnlyTests` (5) run with every `swift test` and in the
Persian-calendar run; `MoneyTests.crmAccountsDecodeOnlyTheLink` now expects the stage and the next step as well. They
cover the widened decode (no `notes`, `city` or `createdBy` held; a bad value never sets a row aside), Kabul's day and the
server's rule for every day of two months, the Desk list in four device time zones, TEST, DUPLICATE, missing companies
and the limits, signups on days 14 and 15, scheduled deletions and support-ticket accounts, one Desk item per cause, the
notification with mixed Sales lines, mark pruning, facts, hashed ids against Phase 3's server check and the proposed one,
the agent brief, fixed dismiss reasons and what is sent to the cloud, the shape report with the console's nulls, the KYC
count, and every draft kind in both languages (including SUSPENDED, EXPIRED with a later day, and a stale server count).

The read-only proof (`SalesReadOnlyTests`) runs the real client over a URLSession whose only protocol records every request,
against the emulator address: every WorkTrack request is a GET without a body to exactly revenue, CRM accounts, CRM
invoices and CRM contacts; the contacts request carries exactly `accountId=<the account>`; no other request has a query;
the only other request is the Firebase token refresh; an empty account id makes no request at all. Negative controls show
it catches a POST, PUT, PATCH or DELETE, contacts without an account, the dashboard route and a production host, and a
real `putLicense` through the guard. A source scan checks that the client's only non-GET is the licence PUT and that
`WorkTrackSalesReading` has two reads. The App methods (`WorkTrackModel.contacts(forAccount:)`, `checkCRMShape()`) call
exactly these and are not run under the guard. The opt-in `WorkTrackEmulatorTests.liveEmulatorSalesCallToday`
(`LCC_WT_EMULATOR=1`) seeds one LEAD due today and its contact through the Firestore emulator on 127.0.0.1:8080 and reads
them with GETs only. No test contacts a production host.

## برای صاحب پروژه (دری)

- **فروش چه نشان می‌دهد:** «امروز با چه کسی تماس بگیرم»: پیگیری‌هایی که تاریخ اقدام بعدی‌شان به روز کابل رسیده، پیگیری‌های این
  هفته، حساب‌های باز بدون تاریخ، ثبت‌نام‌های تازه یا خودخرید بدون حساب CRM، تمدیدها، پیام‌های سایت و شمار ارائه‌دهندگان منتظر
  تأیید هویت در SafeBeauty.
- **فقط خواندنی:** Linumic OS هرگز در CRM نمی‌نویسد. «انجام شد» در میز کار CRM را عوض نمی‌کند؛ تاریخ یا مرحله را در کنسول
  WorkTrack تغییر دهید.
- **چیزی بیرون نمی‌رود:** نام مشتری در اعلان صبح، در متن کپی‌شده برای agent و در Supabase نمی‌آید؛ شناسه‌ها hash می‌شوند و
  دلیل کنار گذاشتن موارد فروش از یک فهرست ثابت انتخاب می‌شود، نه تایپ.
- **پیش‌نویس یادآوری** به دری یا پشتو فقط آنچه خوانده شده را می‌گوید و فقط کپی می‌شود؛ پس از ۲ دقیقه از کلیپ‌بورد پاک می‌شود.
- **کار شما:** کارگاه‌های خیاطی را در console.linumic.com با مرحلهٔ LEAD و تاریخ اقدام بعدی ثبت کنید؛ در Linumic OS «اکنون
  بخوان» را بزنید؛ یک بار «بررسی شکل پاسخ CRM» را روی production بزنید و شمارها را ثبت کنید؛ و query بالا را در Supabase
  اجرا کنید تا `0 | 0` بدهد.
