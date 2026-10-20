# Money (پول)

Phase 4 of [company-os-roadmap.md](company-os-roadmap.md), module 5: who paid, what money is on the way, what we owe
salons, and what we pay. Read-only. It reuses the WorkTrack and SafeBeauty sessions the app already has and adds no
key. Amounts stay in their own currency: nothing is converted, nothing is added across currencies, nothing is summed
across billing cycles. A figure that was not read is **Unknown** with its reason, and that reason is a Desk item; it is
never shown as 0.

Code: `LinumicCore/Money` (`MoneyAmount`, `MoneyFigure`, `MoneyInput`, `MoneyBuilder`, `MoneyBrief`), the CRM and
aggregation reads in `LinumicCore/Integrations` (`WorkTrackVendor.swift`, `FirestoreREST.swift`, `SafeBeautyAdmin.swift`),
`App/MoneyCollect.swift` and `App/Views/MoneyViews.swift`. Tests: `MoneyTests.swift`, `MoneyReadOnlyTests.swift`.

## The figures

Ten figures, each with its source, environment and read time. Sources were read at WorkTrack `origin/main` 0403fd0
(the vendor routes and services are unchanged since f2a9d2c, which the client was built against) and SafeBeauty
`origin/main` 3688474. Paths under WorkTrack are relative to `backend/functions/src/`.

| Question | Figure | Source | Currency |
|---|---|---|---|
| Received | HesabPay payments | `GET /v1/vendor/revenue` → `earned` (`routes/vendor.ts:208-213`, `services/vendorInsights.ts:370-388, 394-484`): only orders HesabPay marked PAID | the response's `currency`, the literal `"AFN"` |
| Received | Invoices paid by hand | `GET /v1/vendor/crm/invoices`, status `PAID` (`routes/vendor.ts:308-345`, `services/crm.ts:99-114, 198-206`) | AFN (`amountAfn`, `crm.ts:106`) |
| On the way | Expected renewals (forecast) | `/v1/vendor/revenue` → `expected` (`vendorInsights.ts:437-461`): renewals in the next 30 days at today's prices | AFN |
| On the way | Invoices sent, not paid | CRM invoices, status `SENT` (the same rule as WorkTrack's dashboard, `crm.ts:274-276`) | AFN |
| On the way | Invoices past due | the SENT invoices whose `dueAt` is before today **in Kabul** (as the console, `web/src/pages/vendor/Revenue.tsx:218`) | AFN |
| Owed to salons | Salons the platform owes | Firestore `provider_balances`, `count()` and `sum(owedAmount)` where `owedAmount > 0` | whole AFN (`functions/lib/money.js:7`) |
| Owed to salons | Salons that owe the platform | the same where `owedAmount < 0`, shown as a positive size | whole AFN |
| What we pay | Account costs | `obligations.json`: each account's cost as recorded from its bill (`AccountCost`) | each cost's own ISO code |
| Store proceeds | App Store, Google Play | none: always Unknown | |

HesabPay, CRM invoices and the forecast are three different things and are **never added together**: one payment can
be both a HesabPay order and a hand-typed invoice, and a forecast is not money. WorkTrack's own console keeps them apart
for the same reason (`Revenue.tsx:8-15`). Salons owed and salons owing are different salons and are **never netted**.
Costs are shown per currency and per billing cycle ("99 USD per year · 25 USD once"), never as one total and never
turned into a yearly figure.

Not figures in v1 (each is a note on the page): pending HesabPay checkouts (no route lists them across companies);
who paid each HesabPay order (on the company's page in WorkTrack customers); licences in their 7 grace days (WorkTrack's
forecast drops them; Money shows how many, never an amount); SafeBeauty commission income, VELRO and Talar finance
(not roadmap sources).

## Two changes from the roadmap's source list

The roadmap names `/vendor/revenue`, `/vendor/crm/invoices` and `payoutsOwed()` (module 5). Money reads:

1. **`GET /vendor/crm/accounts` as well.** An invoice carries only an `accountId`; the account carries the `companyId`
   that says which WorkTrack company it is (`crm.ts:39-40`), and only the company says whether it is marked TEST or
   DUPLICATE. Without the accounts, test invoices could not be left out.
2. **A Firestore `sum(owedAmount)` aggregation instead of `payoutsOwed()`.** `payoutsOwed()` lists one page of at most
   300 balances and drops negative ones, and the Firestore client never follows `nextPageToken`, so its total could be
   silently short. Two aggregation queries count and sum every balance, read no documents and have no page limit.

## TEST and DUPLICATE companies

- **HesabPay and renewals:** WorkTrack leaves out every company with a mark (`flags != null`,
  `vendorInsights.ts:400, 439`) and reports what it left out; the page shows it.
- **CRM invoices:** here, through account → company → `flags`, with the server's own rule (any mark). An account with
  no `companyId` (a prospect, a customer handled by hand) is counted, with a note. What was left out is two notes,
  the paid invoices and the sent ones, each with its own total: received and on the way are never one sum.
- **When the marks are not known, invoices are Unknown, never counted unfiltered:** the company list was not read
  (or its last read failed), or the CRM accounts were not read. An invoice whose company is not in the company list
  (deleted, purged, or past the list's 500-company limit) is left out, counted, and makes the figure "incomplete".
- **SafeBeauty has no TEST mark** (no test or demo field in its functions or rules), so every salon balance is counted;
  the page says so.
- **Known gap in WorkTrack:** purging a company deletes `companies/{id}` but not its `billingOrders` or CRM records. Its
  PAID orders then count as earned again, because the server builds its marked set only from companies that still
  exist (`vendorInsights.ts:400`, `vendor.ts:497-499`). Money cannot see this (`earned` has no per-company breakdown).
  Until WorkTrack is fixed: **mark test companies TEST, and do not purge one that paid.** The page carries this note.

## The page

Four summary cards (one row of four from about 900 pt wide, two by two below), then a section per question. An Unknown
card shows its reason under the pill. Dates are in the device's calendar (Solar Hijri on the owner's Mac): renewal
expiry, invoice dates, the day a cost was recorded, and Kabul's date in the past-due Desk item; revenue by month is
named in the Solar Hijri calendar whatever the device uses, since WorkTrack counts by it. An invoice shows the one date
that answers its question, labelled: "Paid …", "Due …", or "Issued …, no due date"; a paid invoice without a payment
date shows none. Each figure's source line says "read <time>", or "tried <time>" when the read failed. `MoneyPage`
takes a report and its input, so `MoneyViews.swift` has previews built from made-up figures, with no session.

## Limits WorkTrack does not report

| Limit | Where | What Money says |
|---|---|---|
| 5000 PAID orders | `vendor.ts:498` | HesabPay "at least"; the forecast's terms "incomplete" |
| 500 companies (revenue and the company list) | `vendor.ts:201, 499` | HesabPay "incomplete" (a TEST company past the limit is counted, so it can be wrong either way); renewals "at least" |
| 2000 CRM invoices | `crm.ts:204` | invoice figures "at least" |
| 2000 CRM accounts | `crm.ts:204` | invoice figures "incomplete" (invoices of accounts past the limit are counted unfiltered) |

Reaching any of them is a Desk item (`worktrack.limit`). Below the limits the figures are exact.

## Unknown reasons and Desk items

Every Unknown is one gap of the Money section of the Daily Brief, so one Desk item `brief.money|part.<key>|not-read`:

| Reason | Key | Where it lands |
|---|---|---|
| Not signed in, or signed in and not read yet (WorkTrack, SafeBeauty) | `worktrack`, `safebeauty` | Later (the WorkTrack and Operations sections already raise the sign-in for the focus product) |
| WorkTrack's company list failed | `worktrack` | Later (the WorkTrack section raises it in Today). When SafeBeauty was not read either, the section is "not read yet" (information, Later), not a second "could not be read" |
| Revenue read failed; currency not a code | `worktrack.revenue` | WorkTrack, This week |
| Invoices read failed; company list or CRM accounts not read | `worktrack.invoices` | WorkTrack, This week |
| Balance totals failed (rules, index, network) | `safebeauty.balances` | SafeBeauty |
| obligations.json unreadable; register not available; no cost recorded; some accounts without a cost | `costs` | Later |
| App Store and Google Play proceeds | `stores` (one item) | Later, always |

Caveats that only the owner can fix or accept are items too: `worktrack.test` (no company is marked TEST or
DUPLICATE), `worktrack.limit`, `worktrack.production` / `safebeauty.production` (read from a non-production
environment), and `costs` when some accounts have no cost. They are about a part that was read, so their item says
so ("This part was read; its figures are shown, but may not be complete or exact…") instead of "unknown, not zero".
Their texts carry no times, so "Dismiss with reason" holds until the situation changes. A caveat is gone only when its
own part was read and it was not raised: while WorkTrack is signed out, not read or its revenue read failed (or
SafeBeauty's balances, for `safebeauty.production`), a mark on it is kept (`MoneyBrief.readGapKeys(forPart:)`).

When nothing remote could be read, the section itself is "not read" or "could not be read" (one item for that
reason), and the store proceeds and costs items are still there: the Desk shows gaps of a section in every state.

**Lines** (things waiting on the owner), with counts in the text and amounts only in the detail, so the morning
notification never shows an amount:

| Line id | When | Severity |
|---|---|---|
| `money.safebeauty.owed` | salons are owed a payout | normal in production (Today for SafeBeauty), else information |
| `money.safebeauty.receivable` | salons owe the platform (commission on unpaid cash bookings, or a payout that overshot) | information |
| `money.worktrack.overdue` | invoices past due | normal in production, else information |
| `money.worktrack.unpaid` | invoices sent and not yet due | information |

Line ids are fixed strings: no company, salon, account or invoice id. Each line's fact is its id, severity and the
count's power-of-two bucket. A mark on a line that is gone is dropped once its product's part was read again; while
that part is Unknown the mark is kept. "Copy agent brief" carries a Money line's id, never its amount.

## Reading and automation

No new job. The `.worktrack` job (every 6 hours) reads revenue, the CRM accounts and the CRM invoices right after the
company list, one at a time, so the invoices are filtered with the marks of the same reading. The `.operations` job
(every 30 minutes) runs the two aggregation queries after the SafeBeauty snapshot, in their own `do/catch`. A Money
failure makes either run **partial**, never failed, so renewal reminders keep their schedule. **Read now** on the page
runs the whole WorkTrack refresh and the balance totals. On iPhone both jobs run in the foreground only, and the owner
signs in there separately (sessions are per device).

## What never leaves the device, and what is never sent

- Nothing Money shows is written to disk: no file, no cache. The WorkTrack and SafeBeauty clients use an ephemeral
  session with no URL cache (`URLSessionTransport.uncached`), because the CRM answers carry whole customer records.
- CRM `notes`, `period`, `city` and the other fields cross the wire (the API has no field mask) but are not decoded,
  so they are never held. Since Phase 5 an account's `stage`, `nextActionAt` and `nextAction` are decoded too, for Sales,
  and stay in memory on this device ([sales.md](sales.md)).
- Desk marks on Money items carry ids, kinds, times and hashes only; Money adds nothing to Supabase.
- No key was added: `SecretKey.allCases` is pinned by a test.

## Owner steps

1. Sign in once to WorkTrack (customers screen) and SafeBeauty (Operations) on each device that should show Money,
   with "Fill from Vault".
2. Mark test companies TEST (or a duplicate DUPLICATE) in the WorkTrack console, `console.linumic.com`. Do not purge a
   test company that paid until WorkTrack leaves purged companies' orders out. Linumic OS never writes marks.
3. Record each account's cost from its bill in Obligations & accounts.

## Owner questions (each with the default used)

| Question | Default |
|---|---|
| How often are salons paid; should "salons are owed a payout" sit in Today? | Normal in production (Today); snooze it until payout day. |
| Show HesabPay and CRM "paid by hand" as one total? | Never combined. |
| Which invoice statuses are money on the way? | SENT only, as WorkTrack's dashboard; DRAFT a count only; VOID ignored. |
| Are there unmarked WorkTrack test companies? | The `worktrack.test` item stays until one is marked or it is dismissed with a reason. |
| Test salons with balances in SafeBeauty? | Counted (there is no mark), with a note; no local exclusion list (that would be a second ledger). |
| Read App Store Connect or Play finance reports? | No; Unknown with a reason (roadmap §5: after the first payment). |
| Amounts in the agent brief or the notification? | No: ids and counts only. |
| SafeBeauty commission income, VELRO, Talar finance? | Not in v1. |
| Free accounts? | Stay "no recorded cost"; dismiss the item with a reason. |
| Overdue invoices high after N days? | No threshold in v1. |
| Money on iPhone? | Yes, after signing in there. |
| An amount for licences in grace? | No: count only. |
| Keep Money history on the device? | No. |
| A dedicated Money job? | No (it would pair invoices with marks read at another time). |
| Dari wording | The proposals in the catalog; the owner edits them in review. |
| Fix Talar's per-currency sum (`TalarAdmin.swift:280-282`) here? | No: a follow-up. |
| Ask WorkTrack for server changes? | Recorded as follow-ups below; nothing in WorkTrack is changed. |

## Follow-ups (not in this change)

- **WorkTrack:** leave out the orders of purged companies (or mark orders on purge); expected renewals skip licences in
  their grace days (`vendorInsights.ts:443`); `/revenue` and the CRM lists stop at their limits without saying so
  (`vendor.ts:498-499`, `crm.ts:204`); no route lists pending orders across companies.
- **Talar:** `TalarPayoutSummary.pendingNetMinor` adds `netMinor` across currencies (`TalarAdmin.swift:280-282`) and the
  view labels the sum AFN.
- **Obligations:** no way to record "free" with a source (`AccountCost.checked` needs an amount above 0).

## Tests

`MoneyTests` (42) and `MoneyReadOnlyTests` (3) run with every `swift test` and in the Persian-calendar run. The read-only
proof runs the real clients over a URLSession whose only protocol records every request, against the local emulator
addresses: only vendor GETs (exactly revenue, CRM accounts, CRM invoices), token refreshes and two aggregation POSTs; a
negative control proves it catches a PUT. A source scan keeps every Core request on a transport the guard can see: no
file in `LinumicCore/Sources` but `GitHubClient.swift` (where `URLSessionTransport` lives) makes or calls a URLSession
itself. It covers the Core readers; the App methods that call them
(`WorkTrackModel.refresh`, `SafeBeautyModel.refreshBalances`) are not run under it (see docs/security.md). The opt-in
`WorkTrackEmulatorTests.liveEmulatorMoneyReadsTheCRM` (`LCC_WT_EMULATOR=1`) writes one TEST account and invoice through
the Firestore emulator's REST API on 127.0.0.1:8080 and reads them back through the vendor API. Nothing in the tests
contacts a production host.

## برای صاحب پروژه (دری)

- **پول چه نشان می‌دهد:** درآمد HesabPay در WorkTrack و فاکتورهای پرداخت‌شدهٔ دستی (جدا از هم)؛ تمدیدهای پیش‌بینی‌شده و
  فاکتورهای فرستاده‌شده و پرداخت‌نشده؛ آنچه به سالون‌های SafeBeauty بدهکاریم و، جدا از آن، آنچه سالون‌ها به ما بدهکارند؛
  و هزینهٔ حساب‌ها، همان‌طور که در «تعهدات و حساب‌ها» از صورت‌حساب ثبت کرده‌اید.
- **قاعده‌ها:** هر رقم منبع و زمان خواندن دارد. ارزها هرگز تبدیل یا با هم جمع نمی‌شوند و دوره‌های پرداخت (ماهانه، سالانه،
  یک بار) هم با هم جمع نمی‌شوند. چیزی که خوانده نشده «نامعلوم» است و یک کار در «میز کار» می‌شود، نه صفر. عواید App Store
  و Google Play همیشه نامعلوم می‌ماند.
- **چیزی ذخیره یا فرستاده نمی‌شود:** هیچ رقمی روی دیسک یا در Supabase نمی‌رود و کلید تازه‌ای اضافه نشده. یک تست ثابت
  می‌کند که فقط درخواست خواندنی فرستاده می‌شود.
- **کار شما:** در هر دستگاه یک بار با Vault fill به WorkTrack و SafeBeauty وارد شوید؛ شرکت‌های آزمایشی را در
  console.linumic.com با TEST علامت بزنید، و **شرکت آزمایشی‌ای را که پرداخته پاک نکنید** (WorkTrack پس از پاک شدن،
  سفارش‌هایش را دوباره درآمد حساب می‌کند)؛ هزینهٔ هر حساب را از صورت‌حسابش ثبت کنید.
