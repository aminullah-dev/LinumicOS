import Foundation

// MARK: - Products in the Daily Brief (and so on the Desk)
//
// One line per product whose platforms are not level, with every finding in its detail; it is filed under the product,
// so the Desk shows one item per product that is not level. A product whose level is unknown is a gap (an item of its
// own, "unknown, not zero"). Line ids carry the catalogue's product id only.

extension DailyBriefBuilder {
    static func products(_ input: BriefInput) -> BriefSection {
        ProductsBrief.section(input.products)
    }
}

public enum ProductsBrief {
    public static var source: String {
        L("Products: the Platforms hub, the Release Center, the licence ledger, the Monitor and the commits on each default branch (read-only)")
    }

    public static func section(_ report: ProductsReport?) -> BriefSection {
        guard let report else {
            return BriefSection(kind: .products, state: .neverRead(L("The Products page has not been built on this device yet.")),
                                readAt: nil, source: source)
        }
        guard !report.nothingRead else {
            return BriefSection(kind: .products,
                                state: .neverRead(L("Not read yet: the products are built from the Platforms and Release Center readings and the commits on main.")),
                                readAt: nil, source: source)
        }
        var lines: [BriefLine] = []
        var gaps: [BriefGap] = []
        for card in report.cards {
            switch card.level {
            case .notLevel(let findings):
                lines.append(BriefLine(id: "products.notLevel.\(card.id)", kind: .products, severity: .normal,
                                       text: LF("%@: platforms not level", card.product.title),
                                       detail: detail(findings, card: card), source: source, readAt: card.readAt,
                                       destination: .products(card.id), product: card.product.title,
                                       factKey: findings.map(\.key).sorted().joined(separator: "|")))
            case .unknown(let reasons):
                let shown = reasons.prefix(2).joined(separator: L("; "))
                let more = reasons.count > 2 ? LF(" (and %ld more)", reasons.count - 2) : ""
                gaps.append(BriefGap(key: card.id, text: LF("%1$@: whether its platforms are level is unknown: %2$@%3$@", card.product.title, shown, more),
                                     product: card.product.title))
            case .level, .nothingShipped:
                break
            }
        }
        let readAt = report.cards.compactMap(\.readAt).max()
        return DailyBriefBuilder.finish(.products, lines: lines, readAt: readAt, source: source, gaps: gaps)
    }

    /// The findings, with the track's name when the product has more than one compared track.
    static func detail(_ findings: [LevelFinding], card: ProductCard) -> String {
        let tracks = Set(findings.map(\.track))
        let compared = card.product.tracks.filter { $0.slots.contains(where: \.compared) }.count
        return findings.map { f in compared > 1 || tracks.count > 1 ? "\(f.track): \(f.text)" : f.text }.joined(separator: L("; "))
    }
}
