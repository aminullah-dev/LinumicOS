import Foundation
import Testing
@testable import LinumicCore

// Opt-in, LOCAL EMULATOR ONLY. Exercises the real client against the WorkTrack Firebase Emulator Suite
// (project demo-worktrack) and reads the emulator's Firestore directly to check what was stored.
//
//   LCC_WT_EMULATOR=1 swift test --package-path Packages/LinumicCore --filter liveEmulator
//
// Needs the emulators running (functions, firestore, auth) with the vendor test user and sample companies from
// docs/integrations.md ("WorkTrack: testing against the emulator"). It never talks to a real project: the
// environment is fixed to `.localEmulator` (127.0.0.1).

private let enabled = ProcessInfo.processInfo.environment["LCC_WT_EMULATOR"] == "1"
private let vendorEmail = ProcessInfo.processInfo.environment["LCC_WT_VENDOR_EMAIL"] ?? "vendor@linumic.test"
private let password = ProcessInfo.processInfo.environment["LCC_WT_PASSWORD"] ?? "Emulator-Vendor-Only-1"

/// The licence as stored in the emulator's Firestore (`companies/{id}.license`), via its REST API.
private func storedLicense(_ companyID: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/projects/demo-worktrack/databases/(default)/documents/companies/\(companyID)")!)
    request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")  // emulator admin bypass
    let (data, _) = try await URLSession.shared.data(for: request)
    let doc = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let fields = try #require(doc["fields"] as? [String: Any])
    let license = try #require((fields["license"] as? [String: Any])?["mapValue"] as? [String: Any])
    return try #require(license["fields"] as? [String: Any])
}

private func value(_ field: Any?) -> String {
    guard let f = field as? [String: Any], let (k, v) = f.first else { return "missing" }
    if k == "arrayValue" { return "[" + (((v as? [String: Any])?["values"] as? [Any]) ?? []).map(value).joined(separator: ",") + "]" }
    return "\(k.replacingOccurrences(of: "Value", with: "")):\(v)"
}

@Suite("WorkTrack local emulator (opt-in)", .enabled(if: enabled))
struct WorkTrackEmulatorTests {
    @Test func liveEmulatorSignInListDetailRenewAndErrors() async throws {
        let env = WorkTrackEnvironment.localEmulator
        #expect(env.apiBase.host == "127.0.0.1" && env.auth.identityToolkit.host == "127.0.0.1")
        let client = WorkTrackVendorClient(environment: env)

        // Sign in, then every read.
        let session = try await client.signIn(email: vendorEmail, password: password)
        #expect(!session.refreshToken.isEmpty)
        let me = try await client.me()
        #expect(me.vendor && me.email == vendorEmail)
        let companies = try await client.companies()
        print("EMULATOR companies:", companies.map { "\($0.companyId) \($0.license.plan.rawValue) exp=\($0.license.expiresAt ?? "perpetual") days=\($0.daysUntilExpiry.map(String.init) ?? "-") flag=\($0.flags?.kind ?? "-")" })
        let target = try #require(companies.first { $0.companyId == "emu_herat" })
        let detail = try await client.detail(target.companyId)
        #expect(detail.company.license == target.license)
        let orders = try await client.orders(target.companyId)
        let revenue = try await client.revenue()
        let plans = try await client.plans()
        let auditBefore = try await client.audit()
        print("EMULATOR detail timeline:", detail.timeline.count, "orders:", orders.count, "revenue earned:", revenue.earned.totalAfn,
              "plans:", plans.keys.sorted(), "audit entries:", auditBefore.count)

        // Renew +1 month from the licence just fetched.
        let today = WorkTrackDates.kabulToday()
        let current = try await client.company(target.companyId).license
        let newEnd = try #require(WorkTrackRenewal.extended(current, months: 1, today: today))
        let write = try WorkTrackRenewal.makeWrite(current: current, input: WTRenewalInput(plan: current.plan, deviceLimit: current.deviceLimit,
                                                                                           status: WorkTrackRenewal.suggestedStatus(for: current), expiry: .date(newEnd)), today: today)
        print("EMULATOR PUT body:", String(data: try JSONEncoder().encode(write), encoding: .utf8)!)
        let returned = try await client.putLicense(companyID: target.companyId, write)
        let refetched = try await client.detail(target.companyId).company.license
        #expect(returned == refetched)
        #expect(WorkTrackRenewal.mismatches(expected: write.expectedLicense, stored: refetched).isEmpty)
        #expect(refetched.expiresAt == newEnd, "expiresAt stays set")
        #expect(refetched.enforceDevices == current.enforceDevices && refetched.enforcePlan == current.enforcePlan
                && refetched.employeeLimit == current.employeeLimit && refetched.extraFeatures == current.extraFeatures
                && refetched.deviceLimit == current.deviceLimit && refetched.plan == current.plan)

        // What Firestore itself holds.
        let stored = try await storedLicense(target.companyId)
        let summary = ["plan", "deviceLimit", "status", "expiresAt", "enforceDevices", "enforcePlan", "employeeLimit", "extraFeatures", "source"]
            .map { "\($0)=\(value(stored[$0]))" }
        print("EMULATOR Firestore companies/\(target.companyId).license:", summary.joined(separator: " "))
        #expect(value(stored["expiresAt"]) == "string:\(newEnd)")
        #expect(value(stored["source"]) == "string:VENDOR")
        if let cap = current.employeeLimit { #expect(value(stored["employeeLimit"]) == "integer:\(cap)") }

        let auditAfter = try await client.audit()
        #expect(auditAfter.count == auditBefore.count + 1)
        #expect(auditAfter.first?.action == "license.update" && auditAfter.first?.companyId == target.companyId
                && auditAfter.first?.after?.asLicense?.expiresAt == newEnd)

        // Error paths.
        await #expect(throws: WorkTrackError.notFound("Company not found")) { _ = try await client.detail("no_such_company") }
        await #expect(throws: WorkTrackError.self) {
            // Bypasses the builder on purpose to see the server's 422.
            _ = try await client.putLicense(companyID: target.companyId, WTLicenseWrite(plan: .silver, deviceLimit: 0, status: .active, expiresAt: newEnd,
                                                                                        enforceDevices: false, enforcePlan: false, employeeLimit: nil, extraFeatures: []))
        }
        do {
            _ = try await client.putLicense(companyID: target.companyId, WTLicenseWrite(plan: .silver, deviceLimit: 0, status: .active, expiresAt: newEnd,
                                                                                        enforceDevices: false, enforcePlan: false, employeeLimit: nil, extraFeatures: []))
        } catch let e as WorkTrackError {
            guard case .validation(_, let fields) = e else { Issue.record("expected 422, got \(e)"); return }
            #expect(fields.keys.contains("deviceLimit"))
            print("EMULATOR 422:", e.localizedDescription)
        }
        #expect(try await client.company(target.companyId).license == refetched, "the refused writes changed nothing")

        let wrong = WorkTrackVendorClient(environment: env)
        await #expect(throws: WorkTrackError.auth(.invalidCredentials)) { _ = try await wrong.signIn(email: vendorEmail, password: "not-the-password") }

        let notVendor = WorkTrackVendorClient(environment: env)
        _ = try await notVendor.signIn(email: "novendor@linumic.test", password: password)
        await #expect(throws: WorkTrackError.notVendor) { _ = try await notVendor.me() }

        let unverified = WorkTrackVendorClient(environment: env)
        _ = try await unverified.signIn(email: "unverified@linumic.test", password: password)
        await #expect(throws: WorkTrackError.emailNotVerified) { _ = try await unverified.companies() }

        let stale = WorkTrackVendorClient(environment: env)
        await stale.restore(refreshToken: "not-a-real-refresh-token")
        await #expect(throws: WorkTrackError.auth(.sessionExpired)) { _ = try await stale.me() }

        // A restored session (refresh token only) works.
        let restored = WorkTrackVendorClient(environment: env)
        await restored.restore(refreshToken: session.refreshToken)
        #expect(try await restored.me().vendor)
    }
}
