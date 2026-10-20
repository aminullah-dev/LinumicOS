import Foundation

// MARK: - What Sales is built from
//
// Plain values the App collects from the models that already read them: WorkTrack's company list and the CRM accounts
// of the same refresh (Money's reading, reused), the website messages, and SafeBeauty's KYC queue. Nothing here makes a
// request, and nothing of it is saved on this device.

/// SafeBeauty's KYC queue as the Operations model holds it.
public struct SalesKYCInput: Sendable {
    public var isSignedIn: Bool
    /// The environment's raw value (production, demo, localEmulator).
    public var environment: String?
    /// `SafeBeautySnapshot.kycPendingCount`: every person waiting for KYC, counted by Firestore.
    public var pendingCount: Int?
    /// The roles of the people in `SafeBeautySnapshot.kycQueue` (at most its first page). Roles only, no names.
    public var queueRoles: [String]?
    public var readAt: Date?
    public var loadError: String?

    public init(isSignedIn: Bool, environment: String?, pendingCount: Int? = nil, queueRoles: [String]? = nil, readAt: Date? = nil,
                loadError: String? = nil) {
        self.isSignedIn = isSignedIn
        self.environment = environment
        self.pendingCount = pendingCount
        self.queueRoles = queueRoles
        self.readAt = readAt
        self.loadError = loadError
    }
}

public struct SalesInput: Sendable {
    /// The same reading Money uses: the company list and `money.accounts` of one refresh.
    public var worktrack: MoneyWorkTrackInput
    /// Nil when the App has no Website messages model.
    public var siteMessages: BriefSiteMessagesInput?
    /// Nil when the App has no SafeBeauty model.
    public var kyc: SalesKYCInput?

    public init(worktrack: MoneyWorkTrackInput, siteMessages: BriefSiteMessagesInput? = nil, kyc: SalesKYCInput? = nil) {
        self.worktrack = worktrack
        self.siteMessages = siteMessages
        self.kyc = kyc
    }
}
