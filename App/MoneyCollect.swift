import Foundation
import LinumicCore

/// Money (پول) as the models already hold it: the WorkTrack company list and money reading of one refresh, SafeBeauty's
/// balance totals, and the obligations register's accounts. No request, no file: Money has no model and no store of
/// its own, so nothing it shows is kept on this device or sent anywhere.
extension MoneyInput {
    @MainActor
    static func collect(worktrack: WorkTrackModel, safeBeauty: SafeBeautyModel, obligations: ObligationsModel, now: Date = .now) -> MoneyInput {
        let register = obligations.register(now: now)
        return MoneyInput(
            worktrack: .collect(worktrack),
            safeBeauty: MoneySafeBeautyInput(isSignedIn: safeBeauty.isSignedIn, environment: safeBeauty.environment?.rawValue,
                                             balances: safeBeauty.balancesRead),
            // An unreadable obligations.json leaves only the seed, whose accounts carry no cost: Unknown, not "none". The
            // store's reason alone: Money's own sentence goes around it.
            costs: MoneyCostsInput(accounts: register.accounts, builtAt: register.builtAt, loadError: obligations.loadFailure))
    }
}

extension MoneyWorkTrackInput {
    /// The company list and the money reading of one WorkTrack refresh, as Money and Sales both read it.
    @MainActor
    static func collect(_ worktrack: WorkTrackModel) -> MoneyWorkTrackInput {
        MoneyWorkTrackInput(isSignedIn: worktrack.isSignedIn, environment: worktrack.environment?.rawValue,
                            companies: worktrack.companies, companiesReadAt: worktrack.lastRead,
                            loadError: worktrack.loadError, money: worktrack.moneyRead)
    }
}
