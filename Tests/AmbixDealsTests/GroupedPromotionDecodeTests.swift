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
        let kind: GroupedPromotionKind
        let mode: GroupedPromotionMode
        let discount: [String: any Sendable]
        let cents: Int?
        let percent: Int?
        let unitCount: Int?
        let groupSize: Int?
        var testDescription: String { "\(kind.rawValue)/\(mode.rawValue)" }
    }

    private static let t: [String: any Sendable] = [
        "productIds": ["p1"], "categories": [[String: any Sendable]](),
        "allProducts": false, "excludedProductIds": [String](),
    ]

    static let rows: [Row] = [
        Row(kind: .itemOffer, mode: .salePrice,
            discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 899, "unitCount": 6, "targets": t],
            cents: 899, percent: nil, unitCount: 6, groupSize: nil),
        Row(kind: .itemOffer, mode: .amountOff,
            discount: ["kind": "itemOffer", "mode": "amountOff", "cents": 150, "unitCount": 1, "targets": t],
            cents: 150, percent: nil, unitCount: 1, groupSize: nil),
        Row(kind: .itemOffer, mode: .percentOff,
            discount: ["kind": "itemOffer", "mode": "percentOff", "percent": 15, "targets": t],
            cents: nil, percent: 15, unitCount: nil, groupSize: nil),
        Row(kind: .quantityGroup, mode: .percentOff,
            discount: ["kind": "quantityGroup", "mode": "percentOff", "percent": 10, "groupSize": 3,
                       "targets": t, "perPurchaseCap": 4],
            cents: nil, percent: 10, unitCount: nil, groupSize: 3),
        Row(kind: .quantityGroup, mode: .fixedTotal,
            discount: ["kind": "quantityGroup", "mode": "fixedTotal", "cents": 2000, "unitCount": 1,
                       "groupSize": 2, "targets": t],
            cents: 2000, percent: nil, unitCount: 1, groupSize: 2),
        Row(kind: .mixGroup, mode: .percentOff,
            discount: ["kind": "mixGroup", "mode": "percentOff", "percent": 20, "groupSize": 4, "targets": t],
            cents: nil, percent: 20, unitCount: nil, groupSize: 4),
        Row(kind: .mixGroup, mode: .fixedTotal,
            discount: ["kind": "mixGroup", "mode": "fixedTotal", "cents": 3000, "unitCount": 2,
                       "groupSize": 5, "targets": t],
            cents: 3000, percent: nil, unitCount: 2, groupSize: 5),
        Row(kind: .buyGetGroup, mode: .percentOff,
            discount: ["kind": "buyGetGroup", "mode": "percentOff", "percent": 50, "buyQuantity": 2,
                       "getQuantity": 1, "targets": t],
            cents: nil, percent: 50, unitCount: nil, groupSize: nil),
        Row(kind: .slotBundle, mode: .fixedTotal,
            discount: ["kind": "slotBundle", "mode": "fixedTotal", "cents": 4500,
                       "slots": [["label": "Wine", "quantity": 1, "unitCount": 1, "targets": t]]],
            cents: 4500, percent: nil, unitCount: nil, groupSize: nil),
    ]

    @Test(arguments: rows)
    func everyKindAndModeInTheTableDecodes(_ row: Row) throws {
        let deal = try #require(decode(row.discount))
        #expect(deal.discount == .unsupported(kind: row.kind.rawValue))
        let g = try #require(deal.grouped)
        #expect(g.kind == row.kind)
        #expect(g.mode == row.mode)
        #expect(g.cents == row.cents)
        #expect(g.percent == row.percent)
        #expect(g.unitCount == row.unitCount)
        #expect(g.groupSize == row.groupSize)
        if row.kind == .slotBundle {
            #expect(g.targets == nil)
            #expect(g.slots?.count == 1)
            #expect(g.slots?.first?.label == "Wine")
            #expect(g.slots?.first?.targets.productIds == ["p1"])
        } else {
            #expect(g.slots == nil)
            #expect(g.targets?.productIds == ["p1"])
        }
        if row.kind == .quantityGroup, row.mode == .percentOff {
            #expect(g.perPurchaseCap == 4)
        } else {
            #expect(g.perPurchaseCap == nil)
        }
    }

    @Test func buyGetFieldsDecode() throws {
        let g = try #require(decode(Self.rows[7].discount)?.grouped)
        #expect(g.buyQuantity == 2)
        #expect(g.getQuantity == 1)
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
