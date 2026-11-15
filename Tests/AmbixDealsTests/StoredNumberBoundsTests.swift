import Foundation
import Testing

@testable import AmbixDeals

/// The stored-number bounds `Deal`'s decode applies to every promotion it reads.
///
/// The rule under test: a money figure or a count that lies outside what any promotion editor
/// accepts (the Portal composer and `DealDraft` share the same bounds) makes THAT discount
/// dormant (`.unsupported(kind:)`, which the engine never fires and the Studio never edits),
/// while the deal document itself still decodes and still lists. Every in-range value decodes
/// to exactly what it always did.

// MARK: - Fixtures

private func dealJSON(discount: String, memberDiscount: String? = nil, condition: String? = nil) -> Data {
    var fields = [
        #""id":"d1""#,
        #""name":"Stored numbers""#,
        #""isActive":true"#,
        #""scope":{"type":"all","ids":null}"#,
        "\"discount\":\(discount)",
    ]
    if let memberDiscount { fields.append("\"memberDiscount\":\(memberDiscount)") }
    if let condition { fields.append("\"condition\":\(condition)") }
    return Data("{\(fields.joined(separator: ","))}".utf8)
}

private func decoded(discount: String, memberDiscount: String? = nil, condition: String? = nil) throws -> Deal {
    try JSONDecoder().decode(
        Deal.self,
        from: dealJSON(discount: discount, memberDiscount: memberDiscount, condition: condition)
    )
}

/// One stored discount and the `kind` it must keep when it goes dormant.
struct StoredDiscountCase: Sendable, CustomTestStringConvertible {
    let label: String
    let json: String
    let kind: String

    var testDescription: String { label }
}

// MARK: - Money

@Suite("Stored numbers — money outside $0.00...$100,000.00 makes the discount dormant")
struct StoredMoneyBoundsTests {

    static let outOfRange: [StoredDiscountCase] = [
        StoredDiscountCase(
            label: "fixedPrice far below zero",
            json: #"{"kind":"fixedPrice","price":-92233720368547758}"#, kind: "fixedPrice"),
        StoredDiscountCase(
            label: "fixedPrice 1e20",
            json: #"{"kind":"fixedPrice","price":1e20}"#, kind: "fixedPrice"),
        StoredDiscountCase(
            label: "fixedPrice one cent over the ceiling",
            json: #"{"kind":"fixedPrice","price":100000.01}"#, kind: "fixedPrice"),
        StoredDiscountCase(
            label: "fixedPrice -0.01",
            json: #"{"kind":"fixedPrice","price":-0.01}"#, kind: "fixedPrice"),
        StoredDiscountCase(
            label: "tieredQty tier unitPrice far below zero",
            json: #"{"kind":"tieredQty","tiers":[{"minQty":2,"unitPrice":9.99},{"minQty":6,"unitPrice":-92233720368547758}]}"#,
            kind: "tieredQty"),
        StoredDiscountCase(
            label: "flatAmountOff 1e20",
            json: #"{"kind":"flatAmountOff","amount":1e20}"#, kind: "flatAmountOff"),
        StoredDiscountCase(
            label: "unlockAmountOffCart 1e20",
            json: #"{"kind":"unlockAmountOffCart","amount":1e20}"#, kind: "unlockAmountOffCart"),
        StoredDiscountCase(
            label: "bundle bundlePrice -1",
            json: #"{"kind":"bundle","components":[{"productId":"a","qty":1},{"productId":"b","qty":1}],"bundlePrice":-1}"#,
            kind: "bundle"),
    ]

    @Test("an out-of-range stored price makes the discount dormant and the deal still decodes",
          arguments: outOfRange)
    func outOfRangeMoneyIsDormant(_ storedCase: StoredDiscountCase) throws {
        let deal = try decoded(discount: storedCase.json)
        #expect(deal.id == "d1")
        #expect(deal.isActive)
        #expect(deal.scope == .all)
        #expect(deal.discount == .unsupported(kind: storedCase.kind))
        #expect(deal.groupedKind == nil)
    }

    @Test("the bounds are inclusive: $100,000.00 and $0.00 keep their exact values")
    func boundsAreInclusive() throws {
        #expect(try decoded(discount: #"{"kind":"fixedPrice","price":100000.00}"#).discount
                == .fixedPrice(price: Money(cents: DraftValidation.maxAmountCents)))
        #expect(try decoded(discount: #"{"kind":"fixedPrice","price":0}"#).discount
                == .fixedPrice(price: .zero))
        #expect(try decoded(discount: #"{"kind":"flatAmountOff","amount":100000}"#).discount
                == .flatAmountOff(amount: Money(cents: 10_000_000)))
        #expect(try decoded(discount: #"{"kind":"unlockAmountOffCart","amount":0.01}"#).discount
                == .unlockAmountOffCart(amount: Money(cents: 1)))
        #expect(try decoded(discount: #"{"kind":"tieredQty","tiers":[{"minQty":2,"unitPrice":0},{"minQty":6,"unitPrice":100000}]}"#).discount
                == .tieredQty(tiers: [QtyTier(minQty: 2, unitPrice: .zero),
                                      QtyTier(minQty: 6, unitPrice: Money(cents: 10_000_000))]))
        #expect(try decoded(discount: #"{"kind":"bundle","components":[{"productId":"a","qty":1},{"productId":"b","qty":2}],"bundlePrice":19.99}"#).discount
                == .bundle(components: [BundleComponent(productId: "a", qty: 1), BundleComponent(productId: "b", qty: 2)],
                           bundlePrice: Money(cents: 1999)))
    }

    @Test("an honest price keeps its exact cent value")
    func honestPriceIsUnchanged() throws {
        #expect(try decoded(discount: #"{"kind":"fixedPrice","price":2.5}"#).discount
                == .fixedPrice(price: Money(cents: 250)))
        #expect(try decoded(discount: #"{"kind":"fixedPrice","price":9.99}"#).discount
                == .fixedPrice(price: Money(cents: 999)))
    }

    @Test("an out-of-range member price makes only the member discount dormant; the base deal stays")
    func outOfRangeMemberPriceKeepsTheBase() throws {
        let deal = try decoded(
            discount: #"{"kind":"fixedPrice","price":4.99}"#,
            memberDiscount: #"{"kind":"fixedPrice","price":-1e17}"#
        )
        #expect(deal.discount == .fixedPrice(price: Money(cents: 499)))
        #expect(deal.memberDiscount == .unsupported(kind: "fixedPrice"))
    }

    @Test("a missing price still fails the decode, exactly as before")
    func missingPriceStillThrows() {
        #expect(throws: DecodingError.self) {
            _ = try decoded(discount: #"{"kind":"fixedPrice"}"#)
        }
    }

    @Test("a stored minSubtotal is held to $0.00...$100,000.00")
    func minSubtotalIsClamped() throws {
        let discount = #"{"kind":"flatPercentOff","percent":10}"#
        #expect(try decoded(discount: discount, condition: #"{"type":"minSubtotal","value":1e20}"#).condition
                == .minSubtotal(Money(cents: DraftValidation.maxAmountCents)))
        #expect(try decoded(discount: discount, condition: #"{"type":"minSubtotal","value":-5}"#).condition
                == .minSubtotal(.zero))
        #expect(try decoded(discount: discount, condition: #"{"type":"minSubtotal","value":25}"#).condition
                == .minSubtotal(Money(cents: 2500)))
        #expect(try decoded(discount: discount, condition: #"{"type":"minSubtotal","value":100000}"#).condition
                == .minSubtotal(Money(cents: 10_000_000)))
    }
}

// MARK: - The documents the real writers produce

/// The register path (`DealDocumentSanitizer.decodeDeal` over the `[String: Any]` the Firestore
/// SDK hands back, numbers as `NSNumber`), fed the documents the two live writers produce.
@Suite("Stored numbers — documents the Portal and the register editor write")
struct StoredNumberWriterDocumentTests {

    /// `encodeDealSave` in the Portal's `dealCodec.ts`: every discount key of the 11-key
    /// vocabulary present, the unused ones `null` (`padDiscount`). `updatedAt` (a server
    /// timestamp) is left out, as the register drops it before decoding.
    private func portalDocument(discount: [String: Any], condition: [String: Any]) -> [String: Any] {
        var padded: [String: Any] = [:]
        for key in ["percent", "amount", "price", "buyQty", "bonusQty", "percentOff", "tiers",
                    "productId", "quantity", "components", "bundlePrice"] {
            padded[key] = NSNull()
        }
        padded.merge(discount) { _, new in new }
        return [
            "id": "p1",
            "name": "Portal deal",
            "isActive": NSNumber(value: true),
            "channel": "both",
            "audience": "any",
            "discount": padded,
            "scope": ["type": "all", "ids": NSNull()] as [String: Any],
            "condition": condition,
            "perCustomerLimit": NSNumber(value: 0),
            "usageLimit": NSNumber(value: 0),
            "schedule": NSNull(),
            "couponCode": NSNull(),
            "marginFloorOverrideCents": NSNull(),
            "print": NSNull(),
        ]
    }

    @Test("a Portal fixed-price deal at the ceiling and an honest one decode to their exact cents")
    func portalMoneyDocumentsDecode() throws {
        let always: [String: Any] = ["type": "always", "value": NSNull()]
        let atCeiling = try #require(DealDocumentSanitizer.decodeDeal(
            portalDocument(discount: ["kind": "fixedPrice", "price": NSNumber(value: 100_000)], condition: always),
            id: "p1"))
        #expect(atCeiling.discount == .fixedPrice(price: Money(cents: 10_000_000)))

        let honest = try #require(DealDocumentSanitizer.decodeDeal(
            portalDocument(
                discount: ["kind": "tieredQty",
                           "tiers": [["minQty": NSNumber(value: 6), "unitPrice": NSNumber(value: 8.99)]]],
                condition: ["type": "minSubtotal", "value": NSNumber(value: 30.5)]),
            id: "p1"))
        #expect(honest.discount == .tieredQty(tiers: [QtyTier(minQty: 6, unitPrice: Money(cents: 899))]))
        #expect(honest.condition == .minSubtotal(Money(cents: 3050)))
    }

    @Test("a stored double far below zero reaches the register path dormant, the deal still listed")
    func storedDoubleFarBelowZeroIsDormant() throws {
        let deal = try #require(DealDocumentSanitizer.decodeDeal(
            portalDocument(
                discount: ["kind": "fixedPrice", "price": NSNumber(value: -92_233_720_368_547_758.0)],
                condition: ["type": "minSubtotal", "value": NSNumber(value: 1e20)]),
            id: "p1"))
        #expect(deal.isActive)
        #expect(deal.discount == .unsupported(kind: "fixedPrice"))
        #expect(deal.condition == .minSubtotal(Money(cents: DraftValidation.maxAmountCents)))
    }

    @Test("Portal count documents at the ceiling decode exactly; a count one over it lists dormant")
    func portalCountDocumentsDecode() throws {
        // `encodeDiscount` writes every count as `Math.trunc(n)`; the iPad SDK hands a stored
        // integer back as an `NSNumber` holding an Int64.
        let always: [String: Any] = ["type": "always", "value": NSNull()]
        func deal(_ discount: [String: Any]) throws -> Deal {
            try #require(DealDocumentSanitizer.decodeDeal(portalDocument(discount: discount, condition: always), id: "p1"))
        }
        #expect(try deal(["kind": "buyXGetYBonus",
                          "buyQty": NSNumber(value: Int64(1_000_000)),
                          "bonusQty": NSNumber(value: Int64(1))]).discount
                == .buyXGetYBonus(buyQty: 1_000_000, bonusQty: 1))
        #expect(try deal(["kind": "buyXGetYPercentOff",
                          "buyQty": NSNumber(value: Int64(2)),
                          "percentOff": NSNumber(value: Int64(50))]).discount
                == .buyXGetYPercentOff(buyQty: 2, percentOff: 50))
        #expect(try deal(["kind": "mixedCase",
                          "tiers": [["minQty": NSNumber(value: Int64(6)), "discountPercent": NSNumber(value: Int64(10))]]]).discount
                == .mixedCase(tiers: [MixedCaseTier(minQty: 6, discountPercent: 10)]))
        let components: [[String: Any]] = [
            ["productId": "a", "qty": NSNumber(value: Int64(1_000_000))],
            ["productId": "b", "qty": NSNumber(value: Int64(2))],
        ]
        #expect(try deal(["kind": "bundle", "components": components, "bundlePrice": NSNumber(value: 19.99)]).discount
                == .bundle(components: [BundleComponent(productId: "a", qty: 1_000_000), BundleComponent(productId: "b", qty: 2)],
                           bundlePrice: Money(cents: 1999)))
        #expect(try deal(["kind": "buyXGetYBonus",
                          "buyQty": NSNumber(value: Int64(2)),
                          "bonusQty": NSNumber(value: Int64(1_000_001))]).discount
                == .unsupported(kind: "buyXGetYBonus"))
    }

    @Test("a register-authored price at the ceiling round-trips to its exact cents")
    func registerAuthoredCeilingRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.discount = .fixedPrice(price: "100000")
        draft.condition = .minSubtotal("100000")
        let deal = try decodedDeal(from: draft)
        #expect(deal.discount == .fixedPrice(price: Money(cents: 10_000_000)))
        #expect(deal.condition == .minSubtotal(Money(cents: 10_000_000)))
    }
}

// MARK: - Counts

@Suite("Stored numbers — a count outside 1...1,000,000 makes the discount dormant")
struct StoredCountBoundsTests {

    static let outOfRange: [StoredDiscountCase] = [
        StoredDiscountCase(
            label: "buyXGetYBonus buyQty 9223372036854775807",
            json: #"{"kind":"buyXGetYBonus","buyQty":9223372036854775807,"bonusQty":1}"#, kind: "buyXGetYBonus"),
        StoredDiscountCase(
            label: "buyXGetYBonus bonusQty 1000001",
            json: #"{"kind":"buyXGetYBonus","buyQty":2,"bonusQty":1000001}"#, kind: "buyXGetYBonus"),
        StoredDiscountCase(
            label: "buyXGetYBonus buyQty 0",
            json: #"{"kind":"buyXGetYBonus","buyQty":0,"bonusQty":1}"#, kind: "buyXGetYBonus"),
        StoredDiscountCase(
            label: "buyXGetYBonus bonusQty -3",
            json: #"{"kind":"buyXGetYBonus","buyQty":2,"bonusQty":-3}"#, kind: "buyXGetYBonus"),
        StoredDiscountCase(
            label: "buyXGetYBonus buyQty 1e20",
            json: #"{"kind":"buyXGetYBonus","buyQty":1e20,"bonusQty":1}"#, kind: "buyXGetYBonus"),
        StoredDiscountCase(
            label: "buyXGetYPercentOff buyQty 9223372036854775807",
            json: #"{"kind":"buyXGetYPercentOff","buyQty":9223372036854775807,"percentOff":50}"#, kind: "buyXGetYPercentOff"),
        StoredDiscountCase(
            label: "buyXGetYPercentOff buyQty 2.5",
            json: #"{"kind":"buyXGetYPercentOff","buyQty":2.5,"percentOff":50}"#, kind: "buyXGetYPercentOff"),
        StoredDiscountCase(
            label: "tieredQty minQty 2000000",
            json: #"{"kind":"tieredQty","tiers":[{"minQty":2,"unitPrice":9.99},{"minQty":2000000,"unitPrice":8.99}]}"#,
            kind: "tieredQty"),
        StoredDiscountCase(
            label: "tieredQty minQty 2.5",
            json: #"{"kind":"tieredQty","tiers":[{"minQty":2.5,"unitPrice":9.99}]}"#, kind: "tieredQty"),
        StoredDiscountCase(
            label: "mixedCase minQty 2000000",
            json: #"{"kind":"mixedCase","tiers":[{"minQty":2000000,"discountPercent":10}]}"#, kind: "mixedCase"),
        StoredDiscountCase(
            label: "mixedCase minQty 1e20",
            json: #"{"kind":"mixedCase","tiers":[{"minQty":6,"discountPercent":5},{"minQty":1e20,"discountPercent":10}]}"#,
            kind: "mixedCase"),
        StoredDiscountCase(
            label: "bundle component qty 2000000",
            json: #"{"kind":"bundle","components":[{"productId":"a","qty":2000000},{"productId":"b","qty":1}],"bundlePrice":19.99}"#,
            kind: "bundle"),
        StoredDiscountCase(
            label: "bundle component qty 2.5",
            json: #"{"kind":"bundle","components":[{"productId":"a","qty":1},{"productId":"b","qty":2.5}],"bundlePrice":19.99}"#,
            kind: "bundle"),
    ]

    @Test("an out-of-range or fractional stored count makes the discount dormant and the deal still decodes",
          arguments: outOfRange)
    func outOfRangeCountIsDormant(_ storedCase: StoredDiscountCase) throws {
        let deal = try decoded(discount: storedCase.json)
        #expect(deal.id == "d1")
        #expect(deal.isActive)
        #expect(deal.discount == .unsupported(kind: storedCase.kind))
    }

    @Test("the ceiling is inclusive: 1,000,000 and 1 keep their exact values")
    func countBoundsAreInclusive() throws {
        #expect(try decoded(discount: #"{"kind":"buyXGetYBonus","buyQty":1000000,"bonusQty":1}"#).discount
                == .buyXGetYBonus(buyQty: 1_000_000, bonusQty: 1))
        #expect(try decoded(discount: #"{"kind":"buyXGetYPercentOff","buyQty":1,"percentOff":50}"#).discount
                == .buyXGetYPercentOff(buyQty: 1, percentOff: 50))
        #expect(try decoded(discount: #"{"kind":"tieredQty","tiers":[{"minQty":1000000,"unitPrice":1}]}"#).discount
                == .tieredQty(tiers: [QtyTier(minQty: 1_000_000, unitPrice: Money(cents: 100))]))
        #expect(try decoded(discount: #"{"kind":"mixedCase","tiers":[{"minQty":6,"discountPercent":10},{"minQty":12.0,"discountPercent":15}]}"#).discount
                == .mixedCase(tiers: [MixedCaseTier(minQty: 6, discountPercent: 10),
                                      MixedCaseTier(minQty: 12, discountPercent: 15)]))
        #expect(try decoded(discount: #"{"kind":"bundle","components":[{"productId":"a","qty":1000000},{"productId":"b","qty":1}],"bundlePrice":5}"#).discount
                == .bundle(components: [BundleComponent(productId: "a", qty: 1_000_000), BundleComponent(productId: "b", qty: 1)],
                           bundlePrice: Money(cents: 500)))
    }

    @Test("a count key absent or not a number still fails the decode, exactly as before",
          arguments: [
            #"{"kind":"buyXGetYBonus","buyQty":2}"#,
            #"{"kind":"buyXGetYBonus","buyQty":"2","bonusQty":1}"#,
            #"{"kind":"buyXGetYPercentOff","buyQty":null,"percentOff":50}"#,
            #"{"kind":"tieredQty","tiers":[{"unitPrice":9.99}]}"#,
            #"{"kind":"mixedCase","tiers":[{"minQty":"6","discountPercent":10}]}"#,
            #"{"kind":"bundle","components":[{"productId":"a"},{"productId":"b","qty":1}],"bundlePrice":5}"#,
          ])
    func missingOrMistypedCountStillThrows(_ discount: String) {
        #expect(throws: DecodingError.self) {
            _ = try decoded(discount: discount)
        }
    }

    @Test("a deal the register editor of an older build saved with a 19-digit count lists dormant")
    func olderRegisterDocumentListsDormant() throws {
        // `DealDraft.mirrorWrite()` of 0.9.0 emitted counts as `.int`; the Firestore SDK hands
        // them back as an `NSNumber` holding an Int64.
        let raw: [String: Any] = [
            "name": "Buy many",
            "isActive": NSNumber(value: true),
            "channel": "both",
            "audience": "any",
            "discount": ["kind": "buyXGetYBonus",
                         "buyQty": NSNumber(value: Int64.max),
                         "bonusQty": NSNumber(value: Int64(1))] as [String: Any],
            "scope": ["type": "all"] as [String: Any],
            "condition": ["type": "always", "value": NSNull()] as [String: Any],
            "perCustomerLimit": NSNumber(value: Int64(0)),
            "usageLimit": NSNumber(value: Int64(0)),
        ]
        let deal = try #require(DealDocumentSanitizer.decodeDeal(raw, id: "r1"))
        #expect(deal.isActive)
        #expect(deal.discount == .unsupported(kind: "buyXGetYBonus"))
    }

    @Test("a register-authored count at the ceiling round-trips to its exact value")
    func registerAuthoredCeilingCountRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.discount = .buyXGetYBonus(buyQty: "1000000", bonusQty: "1")
        #expect(try decodedDeal(from: draft).discount == .buyXGetYBonus(buyQty: 1_000_000, bonusQty: 1))
    }
}
