import Foundation
import Testing

@testable import AmbixDeals

@Suite struct GroupedPromotionDecodeTests {

    typealias Raw = [String: Any]

    // MARK: - Fixtures

    private func targets(
        productIds: [String] = ["p1"], categories: [Raw] = [], allProducts: Bool = false,
        excluded: [String] = []
    ) -> Raw {
        [
            "productIds": productIds, "categories": categories,
            "allProducts": allProducts, "excludedProductIds": excluded,
        ]
    }

    private func slot(unitCount: Bool = true) -> Raw {
        var s: Raw = ["label": "Wine", "quantity": 1, "targets": targets()]
        if unitCount { s["unitCount"] = 1 }
        return s
    }

    private func doc(discount: Raw, revision: Any = 1) -> Raw {
        [
            "name": "Grouped", "isActive": false, "channel": "inStore", "audience": "any",
            "perCustomerLimit": 0, "usageLimit": 0, "couponCode": NSNull(),
            "marginFloorOverrideCents": NSNull(), "revision": revision,
            "scope": ["type": "products", "ids": [String]()] as Raw,
            "schedule": [
                "weekdayMask": 127, "dayStartMinute": 0, "dayEndMinute": 1440,
                "startDate": NSNull(), "endDate": NSNull(),
            ] as Raw,
            "discount": discount,
        ]
    }

    private func decode(_ discount: Raw, revision: Any = 1) -> Deal? {
        DealDocumentSanitizer.decodeDeal(doc(discount: discount, revision: revision), id: "p1")
    }

    private func merged(_ base: Raw, _ extra: Raw) -> Raw {
        base.merging(extra) { _, new in new }
    }

    // MARK: - Valid rows

    struct Row: Sendable, CustomTestStringConvertible {
        let discount: [String: any Sendable]
        let expected: Want
        var testDescription: String { "\(expected.kind.rawValue)/\(expected.mode.rawValue)" }
    }

    private static let t: [String: any Sendable] = [
        "productIds": ["p1"], "categories": [[String: any Sendable]](),
        "allProducts": false, "excludedProductIds": [String](),
    ]
    private static let tx: [String: any Sendable] = [
        "productIds": ["p1"], "categories": [[String: any Sendable]](),
        "allProducts": false, "excludedProductIds": ["x1"],
    ]
    private static let tAll: [String: any Sendable] = [
        "productIds": [String](), "categories": [[String: any Sendable]](),
        "allProducts": true, "excludedProductIds": ["x1", "x2"],
    ]
    private static let gt = GroupedTargets(
        productIds: ["p1"], categories: [], allProducts: false, excludedProductIds: [])
    private static let gtx = GroupedTargets(
        productIds: ["p1"], categories: [], allProducts: false, excludedProductIds: ["x1"])
    private static let gtAll = GroupedTargets(
        productIds: [], categories: [], allProducts: true, excludedProductIds: ["x1", "x2"])

    /// Every field of a `GroupedPromotion`, spelled out (it has no public memberwise init).
    struct Want: Sendable, Equatable {
        var kind: GroupedPromotionKind, mode: GroupedPromotionMode
        var cents: Int?, percent: Int?, unitCount: Int?, groupSize: Int?
        var buyQuantity: Int?, getQuantity: Int?
        var targets: GroupedTargets?, slots: [GroupedSlot]?, perPurchaseCap: Int?

        init(_ g: GroupedPromotion) {
            kind = g.kind; mode = g.mode; cents = g.cents; percent = g.percent
            unitCount = g.unitCount; groupSize = g.groupSize; buyQuantity = g.buyQuantity
            getQuantity = g.getQuantity; targets = g.targets; slots = g.slots
            perPurchaseCap = g.perPurchaseCap
        }

        init(
            _ kind: GroupedPromotionKind, _ mode: GroupedPromotionMode,
            cents: Int? = nil, percent: Int? = nil, unitCount: Int? = nil, groupSize: Int? = nil,
            buy: Int? = nil, get: Int? = nil, targets: GroupedTargets? = nil,
            slots: [GroupedSlot]? = nil, cap: Int? = nil
        ) {
            self.kind = kind; self.mode = mode; self.cents = cents; self.percent = percent
            self.unitCount = unitCount; self.groupSize = groupSize; buyQuantity = buy
            getQuantity = get; self.targets = targets; self.slots = slots; perPurchaseCap = cap
        }
    }

    static let rows: [Row] = [
        Row(discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 899, "unitCount": 6, "targets": t],
            expected: Want(.itemOffer, .salePrice, cents: 899, unitCount: 6, targets: gt)),
        Row(discount: ["kind": "itemOffer", "mode": "amountOff", "cents": 150, "unitCount": 2, "targets": tx],
            expected: Want(.itemOffer, .amountOff, cents: 150, unitCount: 2, targets: gtx)),
        Row(discount: ["kind": "itemOffer", "mode": "percentOff", "percent": 15, "targets": t],
            expected: Want(.itemOffer, .percentOff, percent: 15, targets: gt)),
        Row(discount: ["kind": "quantityGroup", "mode": "percentOff", "percent": 10, "groupSize": 3,
                       "targets": t, "perPurchaseCap": 4],
            expected: Want(.quantityGroup, .percentOff, percent: 10, groupSize: 3, targets: gt, cap: 4)),
        Row(discount: ["kind": "quantityGroup", "mode": "fixedTotal", "cents": 2000, "unitCount": 1,
                       "groupSize": 2, "targets": t],
            expected: Want(.quantityGroup, .fixedTotal, cents: 2000, unitCount: 1, groupSize: 2, targets: gt)),
        Row(discount: ["kind": "mixGroup", "mode": "percentOff", "percent": 20, "groupSize": 4, "targets": t],
            expected: Want(.mixGroup, .percentOff, percent: 20, groupSize: 4, targets: gt)),
        Row(discount: ["kind": "mixGroup", "mode": "fixedTotal", "cents": 3000, "unitCount": 2,
                       "groupSize": 5, "targets": t, "perPurchaseCap": 7],
            expected: Want(.mixGroup, .fixedTotal, cents: 3000, unitCount: 2, groupSize: 5, targets: gt, cap: 7)),
        Row(discount: ["kind": "buyGetGroup", "mode": "percentOff", "percent": 50, "buyQuantity": 2,
                       "getQuantity": 3, "targets": t],
            expected: Want(.buyGetGroup, .percentOff, percent: 50, buy: 2, get: 3, targets: gt)),
        Row(discount: ["kind": "slotBundle", "mode": "fixedTotal", "cents": 4500,
                       "slots": [["label": "Wine", "quantity": 2, "unitCount": 6, "targets": tx]]],
            expected: Want(.slotBundle, .fixedTotal, cents: 4500, slots: [
                GroupedSlot(label: "Wine", quantity: 2, unitCount: 6, targets: gtx)])),
        Row(discount: ["kind": "itemOffer", "mode": "percentOff", "percent": 5, "targets": tAll],
            expected: Want(.itemOffer, .percentOff, percent: 5, targets: gtAll)),
    ]

    @Test(arguments: rows)
    func everyKindAndModeInTheTableDecodes(_ row: Row) throws {
        let deal = try #require(decode(row.discount.mapValues { $0 as Any }))
        #expect(deal.discount == .unsupported(kind: row.expected.kind.rawValue))
        #expect(deal.grouped.map(Want.init) == row.expected)
    }

    // MARK: - The table's refusals, driven from the valid rows

    private static let forbiddenValue: [String: Any] = [
        "cents": 100, "percent": 10, "unitCount": 2, "groupSize": 3, "buyQuantity": 1,
        "getQuantity": 1, "targets": t,
        "slots": [["label": "Wine", "quantity": 1, "unitCount": 1, "targets": t]],
    ]
    private static let ranges: [String: ClosedRange<Int>] = [
        "cents": 1...10_000_000, "percent": 1...99, "unitCount": 1...999, "groupSize": 2...999,
        "buyQuantity": 1...999, "getQuantity": 1...999, "perPurchaseCap": 1...999,
    ]

    private func grouped(_ d: Raw) -> GroupedPromotion? { decode(d)?.grouped }

    private func with(_ d: Raw, _ key: String, _ value: Any?) -> Raw {
        var out = d
        out[key] = value
        return out
    }

    @Test(arguments: rows)
    func everyRefusalRuleOfTheTableHolds(_ row: Row) throws {
        let base: Raw = row.discount.mapValues { $0 as Any }
        #expect(grouped(base) != nil)
        let optionalCap = row.expected.kind != .itemOffer
        let required = Set(base.keys).subtracting(["kind", "mode", "perPurchaseCap"])

        for key in required {
            #expect(grouped(with(base, key, nil)) == nil, "dropping \(key)")
            #expect(grouped(with(base, key, NSNull())) == nil, "null \(key)")
        }
        for (key, value) in Self.forbiddenValue where !required.contains(key) {
            #expect(grouped(with(base, key, value)) == nil, "forbidden \(key)")
            #expect(grouped(with(base, key, NSNull())) != nil, "null \(key) is the same as absent")
        }
        if optionalCap {
            #expect(grouped(with(base, "perPurchaseCap", NSNull())) != nil)
        } else {
            #expect(grouped(with(base, "perPurchaseCap", 2)) == nil, "itemOffer carries no cap")
        }
        for (key, range) in Self.ranges where required.contains(key) || (key == "perPurchaseCap" && optionalCap) {
            #expect(grouped(with(base, key, range.lowerBound)) != nil, "\(key) low edge")
            #expect(grouped(with(base, key, range.upperBound)) != nil, "\(key) high edge")
            #expect(grouped(with(base, key, range.lowerBound - 1)) == nil, "\(key) below")
            #expect(grouped(with(base, key, range.upperBound + 1)) == nil, "\(key) above")
        }
    }

    @Test func slotCountAndSlotFieldsHoldTheirEdges() throws {
        func slotDoc(_ slots: [Raw]) -> Raw {
            ["kind": "slotBundle", "mode": "fixedTotal", "cents": 4500, "slots": slots]
        }
        let one: Raw = ["label": "Wine", "quantity": 1, "unitCount": 1, "targets": Self.t]
        #expect(grouped(slotDoc(Array(repeating: one, count: 20))) != nil)
        #expect(grouped(slotDoc(Array(repeating: one, count: 19))) != nil)
        #expect(grouped(slotDoc(Array(repeating: one, count: 21))) == nil)
        #expect(grouped(slotDoc([])) == nil)
        #expect(grouped(slotDoc([with(one, "label", "")])) == nil)
        for key in ["quantity", "unitCount"] {
            #expect(grouped(slotDoc([with(one, key, 999)])) != nil, "\(key) 999")
            #expect(grouped(slotDoc([with(one, key, 0)])) == nil, "\(key) 0")
            #expect(grouped(slotDoc([with(one, key, 1000)])) == nil, "\(key) 1000")
            #expect(grouped(slotDoc([with(one, key, nil)])) == nil, "\(key) missing")
        }
        #expect(grouped(slotDoc([with(one, "targets", nil)])) == nil)
        #expect(grouped(slotDoc([with(one, "label", nil)])) == nil)
    }

    @Test func targetsRefuseWhatTheTableRefuses() throws {
        func doc(_ targets: Raw) -> Raw {
            ["kind": "itemOffer", "mode": "percentOff", "percent": 15, "targets": targets]
        }
        let base: Raw = Self.t.mapValues { $0 as Any }
        #expect(grouped(doc(base)) != nil)
        #expect(grouped(doc(with(base, "allProducts", nil))) == nil)
        #expect(grouped(doc(with(base, "productIds", nil))) == nil)
        #expect(grouped(doc(with(base, "categories", nil))) == nil)
        #expect(grouped(doc(with(base, "excludedProductIds", [""]))) == nil)
        #expect(grouped(doc(with(base, "excludedProductIds", ["x1"]))) != nil)
        let cat: Raw = ["name": "Wine", "docId": 9]
        #expect(grouped(doc(with(with(base, "productIds", [String]()), "categories", [cat]))) == nil)
        #expect(grouped(doc(with(with(base, "productIds", [String]()), "categories", [["name": "Wine", "docId": ""]]))) != nil)
    }

    // MARK: - Inertness

    @Test func aGroupedDocIsInertForTheOldReaders() throws {
        let d: Raw = Self.rows[5].discount.mapValues { $0 as Any }
        let deal = try #require(decode(d))
        #expect(deal.discount == .unsupported(kind: "mixGroup"))
        #expect(deal.scope == .products(ids: []))
        #expect(deal.print == nil)
        #expect(DealDraft(from: deal) == nil)
        #expect(deal.revision == 1)
        #expect(deal.groupedKind == .mixGroup)
    }

    // MARK: - Malformed payloads

    struct Bad: Sendable, CustomTestStringConvertible {
        let why: String
        let discount: [String: any Sendable]
        var testDescription: String { why }
    }

    private static func item(_ extra: [String: any Sendable], drop: [String] = []) -> [String: any Sendable] {
        var d: [String: any Sendable] = ["kind": "itemOffer", "mode": "percentOff", "percent": 15, "targets": t]
        for (k, v) in extra { d[k] = v }
        for k in drop { d[k] = nil }
        return d
    }

    private static func group(_ extra: [String: any Sendable]) -> [String: any Sendable] {
        var d: [String: any Sendable] = [
            "kind": "mixGroup", "mode": "percentOff", "percent": 10, "groupSize": 3, "targets": t,
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    private static func bundle(_ extra: [String: any Sendable]) -> [String: any Sendable] {
        var d: [String: any Sendable] = [
            "kind": "slotBundle", "mode": "fixedTotal", "cents": 4500,
            "slots": [["label": "Wine", "quantity": 1, "unitCount": 1, "targets": t]],
        ]
        for (k, v) in extra { d[k] = v }
        return d
    }

    private static func targetsWith(_ extra: [String: any Sendable], drop: [String] = []) -> [String: any Sendable] {
        var x = t
        for (k, v) in extra { x[k] = v }
        for k in drop { x[k] = nil }
        return item(["targets": x])
    }

    static let bads: [Bad] = [
        Bad(why: "percent 0", discount: item(["percent": 0])),
        Bad(why: "percent 100", discount: item(["percent": 100])),
        Bad(why: "percent 12.5", discount: item(["percent": 12.5])),
        Bad(why: "percent as a string", discount: item(["percent": "15"])),
        Bad(why: "cents 0", discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 0, "unitCount": 1, "targets": t]),
        Bad(why: "cents 10000001", discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 10_000_001, "unitCount": 1, "targets": t]),
        Bad(why: "groupSize 1", discount: group(["groupSize": 1])),
        Bad(why: "itemOffer with a cap", discount: item(["perPurchaseCap": 2])),
        Bad(why: "itemOffer percentOff carrying cents", discount: item(["cents": 100])),
        Bad(why: "mixGroup salePrice", discount: group(["mode": "salePrice"])),
        Bad(why: "buyGetGroup fixedTotal", discount: ["kind": "buyGetGroup", "mode": "fixedTotal", "cents": 100, "buyQuantity": 1, "getQuantity": 1, "targets": t]),
        Bad(why: "mode free", discount: item(["mode": "free"])),
        Bad(why: "slotBundle carrying targets", discount: bundle(["targets": t])),
        Bad(why: "slotBundle carrying a top-level unitCount", discount: bundle(["unitCount": 1])),
        Bad(why: "slot without unitCount", discount: bundle(["slots": [["label": "Wine", "quantity": 1, "targets": t]]])),
        Bad(why: "slotBundle with no slots", discount: bundle(["slots": [[String: any Sendable]]()])),
        Bad(why: "21 slots", discount: bundle(["slots": (0..<21).map { _ in ["label": "Wine", "quantity": 1, "unitCount": 1, "targets": t] as [String: any Sendable] }])),
        Bad(why: "targets with two selectors", discount: targetsWith(["allProducts": true])),
        Bad(why: "targets with no selector", discount: targetsWith(["productIds": [String]()])),
        Bad(why: "targets missing excludedProductIds", discount: targetsWith([:], drop: ["excludedProductIds"])),
        Bad(why: "category name empty", discount: targetsWith(["productIds": [String](), "categories": [["name": ""]]])),
        Bad(why: "productIds with an empty string", discount: targetsWith(["productIds": [""]])),
    ]

    @Test(arguments: bads)
    func malformedGroupedPayloadKeepsTheDealButDropsGrouped(_ bad: Bad) throws {
        let d: Raw = bad.discount.mapValues { $0 as Any }
        let deal = try #require(decode(d))
        #expect(deal.grouped == nil)
        #expect(deal.groupedKind != nil)
        guard case .unsupported = deal.discount else {
            Issue.record("discount should stay unsupported")
            return
        }
    }

    // MARK: - Neighbours

    @Test func oldKindsNeverCarryGrouped() throws {
        let d: Raw = [
            "kind": "flatPercentOff", "percent": 10, "mode": "percentOff", "targets": targets(),
        ]
        let deal = try #require(decode(d))
        #expect(deal.grouped == nil)
        #expect(deal.groupedKind == nil)
    }

    @Test func revisionDecodesAndToleratesGarbage() throws {
        let d: Raw = Self.rows[2].discount.mapValues { $0 as Any }
        #expect(decode(d, revision: 7)?.revision == 7)
        var absent = doc(discount: d)
        absent["revision"] = nil
        let noRevision = try #require(DealDocumentSanitizer.decodeDeal(absent, id: "p1"))
        #expect(noRevision.revision == nil)
        let garbage = try #require(decode(d, revision: "7"))
        #expect(garbage.revision == nil)
    }

    @Test func categoryDocIdMayBeAbsentNullOrString() throws {
        func docId(_ category: Raw) throws -> String? {
            let tgt = targets(productIds: [], categories: [category])
            let d: Raw = ["kind": "itemOffer", "mode": "percentOff", "percent": 15, "targets": tgt]
            let g = try #require(decode(d)?.grouped)
            let cat = try #require(g.targets?.categories.first)
            #expect(cat.name == "Wine")
            return cat.docId
        }
        #expect(try docId(["name": "Wine"]) == nil)
        #expect(try docId(["name": "Wine", "docId": NSNull()]) == nil)
        #expect(try docId(["name": "Wine", "docId": "cat-9"]) == "cat-9")
    }

    @Test func unknownKeysInsideDiscountAreIgnored() throws {
        let d: Raw = merged(Self.rows[2].discount.mapValues { $0 as Any }, ["note": "x"])
        #expect(decode(d)?.grouped != nil)
    }
}
