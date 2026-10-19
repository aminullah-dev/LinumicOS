import Foundation

// MARK: - Seed: facts already recorded with a source
//
// Every row below cites where the fact is recorded (a repository doc, a PRIORITIES file, the newest NEXT-ACTIONS report
// or a memory note) and the day it was recorded there. Titles, consequences and purposes are English and localized when
// shown; sources are shown as written. A consequence is given only where a source states it. Seed rows are not stored:
// the owner's dates, Done marks and holders are kept beside them in obligations.json, so a corrected seed never
// overwrites what the owner entered.

public enum ObligationSeed {
    /// Bumped whenever a row is added or corrected (recorded in exports).
    public static let revision = 3

    static let multiplatform = "~/Projects/Multiplatform"
    static let nextActions = "~/Projects/Multiplatform/NEXT-ACTIONS-2026-10-19.md"
    static let memory = "~/.claude/projects/-Users-aminullahhashemi/memory"
    static let repo = "~/Projects/Multiplatform/Linumic/LinumicCommandCenter"

    /// What docs/integrations.md:548-551 says depends on linumic.com, in its own terms (the seed row and the Monitor's
    /// live reading share it). The source names no mailbox, so none is named here.
    static let linumicComConsequence = "linumic.com and its subdomains (such as console.linumic.com) depend on this registration; the hosts on Google's web.app and cloudfunctions.net do not."

    public static var obligations: [Obligation] {
        let d19 = KeyDay("2026-10-19")!
        return [
            // The roadmap named this certificate's date as 2027-09-23. The certificate on this Mac says otherwise:
            // 2027-09-23 is the Mac development profile (below).
            Obligation(id: "signing.developer-id-certificate",
                       title: "Developer ID Application certificate (team 27RXPRW77S) ends",
                       product: "Linumic OS", area: .signing, due: KeyDay("2027-02-01"),
                       consequence: "tools/release/build-release.sh exports Linumic OS releases with the developer-id method, and this is the only Developer ID Application certificate on this Mac. What happens after it ends, to copies already signed or to new releases, is not recorded in a source.",
                       source: "Keychain on this Mac: certificate “Developer ID Application: AMINULLAH HASHEMI (27RXPRW77S)”, not valid after 2027-02-01 22:12:15 GMT; its issuer “Developer ID Certification Authority” ends at the same second (security find-certificate; the only Developer ID identity in security find-identity -v -p codesigning; read 2026-10-19); \(repo)/tools/release/ExportOptions.plist:6 (method developer-id); docs/obligations.md",
                       recordedOn: d19, origin: .seed),
            // What signs the installed copy, and ends before the profile does.
            Obligation(id: "signing.apple-development-certificate",
                       title: "Apple Development certificate (T9QW4K4J88) ends",
                       product: "Linumic OS", area: .signing, due: KeyDay("2027-09-08"),
                       consequence: "It signs the installed Linumic OS 0.2.0 (2), which is development-signed and not notarized. Whether that copy still opens after the certificate ends is not recorded in a source.",
                       source: "Keychain on this Mac: certificate “Apple Development: AMINULLAH HASHEMI (T9QW4K4J88)”, not valid after 2027-09-08 23:26:15 GMT (security find-certificate, read 2026-10-19); codesign -dvv /Applications/LinumicOS.app: Authority “Apple Development: AMINULLAH HASHEMI (T9QW4K4J88)”, and spctl rejects it (read 2026-10-19); \(multiplatform)/PRIORITIES.md:15 («0.2.0 (2) با امضای توسعه در /Applications (notarize نشده)»)",
                       recordedOn: d19, origin: .seed),
            Obligation(id: "signing.linumicos-mac-profile",
                       title: "Mac development profile for com.linumic.commandcenter ends",
                       product: "Linumic OS", area: .signing, due: KeyDay("2027-09-23"),
                       consequence: "The installed 0.2.0 (2) is development-signed, not notarized. Whether it still opens after the profile ends is not recorded in a source.",
                       source: "\(nextActions):147 («Linumic OS، مسیر امضا: پروفایل تا ۲۰۲۷-۰۹-۲۳ اعتبار دارد»); on this Mac the profile is “Mac Team Provisioning Profile: com.linumic.commandcenter”, expires 2027-09-23 (read 2026-10-19). It is a development profile, not the Developer ID. \(multiplatform)/PRIORITIES.md:15 («0.2.0 (2) با امضای توسعه در /Applications (notarize نشده)»)",
                       recordedOn: d19, origin: .seed),
            // «پیش از ۳۱ اکتبر» (before 31 October) is read as "by 30 October", as «پیش از ۲۷ اکتبر» is for WorkTrack's
            // queue below: the due day is the last day before the one the source names.
            Obligation(id: "marketing.safebeauty-dst-pashto",
                       title: "Move SafeBeauty's Pashto post times before US daylight time ends on 2026-11-01",
                       product: "SafeBeauty", area: .marketing, due: KeyDay("2026-10-30"),
                       consequence: "From 2026-11-01 the scheduled Pashto posts go out at 23:30 Kabul time, because Business Suite schedules in New York time.",
                       source: "\(nextActions):119 («از ۱ نومبر که DST آمریکا تمام می‌شود، پست‌های پشتو ساعت 23:30 … به وقت کابل منتشر می‌شوند. موعد: برای پشتو پیش از ۳۱ اکتبر»: «پیش از» read as the day before, 2026-10-30); \(memory)/safebeauty-marketing.md:57 (Business Suite time zone America/New_York)",
                       recordedOn: d19, origin: .seed),
            Obligation(id: "marketing.safebeauty-dst-reels",
                       title: "Move SafeBeauty's reel times before the reels run on 2026-11-11",
                       product: "SafeBeauty", area: .marketing, due: KeyDay("2026-11-09"),
                       consequence: "After US daylight time ends on 2026-11-01, the reels scheduled for 17:00 New York time go out at 02:30 Kabul time.",
                       source: "\(nextActions):119 («ریل‌های 17:00 ساعت 02:30 به وقت کابل … برای ریل‌ها پیش از ۱۰ نومبر»: «پیش از» read as the day before, 2026-11-09); \(memory)/safebeauty-marketing.md:57 (reels Nov 11-13)",
                       recordedOn: d19, origin: .seed),
            Obligation(id: "marketing.worktrack-queue-end",
                       title: "WorkTrack's scheduled Meta posts end on 2026-10-26",
                       product: "WorkTrack", area: .marketing, due: KeyDay("2026-10-26"),
                       consequence: "From 2026-10-27 nothing is scheduled on WorkTrack's Facebook and Instagram; 24 launch packages and 4 videos are ready but not scheduled.",
                       source: "\(memory)/worktrack-marketing.md:15 (scheduled 2026-10-19..26, next free day 2026-10-27, recorded 2026-10-18); \(nextActions):117 («WorkTrack، پیش از ۲۷ اکتبر»)",
                       recordedOn: KeyDay("2026-10-18"), origin: .seed),
            // The Monitor's live RDAP reading replaces this row (same id) once it has read the domain.
            Obligation(id: "domain.linumic.com",
                       title: "linumic.com registration ends",
                       product: "linumic.com", area: .domains, due: KeyDay("2029-08-15"),
                       consequence: linumicComConsequence,
                       source: "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/docs/integrations.md:548-551 (RDAP on 2026-10-09: expires 2029-08-15, registrar GoDaddy.com, LLC; every other host is a subdomain of it or Google's)",
                       recordedOn: KeyDay("2026-10-09"), origin: .seed, subject: "linumic.com"),
            Obligation(id: "stores.play-target-api",
                       title: "Google Play target API level: the next deadline",
                       area: .stores, due: nil,
                       consequence: "Apps below the required level can't release updates on Google Play.",
                       source: "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/docs/product-discovery-report.md:79 (Play Console notice seen on 2026-09-23: “Update your target API level by August 31, 2026 to release updates to your app”, 2 apps; which ones was not recorded). That deadline had already passed when the notice was read; the next one is not recorded.",
                       recordedOn: KeyDay("2026-09-23"), origin: .seed),
        ]
    }

    public static var accounts: [VendorAccount] {
        let d23 = KeyDay("2026-09-23")!
        let d19 = KeyDay("2026-10-19")!
        let lcc = "\(memory)/linumic-command-center.md"
        return [
            VendorAccount(id: "apple-developer", name: "Apple Developer Program",
                          purpose: "App Store and TestFlight for the iOS apps, and the signing certificates (team 27RXPRW77S).",
                          holder: .personal,
                          holderSource: "\(lcc):21 (team 27RXPRW77S, Individual); ~/Projects/Multiplatform/Linumic/LinumicCommandCenter/docs/product-discovery-report.md:62 (every App Store listing names the seller as the individual “AMINULLAH HASHEMI”)",
                          source: "\(lcc):21", recordedOn: d23, origin: .seed),
            VendorAccount(id: "google-play", name: "Google Play Console",
                          purpose: "The Android apps on Google Play.",
                          holder: .personal, holderSource: "\(lcc):40 (developer account 7764339598095587681, personal)",
                          source: "\(lcc):40; \(multiplatform)/PRIORITIES.md:78 (identity AMINULLAH HASHEMI, Ottawa, Canada)",
                          recordedOn: d23, origin: .seed),
            VendorAccount(id: "godaddy", name: "GoDaddy",
                          purpose: "Registrar of linumic.com and host of the linumic.com WordPress site. The domain's own date is read from RDAP.",
                          source: "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/docs/integrations.md:550 (registrar GoDaddy.com, LLC); \(memory)/linumic-site.md:11 (WordPress on a GoDaddy host), :107 (Basic plan)",
                          recordedOn: KeyDay("2026-10-09"), origin: .seed),
            VendorAccount(id: "microsoft-365", name: "Microsoft 365 (contact@linumic.com)",
                          purpose: "The contact@linumic.com mailbox in Outlook, where the website form's mail arrives.",
                          source: "\(memory)/linumic-site.md:107 (test mail reached contact@linumic.com, Outlook/M365, 2026-10-09)",
                          recordedOn: KeyDay("2026-10-09"), origin: .seed),
            VendorAccount(id: "hetzner", name: "Hetzner",
                          purpose: "VELRO's server (Docker Compose).",
                          source: "\(multiplatform)/Velro/PRIORITIES.md:9 (reviewed 2026-10-19)",
                          recordedOn: d19, origin: .seed),
            VendorAccount(id: "google-cloud", name: "Google Cloud and Firebase",
                          purpose: "WorkTrack's production and demo projects (worktrack-prod, worktrack-demo-af) and SafeBeauty's Firebase functions.",
                          source: "\(memory)/worktrack-strengthen-platform.md:13 (deployed 2026-10-06); \(memory)/safebeauty-marketing.md:49",
                          recordedOn: KeyDay("2026-10-06"), origin: .seed),
            VendorAccount(id: "supabase", name: "Supabase",
                          purpose: "Linumic OS's backend: inventory sync, the licence ledger and the Sentinel. Free plan.",
                          source: "~/Projects/Multiplatform/Linumic/LinumicCommandCenter/docs/backend-plan.md:11 (the Organization row: mjkdmjrjalelcmqwdwok, Free plan); \(lcc):48",
                          recordedOn: d23, origin: .seed),
            VendorAccount(id: "github", name: "GitHub (aminullah-dev)",
                          purpose: "Every product's repositories.",
                          holder: .personal, holderSource: "GitHub API users/aminullah-dev: type User, not an organization (read 2026-10-19)",
                          source: "\(nextActions):67 (all recovery codes are under one account, aminullah-dev)",
                          recordedOn: d19, origin: .seed),
            VendorAccount(id: "meta-ads", name: "Meta ad account (act 1061522111943056)",
                          purpose: "SafeBeauty's ads.",
                          holder: .personal, holderSource: "\(memory)/safebeauty-marketing.md:29 (“the user's personal ad account … not a business portfolio”)",
                          source: "\(memory)/safebeauty-marketing.md:29", recordedOn: KeyDay("2026-09-27"), origin: .seed),
            VendorAccount(id: "elevenlabs", name: "ElevenLabs",
                          purpose: "Sounds and voices (about 3,200 credits used for BE-PAYA).",
                          source: "\(memory)/be-paya-game.md:17", recordedOn: KeyDay("2026-10-12"), origin: .seed),
            VendorAccount(id: "notion", name: "Notion",
                          purpose: "The private page that holds the backup passphrase.",
                          source: "\(memory)/linumic-licensing.md:30", recordedOn: KeyDay("2026-10-09"), origin: .seed),
        ]
    }
}
