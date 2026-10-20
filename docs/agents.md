# Agents (ایجنت‌ها)

Phase 7 of [the company OS roadmap](company-os-roadmap.md). Since 2026-10-20 the owner has 20 scheduled cloud agents,
one per product platform (plus one for security and dependencies). Each runs every two days, opens **pull requests
only** — titled `[agent:<slug>] …`, on a branch `agent/<slug>/<date>-<topic>` — and never merges, deploys or touches
keys; the coordinator reviews and the owner merges. This page shows what each agent did, and the Desk says when one has
gone quiet.

Read from **GitHub only**, with the existing client and token, GET only. Nothing here calls the service that runs the
agents (no claude.ai or Anthropic API), and no routine id is kept. Code: `Packages/LinumicCore/Sources/LinumicCore/Agents/`,
`App/Views/AgentsViews.swift`; the reads are in `Products/ProductsReads.swift`.

## The registry

`Packages/LinumicCore/Sources/LinumicCore/Resources/agents.json`, bundled with the app. Per agent: number (as the
routines are named, "Agent 01"), slug, area, products, platforms (`Platform` raw values), repositories, cadence
("every 2 days"), the routine's cron and its UTC time, and whether it runs on odd or even days of the month. Recorded
from the routines as created on 2026-10-20 between 05:01 and 05:13 UTC; `createdAt` (05:13) is when they all existed.
No routine id, environment, prompt, address or token is in the file (a test checks), since this repository is public.

| # | Slug | Area | Repositories | UTC |
|---|---|---|---|---|
| 01 | worktrack-backend | WorkTrack backend | WorkTrack | 01:07 odd days |
| 02 | worktrack-web | WorkTrack web and desktop | WorkTrack | 03:19 odd |
| 03 | worktrack-android | WorkTrack Android | WorkTrack | 05:41 odd |
| 04 | worktrack-ios | WorkTrack iOS | WorkTrack | 07:53 odd |
| 05 | safebeauty-server | SafeBeauty server | stealth-service-vault- | 10:11 odd |
| 06 | safebeauty-android | SafeBeauty Android | stealth-service-vault- | 12:23 odd |
| 07 | safebeauty-ios | SafeBeauty iOS | stealth-service-vault- | 14:37 odd |
| 08 | velro-backend | VELRO backend and admin | velro | 16:49 odd |
| 09 | velro-rider | VELRO passenger apps | velro | 19:13 odd |
| 10 | velro-driver | VELRO driver apps | velro | 21:27 odd |
| 11 | khayatyar-desktop | KhayatYar desktop (Mac and Windows) | AfghanJama | 01:07 even |
| 12 | khayatyar-android | KhayatYar Android | AfghanJama | 03:19 even |
| 13 | khayatyar-ios | KhayatYar iOS | AfghanJama | 05:41 even |
| 14 | talar-web | Talar web and backend | talar | 07:53 even |
| 15 | talar-android | Talar Android | talar | 10:11 even |
| 16 | linumic-os | Linumic OS | LinumicOS | 12:23 even |
| 17 | dukanpro | DukanPro | DukanPro | 14:37 even |
| 18 | mediflow | MediFlow | MediFlow | 16:49 even |
| 19 | nerkhtimes-namazia | NerkhTimes and Namazia | NerkhTimes, -Namazia | 19:13 even |
| 20 | security | Security and dependencies | WorkTrack, stealth-service-vault-, talar, velro, AfghanJama | 21:27 even |

Odd days are the cron's `*/2` (1st, 3rd, …, so the 31st and the 1st in a row); even days are `2-30/2` (from the 30th
to the 2nd is three days). `AgentRegistry.problems` refuses a duplicate slug or number, a slug that is not lower-case
words with dashes, a UTC time that is not the cron's, or another day pattern. **Changing an agent:** edit the routine,
then the same row here, in a pull request; the tests read the file.

## Which pull request is whose

`AgentMatcher`: a title that starts with `[agent:<slug>]`, else a head branch that starts with `agent/<slug>/` followed
by a topic, for a slug in the registry (case and leading spaces ignored). `[agent:talar]` is nobody's (there is no
`talar` agent, only `talar-web` and `talar-android`), and neither is a branch `agent/talar-web` with no topic.

## What is read

For each of the 10 registry repositories, one page: `GET /repos/{r}/pulls?state=all&sort=created&direction=desc&per_page=50`
(open, merged and closed, newest first). Only the agents' pull requests are kept (number, title, branch, state, draft,
link, created, updated, closed and merged times), with how many the page held and how far back it reached. A repository
that fails keeps its previous page with the error; one that was never read stays unread. The same job and file as the
Products page ([docs/products.md](products.md)): `products-agents.json`, every 30 minutes, GitHub token required.

## The page

Per agent: its number and slug, its area, products and platforms, "Every 2 days at HH:MM UTC (odd or even days)", its
repositories (links to their pull requests), its last activity, its open pull requests and its last three merged or
closed ones, with links. Status pills: **Waiting for review: N** (open, not a draft), **No pull request for N days**,
**Active**, **No pull request yet** (created less than 4 days ago), **Unknown** (with why). Filters: All, Waiting for
review, Quiet, Unknown. The header counts agents, pull requests waiting for review and quiet agents, with the read time,
and names any repository not read or whose last read failed.

## "No pull request for more than 4 days"

The cadence is two days and a month can put three days between two runs, so more than `quietAfterDays` (4) days without
a new pull request is a **Desk item**. Counted from the agent's newest pull request (its creation), or, with none, from
when the agents were created, **to the time of the reading** (a pull request may have been opened since) — and only as
far back as the pages reach: if a busy repository's page of 50 starts later than that and holds none of the agent's,
"no pull request since then" is said only when that alone is more than four days; otherwise it is Unknown with why. A
repository not read makes the agent's state Unknown. An agent may rightly open nothing when nothing safe is left in its
area; the item is there for the owner to look.

## Daily Brief, Desk and Command Palette

- **Brief section "Agents"** (after Products): "Agent 16 (linumic-os): pull requests waiting for review: 1" (the pull
  requests in the detail) and "Agent 13 (khayatyar-ios): no pull request for 5 days" (the last one, or since when, and
  its UTC time in the detail). Both are filed under the agent's product (all products for nerkhtimes-namazia and
  security), so they are **Desk items**; a waiting line's fact is its pull requests, a quiet line's the day it went
  quiet. A repository not read, or a quiet state that can't be known, is a gap: an item of its own, never zero. Line ids
  carry the slug only.
- **Command Palette:** "Agent pull requests waiting for review: N" (opens the page filtered), each agent ("Agent 01 ·
  worktrack-backend"), each open agent pull request (opens it on GitHub), "Read products and agents now".
