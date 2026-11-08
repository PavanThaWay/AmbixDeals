import Foundation

// Plain-words phrases for the register's and phone's read-only promotion lists.
// Money is built from integers: no locale, no NumberFormatter.

extension GroupedPromotionKind {
    /// The box name the owner knows this kind by.
    public var displayName: String {
        switch self {
        case .itemOffer: return "Item discount"
        case .quantityGroup: return "Quantity deal"
        case .mixGroup: return "Mix & match"
        case .buyGetGroup: return "Buy & get"
        case .slotBundle: return "Bundle"
        }
    }
}

extension GroupedPromotion {
    private static let dot = " \u{B7} "

    /// What the shopper gets, in one line. Ends with " · Max N per sale" when capped.
    public var offerPhrase: String {
        let base = baseOfferPhrase
        guard let cap = perPurchaseCap else { return base }
        return base + Self.dot + "Max \(cap) per sale"
    }

    /// What the promotion applies to, in one line.
    public var targetPhrase: String {
        if kind == .slotBundle {
            let n = slots?.count ?? 0
            return n == 1 ? "1 part" : "\(n) parts"
        }
        guard let targets else { return "" }
        var phrase: String
        if targets.allProducts {
            phrase = "All products"
        } else if !targets.categories.isEmpty {
            phrase = targets.categories.map(\.name).joined(separator: ", ")
        } else {
            let n = targets.productIds.count
            phrase = n == 1 ? "1 product" : "\(n) products"
        }
        if !targets.excludedProductIds.isEmpty {
            phrase += Self.dot + "\(targets.excludedProductIds.count) excluded"
        }
        return phrase
    }

    private var baseOfferPhrase: String {
        let money = Self.money(cents ?? 0)
        let pct = percent ?? 0
        let size = groupSize ?? 0
        // A money offer applies to ONE size (the saved unitCount), so a size above 1 is said.
        // Percent offers apply to every size and say nothing.
        let pack = (unitCount ?? 1) > 1 ? Self.dot + "\(unitCount ?? 1)-pack" : ""
        switch (kind, mode) {
        case (.itemOffer, .salePrice): return "\(money) each" + pack
        case (.itemOffer, .amountOff): return "\(money) off each" + pack
        case (.itemOffer, _): return "\(pct)% off each"
        case (.quantityGroup, .fixedTotal): return "\(size) of the same product for \(money)" + pack
        case (.quantityGroup, _): return "Buy \(size) of the same product, \(pct)% off"
        case (.mixGroup, .fixedTotal): return "Any \(size) from this group for \(money)" + pack
        case (.mixGroup, _): return "Any \(size) from this group, \(pct)% off"
        case (.buyGetGroup, _):
            return "Buy \(buyQuantity ?? 0), get \(getQuantity ?? 0) \(pct)% off" + Self.dot + "same product"
        case (.slotBundle, _):
            let parts = (slots ?? []).map { slot in
                slot.unitCount > 1
                    ? "\(slot.quantity) \(slot.label) \(slot.unitCount)-pack"
                    : "\(slot.quantity) \(slot.label)"
            }
            .joined(separator: " + ")
            return "\(parts) for \(money)"
        }
    }

    /// "$12,345.67" from 1234567. Whole dollars get a comma every three digits.
    static func money(_ cents: Int) -> String {
        let dollars = String(cents / 100)
        var grouped = ""
        for (i, ch) in dollars.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        let rest = cents % 100
        return "$" + String(grouped.reversed()) + "." + (rest < 10 ? "0" : "") + String(rest)
    }
}
