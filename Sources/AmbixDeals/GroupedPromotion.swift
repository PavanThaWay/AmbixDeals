import Foundation

// The five grouped promotion kinds (AmbixDeals 0.9.0). On the wire they live inside
// `discount`, discriminated by `discount.kind`. `DealDiscount` still decodes all five as
// `.unsupported(kind:)` so every existing "never fire, never edit, never offer" gate keeps
// working; `Deal.grouped` carries the parsed payload beside it.
//
// The decode is STRICT: one invalid field throws, and `Deal.init(from:)` turns the throw
// into `grouped == nil` without failing the Deal. S1's TypeScript `wire.ts` copies the
// decode table in `Rule.forPair` exactly.

public enum GroupedPromotionKind: String, Sendable, Equatable, CaseIterable {
    case itemOffer, quantityGroup, mixGroup, buyGetGroup, slotBundle
}

public enum GroupedPromotionMode: String, Sendable, Equatable {
    case salePrice, amountOff, percentOff, fixedTotal
}

public struct GroupedCategoryTarget: Sendable, Equatable {
    public let name: String
    public let docId: String?
}

public struct GroupedTargets: Sendable, Equatable {
    public let productIds: [String]
    public let categories: [GroupedCategoryTarget]
    public let allProducts: Bool
    public let excludedProductIds: [String]
}

public struct GroupedSlot: Sendable, Equatable {
    public let label: String
    public let quantity: Int
    public let unitCount: Int
    public let targets: GroupedTargets
}

public struct GroupedPromotion: Sendable, Equatable, Decodable {
    public let kind: GroupedPromotionKind
    public let mode: GroupedPromotionMode
    public let cents: Int?
    public let percent: Int?
    public let unitCount: Int?
    public let groupSize: Int?
    public let buyQuantity: Int?
    public let getQuantity: Int?
    public let targets: GroupedTargets?
    public let slots: [GroupedSlot]?
    public let perPurchaseCap: Int?

    static let centsRange = 1...10_000_000
    static let percentRange = 1...99
    static let countRange = 1...999
    static let groupSizeRange = 2...999
    static let slotCountRange = 1...20

    private enum CodingKeys: String, CodingKey {
        case kind, mode, cents, percent, unitCount, groupSize, buyQuantity, getQuantity,
             targets, slots, perPurchaseCap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = GroupedPromotionKind(rawValue: try c.decode(String.self, forKey: .kind)) else {
            throw Self.corrupt(c, .kind, "Unknown grouped kind")
        }
        guard let mode = GroupedPromotionMode(rawValue: try c.decode(String.self, forKey: .mode)) else {
            throw Self.corrupt(c, .mode, "Unknown grouped mode")
        }
        guard let rule = Rule.forPair(kind, mode) else {
            throw Self.corrupt(c, .mode, "Mode \(mode.rawValue) is not valid for \(kind.rawValue)")
        }

        let cents = try Self.int(c, .cents, Self.centsRange)
        let percent = try Self.int(c, .percent, Self.percentRange)
        let unitCount = try Self.int(c, .unitCount, Self.countRange)
        let groupSize = try Self.int(c, .groupSize, Self.groupSizeRange)
        let buyQuantity = try Self.int(c, .buyQuantity, Self.countRange)
        let getQuantity = try Self.int(c, .getQuantity, Self.countRange)
        let perPurchaseCap = try Self.int(c, .perPurchaseCap, Self.countRange)
        let targets: GroupedTargets? = try Self.present(c, .targets)
            ? try c.decode(GroupedTargets.self, forKey: .targets) : nil
        let slots: [GroupedSlot]? = try Self.present(c, .slots)
            ? try c.decode([GroupedSlot].self, forKey: .slots) : nil
        if let slots, !Self.slotCountRange.contains(slots.count) {
            throw Self.corrupt(c, .slots, "A bundle has 1 to 20 slots")
        }

        let given: Set<CodingKeys> = Set(
            [
                cents != nil ? CodingKeys.cents : nil, percent != nil ? .percent : nil,
                unitCount != nil ? .unitCount : nil, groupSize != nil ? .groupSize : nil,
                buyQuantity != nil ? .buyQuantity : nil, getQuantity != nil ? .getQuantity : nil,
                targets != nil ? .targets : nil, slots != nil ? .slots : nil,
                perPurchaseCap != nil ? .perPurchaseCap : nil,
            ].compactMap { $0 }
        )
        if let missing = rule.required.subtracting(given).first {
            throw Self.corrupt(c, missing, "Required field is missing for \(kind.rawValue)/\(mode.rawValue)")
        }
        if let extra = given.subtracting(rule.required).subtracting(rule.optional).first {
            throw Self.corrupt(c, extra, "Field is not allowed for \(kind.rawValue)/\(mode.rawValue)")
        }

        self.kind = kind
        self.mode = mode
        self.cents = cents
        self.percent = percent
        self.unitCount = unitCount
        self.groupSize = groupSize
        self.buyQuantity = buyQuantity
        self.getQuantity = getQuantity
        self.targets = targets
        self.slots = slots
        self.perPurchaseCap = perPurchaseCap
    }

    /// One row of the decode table: which fields must be non-null, which may be, and
    /// (by omission) which must be null or absent.
    private struct Rule {
        let required: Set<CodingKeys>
        let optional: Set<CodingKeys>

        static func forPair(_ kind: GroupedPromotionKind, _ mode: GroupedPromotionMode) -> Rule? {
            let cap: Set<CodingKeys> = [.perPurchaseCap]
            switch (kind, mode) {
            case (.itemOffer, .salePrice), (.itemOffer, .amountOff):
                return Rule(required: [.cents, .unitCount, .targets], optional: [])
            case (.itemOffer, .percentOff):
                return Rule(required: [.percent, .targets], optional: [])
            case (.quantityGroup, .percentOff), (.mixGroup, .percentOff):
                return Rule(required: [.percent, .groupSize, .targets], optional: cap)
            case (.quantityGroup, .fixedTotal), (.mixGroup, .fixedTotal):
                return Rule(required: [.cents, .unitCount, .groupSize, .targets], optional: cap)
            case (.buyGetGroup, .percentOff):
                return Rule(required: [.percent, .buyQuantity, .getQuantity, .targets], optional: cap)
            case (.slotBundle, .fixedTotal):
                return Rule(required: [.cents, .slots], optional: cap)
            default:
                return nil
            }
        }
    }

    fileprivate static func corrupt<K: CodingKey>(
        _ c: KeyedDecodingContainer<K>, _ key: K, _ why: String
    ) -> DecodingError {
        DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: why)
    }

    /// `true` when the key is present and not null.
    fileprivate static func present<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Bool {
        guard c.contains(key) else { return false }
        return !(try c.decodeNil(forKey: key))
    }

    /// Absent or null gives nil; otherwise a JSON integer inside `range` (2.5 and "3" throw).
    private static func int(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ range: ClosedRange<Int>
    ) throws -> Int? {
        guard try present(c, key) else { return nil }
        let value = try c.decode(Int.self, forKey: key)
        guard range.contains(value) else {
            throw corrupt(c, key, "\(key.rawValue) \(value) is outside \(range)")
        }
        return value
    }
}

extension GroupedCategoryTarget: Decodable {
    private enum CodingKeys: String, CodingKey { case name, docId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        guard !name.isEmpty else { throw GroupedPromotion.corrupt(c, .name, "Empty category name") }
        docId = try GroupedPromotion.present(c, .docId) ? try c.decode(String.self, forKey: .docId) : nil
    }
}

extension GroupedTargets: Decodable {
    private enum CodingKeys: String, CodingKey {
        case productIds, categories, allProducts, excludedProductIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productIds = try c.decode([String].self, forKey: .productIds)
        categories = try c.decode([GroupedCategoryTarget].self, forKey: .categories)
        allProducts = try c.decode(Bool.self, forKey: .allProducts)
        excludedProductIds = try c.decode([String].self, forKey: .excludedProductIds)
        if productIds.contains(where: \.isEmpty) {
            throw GroupedPromotion.corrupt(c, .productIds, "Empty product id")
        }
        if excludedProductIds.contains(where: \.isEmpty) {
            throw GroupedPromotion.corrupt(c, .excludedProductIds, "Empty product id")
        }
        let selectors = [!productIds.isEmpty, !categories.isEmpty, allProducts].filter { $0 }.count
        guard selectors == 1 else {
            throw GroupedPromotion.corrupt(c, .productIds, "Exactly one selector must be active")
        }
    }
}

extension GroupedSlot: Decodable {
    private enum CodingKeys: String, CodingKey { case label, quantity, unitCount, targets }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        guard !label.isEmpty else { throw GroupedPromotion.corrupt(c, .label, "Empty slot label") }
        quantity = try c.decode(Int.self, forKey: .quantity)
        unitCount = try c.decode(Int.self, forKey: .unitCount)
        guard GroupedPromotion.countRange.contains(quantity) else {
            throw GroupedPromotion.corrupt(c, .quantity, "Slot quantity is outside 1...999")
        }
        guard GroupedPromotion.countRange.contains(unitCount) else {
            throw GroupedPromotion.corrupt(c, .unitCount, "Slot unitCount is outside 1...999")
        }
        targets = try c.decode(GroupedTargets.self, forKey: .targets)
    }
}
