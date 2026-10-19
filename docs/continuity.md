# Continuity (تداوم): the encrypted export

Module 4 of [company-os-roadmap.md](company-os-roadmap.md), Phase 2. One encrypted copy of the company's records in a
folder the owner chooses, off this Mac (a USB stick, or a Google Drive for desktop folder), in a documented format that
opens **without Linumic OS**. Local only: no network, nothing uploaded by the app.

## Making one (Mac)

Sidebar → **Continuity** («تداوم»):

1. **Folder.** Choose it once (a read-write bookmark, `LCCContinuityFolder`). The screen says where it is: an external
   drive, a cloud folder (Google Drive for desktop, iCloud Drive), a network volume, **this Mac's own disk**, or a place
   the system does not report. Only the first three are off this Mac, and the app makes an export only there: a copy on
   this Mac's own disk, or somewhere it can't place, would look like the copy that is still missing.
2. **Passphrase**, typed twice, at least 16 characters, **Latin letters, digits, spaces and punctuation only** (printable
   ASCII). age uses the passphrase's bytes as typed, with no normalisation, and a Dari passphrase can hold letters that
   look the same on paper but are different characters on another keyboard (ي and ی, ك and ک, the half-space): typed
   elsewhere, it would not open the file. It is typed for each export and **never stored**: not in a file, not in the
   Keychain, not in the log. "Suggest a passphrase" shows six groups of four letters and digits that can't be mistaken
   for one another (about 119 bits) once; write it on paper and keep the paper apart from the folder.
3. **Export and verify.** The app builds the document, refuses to write if it finds a key or token pattern in it,
   encrypts it, writes `linumic-os-continuity-YYYY-MM-DD-HHmm.json.age` (never over an existing file), then **reads the
   file back from the folder**, checks it is the file it wrote (SHA-256), decrypts it with the passphrase, checks the
   result is the document it encrypted (SHA-256) and that it still decodes. Only then is the export recorded. A file
   that fails any step is removed, a write that stops halfway (a full or pulled USB stick, a cloud folder's error)
   included; a file of the same name that appeared in the meantime is someone else's and is left alone.

The obligation `continuity.export` is "date unknown" (This week on the Desk) until there is a verified export **off this
Mac**, then due 30 days after the last one; the Continuity screen's "Next export due" is the same date. An older export
on this Mac's own disk (from before the app refused them) is named on the screen and in the row's source, but it does
not count.

## Opening one without Linumic OS

The file is a standard [age](https://age-encryption.org/v1) file with a passphrase (scrypt). Any age implementation
opens it: `age` (Go, by its authors; Homebrew, most Linux distributions, Windows releases on GitHub) or `rage` (Rust).

```sh
brew install age                       # once, on a Mac; or download age from github.com/FiloSottile/age/releases
age -d -o linumic-os-continuity.json linumic-os-continuity-2026-10-19-1405.json.age
# age asks for the passphrase
shasum -a 256 linumic-os-continuity.json   # Linux: sha256sum; Windows: certutil -hashfile linumic-os-continuity.json SHA256
```

The SHA-256 must equal "SHA-256 (decrypted)" in the export's record (Continuity screen, or `plaintextSHA256` in
`continuity.json`). The JSON opens in any text editor or with `jq`. Then record it on the Continuity screen:
"Opened outside this Mac…", with what was done (the roadmap's Phase 2 is finished by one export opened and checked
outside this Mac).

## The document (format `linumic-os-continuity`, version 1)

One UTF-8 JSON object, keys sorted, dates in ISO 8601 (UTC):

| Key | What it holds |
|---|---|
| `format`, `formatVersion` | `"linumic-os-continuity"`, `1` |
| `createdAt`, `app` | When, and "Linumic OS 0.2.0 (2)" |
| `excluded` | In words, what is never in the file and where it is instead |
| `inventory` | The inventory as `inventory.json` holds it (schema 2): products, facts and their evidence, oversight, market and content records |
| `obligationEntries` | The owner's entries as `obligations.json` holds them (docs/obligations.md) |
| `obligations` | Every obligation as the register showed it: seed, owner's, accounts' renewals and live dates, each with `source` and `recordedOn` |
| `accounts` | Every account with its holder, renewal and cost, each with its source |
| `licences`, `licencesSyncedAt` | The licence ledger, with `keyText` always null. **Absent** when the ledger was not loaded when the export was made: not read, which is not the same as no licences |
| `keysRegistry` | The Keys & Backups registry: which keys and backups exist, where, since when, with sources. **Absent** when the registry could not be read |

The record's `counts` follow the same rule: a part that was not read has no count, never a zero. The Continuity screen
names such a part before the export is made.

**Never in it:** passwords, tokens, API keys and sessions (Keychain); signing keys, keystores, `.p8` and `.pem` files and
their passwords (their own encrypted backups are described in the keys registry); licence key text (in the Supabase
ledger and the customer's `.lnmlic` file); the run log, Desk marks and cached readings (read again from their sources).
Before encrypting, the document is searched for PEM blocks, LNM1 licence keys, GitHub, Anthropic, Supabase secret,
Google API key, age secret key, JSON Web Token (such as Supabase's legacy `service_role` key), Stripe live key and AWS
access key formats (`ContinuityBundle.forbiddenPatterns`); a match stops the export and names the kind, never the text.
The document has no field meant for a secret; this is a second check on free text (notes, sources).

## The encryption

age v1, scrypt recipient, as written by `AgeFile` (CryptoKit only, no dependency):

- a random 16-byte file key, wrapped with ChaCha20-Poly1305 under scrypt(passphrase, `age-encryption.org/v1/scrypt` ‖
  16-byte salt, N = 2^18, r = 8, p = 1), the stanza `-> scrypt <salt> 18`;
- the header MAC: HMAC-SHA256 under HKDF-SHA256(file key, "header");
- the payload: a 16-byte nonce, then 64 KiB chunks sealed with ChaCha20-Poly1305 under HKDF-SHA256(file key, nonce,
  "payload") (STREAM).

Checked in `AgeFileTests` against age's own test vectors (C2SP/CCTV, `Fixtures/age`): every scrypt vector, and the
header, MAC and STREAM vectors through the file key they give; with the same random parts our encryption writes the
`scrypt` vector byte for byte; scrypt matches RFC 7914. Decryption refuses a work factor above 22 (age's own limit).

## The log (`continuity.json`)

Per export: file name, folder (as shown), where the folder is, created and verified times, later checks ("Check
again…", with the passphrase), file and plain sizes and SHA-256s, work factor, format version, counts, and "opened
outside this Mac" entries (day and evidence, refused without evidence or with a future day). A file that can't be read
is reported and never overwritten.

## Losing the passphrase

Nothing can open the file without it, by design. Keep it on paper and, if wanted, in the Vault of another device. Do
not keep it next to the export or in a Notion page shared with an integration.

## For the owner (دری)

- «تداوم» در نوار کنار: یک بار پوشه‌ای بیرون از مک انتخاب کنید (فلش‌دیسک یا پوشهٔ Google Drive for desktop). برنامه در پوشه‌ای روی دیسک خود مک خروجی نمی‌گیرد.
- عبارت رمز را دو بار بنویسید و روی کاغذ نگه دارید؛ برنامه آن را هیچ‌جا نگه نمی‌دارد. فقط حروف لاتین، رقم و نشانه‌ها؛ حروف دری روی کیبورد دیگری ممکن است حرف دیگری شوند.
- «خروجی و بررسی» فایل را می‌نویسد، دوباره از پوشه می‌خواند و با عبارت رمز باز و مقایسه می‌کند.
- روی کمپیوتر دیگری با `age -d` باز کنید، SHA-256 را مقایسه کنید و در برنامه «بیرون از این مک باز شد…» را ثبت کنید.
