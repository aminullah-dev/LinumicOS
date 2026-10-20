# Legal & company (حقوقی و شرکت)

Module 7 of [company-os-roadmap.md](company-os-roadmap.md), Phase 6. Read-only. One screen (sidebar after Sales), a Daily
Brief section and its Desk items, and an automation job on the Mac. Code: `LinumicCore/Legal` (`LegalMarkers`,
`LegalFolder`, `LegalAccess`, `CompanyStatus`, `LegalBrief`), App: `LegalModel`, `LegalViews`.

## What it shows

1. **The company card** (Mac, iPhone and iPad), each fact with its source and the day it was recorded or read:
   - **Registration:** not registered; the apps are sold under the owner's individual developer accounts.
     `CompanyStatusSeed.registration` cites the roadmap (§2 module 7, §6 decision 2, recorded 2026-10-19), the memory
     note on the Apple team (Individual) and the Google Play account (personal), and the seed accounts in
     `ObligationSeed` (holder: personal). It changes only in code, with a new source, when the company is registered.
   - **The seller per store:** the `seller` of every store listing in the inventory, as written there. For the App
     Store it is set by the public lookup the Store listings job already runs (`AppStoreLookupClient`, `sellerName`),
     so it is shown with that lookup's read time. For Google Play the app never reads a seller: the value was recorded
     from the Play Console when the inventory was seeded, so it is shown as recorded, with the day of the listing's
     first Google Play source. A store with no listing that names a seller is **Unknown**, never empty.
   - **EU DSA trader status:** **Unknown**. No source records the status declared in App Store Connect or the Play
     Console, and the app reads neither for it. It stays Unknown until a source is recorded in `CompanyStatusSeed`.
2. **Markers in the legal drafts** (Mac): how many `[TO FILL]` (a value to fill in), `[LAWYER]` (a question for the
   lawyer) and `[TO DECIDE]` (a decision of the owner's) the text files in `~/Documents/Linumic-Legal` hold, and the
   file and line of each. Exact, or "at least" when a file could not be read.
3. **Asasnama files** (Mac): the name, folder and modification date of every file whose name says Asasnama
   (`asasnama`, `asasnameh` or «اساسنامه», any case), in the legal folder and in any folder the owner adds for them.
   Whether there is a partner is the owner's decision (roadmap §6, decision 1); the app only shows that the files exist.

## What is read, and what never is

| Read | Never |
|---|---|
| The names in `~/Documents/Linumic-Legal` and its folders (4 levels, at most 500 entries; hidden names skipped) | Anything outside the granted folders |
| The text of `.md`, `.markdown` and `.txt` files there (UTF-8, at most 1 MB each), to find the markers | The text itself: no sentence, word or value around a marker is kept, shown, logged or sent. Only the kind and the line number of each marker leave the reader (`LegalMarkerHit`) |
| Of an Asasnama file: its name and modification date (`lstat`) | Its content: an Asasnama file is never opened, whatever its extension (a `.md` named Asasnama is not scanned) |
| Of any other file (`.docx`, `.pdf`, …): its name, to say its markers are unknown | Its content |
| | A symbolic link (never followed), a hard link (refused), a file over 1 MB (refused) |

Nothing is written to the drafts or anywhere else. Nothing about the drafts is saved on disk: the reading is in memory
and is read again by the job. The grants themselves are the only thing kept (UserDefaults, below).

**The Desk and the cloud.** The Brief lines carry counts only ("27 [TO FILL] markers to fill in the legal drafts"),
with the product the first folder names (`WorkTrack/…` → WorkTrack). The detail lists `file: line, line` relative to
the legal folder, so "Copy agent brief" can point an agent at the place; no text. A line's id is
`legal.markers.<kind>.<hash of the folder>`, never a file or folder name (a folder could be named after a customer), so
what Desk sync sends of a mark (`desk_state`: id, kind, time, fact hash, reason) carries no name either. Asasnama
names and dates appear only on this screen; the Desk says how many there are.

## The rule, and the same count with grep

A marker is `[`, one of the three words in upper case, then `]`, `:`, a space or any other character that is not an
ASCII letter or digit, or the end of the line. So `[TO FILL]`, `[TO FILL: date]` and `[LAWYER — tax]` count;
`[TO FILLED]`, `[lawyer]` and `[TO_FILL]` do not. Every occurrence counts, several on one line too; a line that
explains what the markers mean counts like any other. Lines are split at `\n`, as grep splits them.

The same count, for checking by hand (the screen prints the pattern too):

```sh
grep -rnoE --include='*.md' --include='*.markdown' --include='*.txt' --exclude='.*' --exclude-dir='.*' \
  --exclude='*[Aa]sasnama*' '\[(TO FILL|LAWYER|TO DECIDE)([^A-Za-z0-9]|$)' ~/Documents/Linumic-Legal | grep -c '\[TO FILL'
```

(`\[LAWYER` and `\[TO DECIDE` for the other two.) A test (`LegalReaderTests.theCountsEqualGrepOnTheSameFolder`)
copies a made-up fixture folder to a temporary home, reads it with the app's reader and runs this grep on it; the
counts must be equal.

**On the real folder (2026-10-20, read-only):** the app's reader and the grep above both give **27 [TO FILL], 11
[LAWYER], 2 [TO DECIDE]**, in one product folder, every file read. The roadmap's "18, 8 and 1" do not come from one
rule: 18 and 8 are the number of lines holding `[TO FILL` and `[LAWYER` in one of the files, and 1 is the `[TO DECIDE]`
lines of that file without its legend line. The roadmap's status line now records this.

## Access: the sandbox check first, then a one-time grant

The app is sandboxed (project.yml). On 2026-10-20 a probe signed with the app's own file entitlements
(`app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, the read-only exception for
`/Projects/Multiplatform/`) showed, inside the sandbox:

| Path | `lstat` (metadata) | list or open |
|---|---|---|
| `~/Documents/Linumic-Legal`, `~/Documents` | allowed | refused (Operation not permitted) |
| `~/Desktop/1`, `~/Desktop` | allowed | refused (Operation not permitted) |
| `~/Projects/Multiplatform` | allowed | allowed (its exception) |

So no new entitlement is added. At every read the app first tries to list the legal folder without a grant
(`LegalAccessRules.probe`, shown on the screen as "Sandbox check"); when that is refused, it uses the folder the owner
granted once in a folder picker, kept as a **read-only security-scoped bookmark** (`.securityScopeAllowOnlyReadAccess`)
under its own UserDefaults key, the pattern of Keys & Backups:

| Key | What it may hold | What the app does inside |
|---|---|---|
| `LCCLegalBookmarks` | exactly `~/Documents/Linumic-Legal` (anything else, `~/Documents` or the home folder included, is refused before a bookmark is made) | the reading above |
| `LCCAsasnamaBookmarks` | folders inside the home folder, not the home folder or one above it, not the legal folder | names and dates of Asasnama files, the folder and the folders directly in it; never the legal folder's text, even when it covers it (`~/Documents`) |

They are separate from `LCCKeysBookmarks` (whose grant promises no file is ever opened) and `LCCLedgerBookmarks`
(ledgers only). "Remove access" forgets both legal keys. The grants are read-only, but while the open panel is showing
and until the app quits, the folder picked carries the read-write access of the existing
`files.user-selected.read-write` entitlement; nothing writes there.

**A stored grant can fail. Each state is shown, and none is read as "no markers"** (`LegalAccessRules`, tested in
`LegalAccessTests`):

| State | When | What happens |
|---|---|---|
| Readable without a grant | the sandbox check passes (not sandboxed, or an exception covers it) | read without a bookmark |
| Not granted | no grant, and the sandbox refuses the folder | Desk item: "~/Documents/Linumic-Legal is not granted, so the markers are unknown here, not zero" |
| Granted | the bookmark resolves to the folder and its scope starts | read |
| Could not be resolved | resolving the bookmark throws | kept, tried again at the next read; Desk item |
| Refused by macOS | the bookmark resolves but its scope does not start, or the folder can't be read through it | Desk item with the reason; grant again |
| Moved | the bookmark now leads to another folder (moved or renamed) | the grant is dropped (it would say "granted" for a grant that reads nothing); grant again |
| Not found | the folder is not there | Desk item |
| (stale) | the bookmark is stale | remade and stored; if it can't be remade, the old one is kept |

## Daily Brief, Desk and the job

- **Brief section** "Legal & company" (after Keys & Backups): the registration line (information, so Later on the
  Desk), one line per marker kind and product folder (normal: Today for WorkTrack, the focus product), the Asasnama
  line (normal), and as gaps (each a Desk item, "unknown here, not zero"): the folder not read (with the state's
  reason), files not read (a caveat: the counts are "at least"), no Asasnama file in the folders read, a store with no
  seller, and the DSA status. On iPhone and iPad the folder is a note, not a Desk item.
- A Desk mark on a marker or Asasnama line is dropped only after a reading in which the folder was read and the line is
  gone (`LegalBrief.readGapKeys`); a failed read never drops it.
- **Job** `legal` ("Legal folder"): every hour, no network, Mac only, before the ledgers and the Brief. Skipped while the
  folder is not granted; partial when a file could not be read.

## Owner steps

1. Legal & company → Access → **Grant…**, choose `~/Documents/Linumic-Legal` (once).
2. **Add folder…** for the folders that hold the Asasnama drafts (on 2026-10-20 they were not in the legal folder but
   in `~/Desktop/1` and `~/Documents/Business-Docs`), if they should be listed.
3. Answer the partner question (roadmap §6, decision 1); fill the markers or move them to the lawyer. The counts follow.

## Not verified

- The grant flow, the screen and the Desk items were built and compiled for macOS and the iOS Simulator, and the logic
  is tested with fixtures; the app was not launched by the agent that built it, so the picker and the Powerbox grant
  on this Mac are untested.
- Whether macOS asks a Files and Folders (TCC) question for a folder the owner picks in the open panel: by Apple's rules
  a Powerbox choice is the consent, and the probe shows the sandbox, not TCC, refuses the folder without one.
