import Foundation
import Testing

@testable import AmbixDeals

@Suite struct GroupedPromotionPhrasesTests {

    typealias Raw = [String: Any]
    typealias Wire = [String: any Sendable]

    // MARK: - Fixtures

    private static func targets(
        productIds: [String] = ["p1"], categories: [Wire] = [], allProducts: Bool = false,
        excluded: [String] = []
    ) -> Wire {
        [
            "productIds": productIds, "categories": categories,
            "allProducts": allProducts, "excludedProductIds": excluded,
        ]
    }

    private static let t = targets()

    private static func doc(_ discount: Wire) -> Raw {
        [
            "name": "Grouped", "isActive": false, "channel": "inStore", "audience": "any",
            "perCustomerLimit": 0, "usageLimit": 0, "couponCode": NSNull(),
            "marginFloorOverrideCents": NSNull(), "revision": 1,
            "scope": ["type": "products", "ids": [String]()] as Raw,
            "schedule": [
                "weekdayMask": 127, "dayStartMinute": 0, "dayEndMinute": 1440,
                "startDate": NSNull(), "endDate": NSNull(),
            ] as Raw,
            "discount": discount.mapValues { $0 as Any },
        ]
    }

    private static func promotion(_ discount: Wire) throws -> GroupedPromotion {
        let deal = try #require(DealDocumentSanitizer.decodeDeal(doc(discount), id: "p1"))
        return try #require(deal.grouped)
    }

    private static func merged(_ base: Wire, _ extra: Wire) -> Wire {
        base.merging(extra) { _, new in new }
    }

    // MARK: - Offer phrases

    struct Case: Sendable, CustomTestStringConvertible {
        let discount: Wire
        let phrase: String
        var testDescription: String { phrase }
    }

    private static let cases: [Case] = [
        Case(discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 899, "unitCount": 1, "targets": t],
             phrase: "$8.99 each"),
        Case(discount: ["kind": "itemOffer", "mode": "amountOff", "cents": 100, "unitCount": 1, "targets": t],
             phrase: "$1.00 off each"),
        Case(discount: ["kind": "itemOffer", "mode": "percentOff", "percent": 10, "targets": t],
             phrase: "10% off each"),
        Case(discount: ["kind": "quantityGroup", "mode": "percentOff", "percent": 10, "groupSize": 3, "targets": t],
             phrase: "Buy 3 of the same product, 10% off"),
        Case(discount: ["kind": "quantityGroup", "mode": "fixedTotal", "cents": 2500, "unitCount": 1,
                        "groupSize": 3, "targets": t],
             phrase: "3 of the same product for $25.00"),
        Case(discount: ["kind": "mixGroup", "mode": "percentOff", "percent": 10, "groupSize": 3, "targets": t],
             phrase: "Any 3 from this group, 10% off"),
        Case(discount: ["kind": "mixGroup", "mode": "fixedTotal", "cents": 2500, "unitCount": 1,
                        "groupSize": 3, "targets": t],
             phrase: "Any 3 from this group for $25.00"),
        Case(discount: ["kind": "buyGetGroup", "mode": "percentOff", "percent": 50, "buyQuantity": 2,
                        "getQuantity": 1, "targets": t],
             phrase: "Buy 2, get 1 50% off \u{B7} same product"),
        Case(discount: bundle(slots: [("Tequila", 1), ("Mixer", 1)], cents: 3500),
             phrase: "1 Tequila + 1 Mixer for $35.00"),
        // A money offer applies to ONE size, so a size above 1 is said (Ruling K).
        Case(discount: ["kind": "itemOffer", "mode": "salePrice", "cents": 899, "unitCount": 6, "targets": t],
             phrase: "$8.99 each \u{B7} 6-pack"),
        Case(discount: ["kind": "itemOffer", "mode": "amountOff", "cents": 300, "unitCount": 30, "targets": t],
             phrase: "$3.00 off each \u{B7} 30-pack"),
        Case(discount: ["kind": "mixGroup", "mode": "fixedTotal", "cents": 2500, "unitCount": 6,
                        "groupSize": 3, "targets": t],
             phrase: "Any 3 from this group for $25.00 \u{B7} 6-pack"),
        Case(discount: ["kind": "quantityGroup", "mode": "fixedTotal", "cents": 2500, "unitCount": 6,
                        "groupSize": 3, "targets": t, "perPurchaseCap": 2],
             phrase: "3 of the same product for $25.00 \u{B7} 6-pack \u{B7} Max 2 per sale"),
        Case(discount: bundleSlots([("Tequila", 2, 1), ("Mixer", 1, 4)], cents: 3500),
             phrase: "2 Tequila + 1 Mixer 4-pack for $35.00"),
        Case(discount: bundleSlots([("Tequila", 1, 1)], cents: 3500, extra: ["perPurchaseCap": 2]),
             phrase: "1 Tequila for $35.00 \u{B7} Max 2 per sale"),
    ]

    private static func bundleSlots(_ slots: [(String, Int, Int)], cents: Int, extra: Wire = [:]) -> Wire {
        let parts: [Wire] = slots.map {
            ["label": $0.0, "quantity": $0.1, "unitCount": $0.2, "targets": t]
        }
        return merged(["kind": "slotBundle", "mode": "fixedTotal", "cents": cents, "slots": parts], extra)
    }

    private static func bundle(slots: [(String, Int)], cents: Int = 3500, extra: Wire = [:]) -> Wire {
        let parts: [Wire] = slots.map {
            ["label": $0.0, "quantity": $0.1, "unitCount": 1, "targets": t]
        }
        return merged(["kind": "slotBundle", "mode": "fixedTotal", "cents": cents, "slots": parts], extra)
    }

    @Test(arguments: cases)
    func offerPhraseForEveryKindAndMode(_ c: Case) throws {
        #expect(try Self.promotion(c.discount).offerPhrase == c.phrase)
    }

    @Test func capAddsMaxPerSale() throws {
        let d: Wire = ["kind": "quantityGroup", "mode": "percentOff", "percent": 10, "groupSize": 3,
                       "targets": Self.t, "perPurchaseCap": 2]
        #expect(try Self.promotion(d).offerPhrase == "Buy 3 of the same product, 10% off \u{B7} Max 2 per sale")
    }

    @Test func moneyUsesThousandsCommasAndTwoCentDigits() throws {
        let expected: [(Int, String)] = [
            (5, "$0.05"), (100, "$1.00"), (1_234_567, "$12,345.67"), (10_000_000, "$100,000.00"),
        ]
        for (cents, text) in expected {
            let d: Wire = ["kind": "itemOffer", "mode": "salePrice", "cents": cents, "unitCount": 1,
                           "targets": Self.t]
            #expect(try Self.promotion(d).offerPhrase == "\(text) each")
        }
    }

    // MARK: - Target phrases

    private func offer(_ targets: Wire) -> Wire {
        ["kind": "itemOffer", "mode": "percentOff", "percent": 10, "targets": targets]
    }

    @Test func targetPhraseForEachSelector() throws {
        let all = Self.targets(productIds: [], allProducts: true)
        #expect(try Self.promotion(offer(all)).targetPhrase == "All products")
        #expect(try Self.promotion(offer(Self.t)).targetPhrase == "1 product")
        let three = Self.targets(productIds: ["a", "b", "c"])
        #expect(try Self.promotion(offer(three)).targetPhrase == "3 products")
        let cats = Self.targets(productIds: [], categories: [["name": "Red"], ["name": "White"]])
        #expect(try Self.promotion(offer(cats)).targetPhrase == "Red, White")
        let b = Self.bundle(slots: [("Tequila", 1), ("Mixer", 1)])
        #expect(try Self.promotion(b).targetPhrase == "2 parts")
        let one = Self.bundle(slots: [("Tequila", 1)])
        #expect(try Self.promotion(one).targetPhrase == "1 part")
    }

    @Test func targetPhraseCountsExclusions() throws {
        let all = Self.targets(productIds: [], allProducts: true, excluded: ["x1", "x2"])
        #expect(try Self.promotion(offer(all)).targetPhrase == "All products \u{B7} 2 excluded")
    }

    @Test func targetPhraseCountsExclusionsForCategoriesAndProductLists() throws {
        let cats = Self.targets(productIds: [], categories: [["name": "Red"], ["name": "White"]],
                                excluded: ["x1", "x2"])
        #expect(try Self.promotion(offer(cats)).targetPhrase == "Red, White \u{B7} 2 excluded")
        let list = Self.targets(productIds: ["a", "b", "c"], excluded: ["b"])
        #expect(try Self.promotion(offer(list)).targetPhrase == "3 products \u{B7} 1 excluded")
    }

    @Test func targetPhraseKeepsCategoryNamesVerbatim() throws {
        let cats = Self.targets(productIds: [], categories: [["name": "Rosé"], ["name": " Red  "]])
        #expect(try Self.promotion(offer(cats)).targetPhrase == "Rosé,  Red  ")
    }

    @Test func displayNamesAreTheFiveBoxes() {
        #expect(GroupedPromotionKind.allCases.map(\.displayName) == [
            "Item discount", "Quantity deal", "Mix & match", "Buy & get", "Bundle",
        ])
    }
}
