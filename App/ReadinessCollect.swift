import Foundation
import LinumicCore

/// Operational readiness as the models already hold it: the Products cards, the Desk's ledgers, the Keys & Backups
/// registry and its file checks, the obligations register, the continuity log and the apps in /Applications. No request
/// and no file: the scorecard has no model and no store of its own, so nothing it shows is kept or sent anywhere.
extension ReadinessInput {
    @MainActor
    static func collect(cards: [ProductCard], products: ProductsModel, desk: DeskModel, keys: KeysModel, obligations: ObligationsModel,
                        continuity: ContinuityModel, now: Date = .now) -> ReadinessInput {
        let installed = products.installedStatuses()
        return ReadinessInput(
            now: now, cards: cards, ledgers: desk.desk(now: now).sources,
            // A registry, register or log that could not be read is unknown, not empty.
            keys: keys.loadError == nil ? keys.registry : nil, keyResults: keys.results,
            obligations: obligations.loadError == nil ? obligations.register(now: now) : nil,
            continuity: continuity.isAvailable && continuity.loadError == nil ? continuity.log : nil,
            // iPhone and iPad have no /Applications to read: not read, which is not "nothing installed".
            installed: KeysModel.supportsLocalChecks || !installed.isEmpty ? installed : nil)
    }
}
