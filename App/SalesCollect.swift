import Foundation
import LinumicCore

/// Sales (فروش) as the models already hold it: WorkTrack's company list and CRM accounts of one refresh (Money's
/// reading), the website messages, and SafeBeauty's KYC queue (its roles only). No request, no file: Sales has no model
/// and no store of its own, so nothing it shows is kept on this device or sent anywhere.
extension SalesInput {
    @MainActor
    static func collect(worktrack: WorkTrackModel, siteMessages: SiteMessagesModel, safeBeauty: SafeBeautyModel) -> SalesInput {
        let snapshot = safeBeauty.snapshot
        return SalesInput(
            worktrack: .collect(worktrack),
            siteMessages: siteMessages.briefInput,
            kyc: SalesKYCInput(isSignedIn: safeBeauty.isSignedIn, environment: safeBeauty.environment?.rawValue,
                               pendingCount: snapshot?.kycPendingCount, queueRoles: snapshot?.kycQueue.map(\.role),
                               readAt: snapshot?.readAt, loadError: safeBeauty.loadError))
    }
}
