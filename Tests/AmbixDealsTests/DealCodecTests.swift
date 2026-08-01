import Foundation
import Testing

@testable import AmbixDeals

/// One parameterized case for the "each v1 kind decodes its exact payload" sweep below.
/// (Not `private`: the `@Test` method that takes this as a parameter must be at least as
/// visible as its parameter type.)
struct KindCase: Sendable {
    let label: String
    let json: String
    let expected: DealDiscount
}

/// All 11 v1 (engine-applied) `discount.kind` payload shapes, decoded standalone (no `Deal`
/// wrapper needed — `DealDiscount` decodes on its own). Field names/values are Station's OWN
/// wire convention (see `Deal.swift` doc comment), not ported from POS's synthesized shapes.
private let v1KindCases: [KindCase] = [
    KindCase(label: "flatPercentOff", json: #"{"kind":"flatPercentOff","percent":15}"#,
             expected: .flatPercentOff(percent: 15)),
    KindCase(label: "flatAmountOff", json: #"{"kind":"flatAmountOff","amount":2.50}"#,
             expected: .flatAmountOff(amount: Money(cents: 250))),
    KindCase(label: "fixedPrice", json: #"{"kind":"fixedPrice","price":9.99}"#,
             expected: .fixedPrice(price: Money(cents: 999))),
    KindCase(label: "buyXGetYBonus", json: #"{"kind":"buyXGetYBonus","buyQty":2,"bonusQty":1}"#,
             expected: .buyXGetYBonus(buyQty: 2, bonusQty: 1)),
    KindCase(label: "buyXGetYPercentOff", json: #"{"kind":"buyXGetYPercentOff","buyQty":1,"percentOff":50}"#,
             expected: .buyXGetYPercentOff(buyQty: 1, percentOff: 50)),
    KindCase(
        label: "tieredQty",
        json: #"{"kind":"tieredQty","tiers":[{"minQty":6,"unitPrice":8.99},{"minQty":12,"unitPrice":7.99}]}"#,
        expected: .tieredQty(tiers: [
            QtyTier(minQty: 6, unitPrice: Money(cents: 899)),
            QtyTier(minQty: 12, unitPrice: Money(cents: 799)),
        ])
    ),
    KindCase(
        label: "mixedCase",
        json: #"{"kind":"mixedCase","tiers":[{"minQty":6,"discountPercent":10},{"minQty":12,"discountPercent":20}]}"#,
        expected: .mixedCase(tiers: [
            MixedCaseTier(minQty: 6, discountPercent: 10),
            MixedCaseTier(minQty: 12, discountPercent: 20),
        ])
    ),
    KindCase(label: "unlockBonusProduct", json: #"{"kind":"unlockBonusProduct","productId":"sku-1","quantity":1}"#,
             expected: .unlockBonusProduct(productId: "sku-1", quantity: 1)),
    KindCase(label: "unlockAmountOffCart", json: #"{"kind":"unlockAmountOffCart","amount":15.00}"#,
             expected: .unlockAmountOffCart(amount: Money(cents: 1500))),
    KindCase(label: "unlockPercentOffCart", json: #"{"kind":"unlockPercentOffCart","percent":10}"#,
             expected: .unlockPercentOffCart(percent: 10)),
    KindCase(
        label: "bundle",
        json: #"{"kind":"bundle","components":[{"productId":"a","qty":1},{"productId":"b","qty":2}],"bundlePrice":25.00}"#,
        expected: .bundle(
            components: [BundleComponent(productId: "a", qty: 1), BundleComponent(productId: "b", qty: 2)],
            bundlePrice: Money(cents: 2500)
        )
    ),
]

/// The 9 decode-only (non-v1) `kind` strings from the AmbixServer migration CHECK constraint —
/// schema accepts them, but the engine (later tasks) never fires them.
private let nonV1Kinds = [
    "pointsEarning", "pointsRedemption", "birthdayDiscount", "tierThreshold",
    "doublePoints", "categoryBonus", "welcomeBonus", "visitFrequency", "kanpaiCoupon",
]

/// Builds a minimal-but-valid `Deal` JSON document (only the fields with no decode default —
/// `id`/`name`/`discount` — plus whatever `extraFields` splices in), so each fallback-matrix
/// test only has to state the ONE field it cares about.
private func minimalDealJSON(extraFields: String = "") -> String {
    """
    {"id":"deal-x","name":"Minimal","discount":{"kind":"flatPercentOff","percent":5}\(extraFields)}
    """
}

private func decodeMinimalDeal(extraFields: String = "") throws -> Deal {
    try JSONDecoder().decode(Deal.self, from: Data(minimalDealJSON(extraFields: extraFields).utf8))
}

@Suite("Deal wire codec — happy path, fail-closed scope, fail-open condition, fail-hard audience/channel")
struct DealCodecTests {

    // MARK: - Full happy-path decode (every field, from the brief's canonical JSON)

    @Test("full JSON decodes every Deal field")
    func happyPathDecodesEveryField() throws {
        let json = """
        {"id":"deal-1","name":"Tuesday Wine 15","isActive":true,"channel":"inStore",
         "audience":"any","discount":{"kind":"flatPercentOff","percent":15},
         "scope":{"type":"category","ids":["Wine"]},
         "condition":{"type":"minQuantity","value":6},
         "schedule":{"weekdayMask":4,"dayStartMinute":0,"dayEndMinute":1440,"startDate":"2026-08-01T00:00:00Z"},
         "perCustomerLimit":0,"usageLimit":0}
        """
        let deal = try JSONDecoder().decode(Deal.self, from: Data(json.utf8))

        #expect(deal.id == "deal-1")
        #expect(deal.name == "Tuesday Wine 15")
        #expect(deal.isActive == true)
        #expect(deal.channel == .inStore)
        #expect(deal.audience == .any)
        #expect(deal.discount == .flatPercentOff(percent: 15))
        #expect(deal.memberDiscount == nil)
        #expect(deal.scope == .category(names: ["Wine"]))
        #expect(deal.condition == .minQuantity(6))
        #expect(deal.couponCode == nil)
        #expect(deal.perCustomerLimit == 0)
        #expect(deal.usageLimit == 0)
        #expect(deal.marginFloorOverrideCents == nil)

        let schedule = try #require(deal.schedule)
        #expect(schedule.weekdayMask == 4)
        #expect(schedule.dayStartMinute == 0)
        #expect(schedule.dayEndMinute == 1440)
        #expect(schedule.endDate == nil)
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        #expect(schedule.startDate == plainFormatter.date(from: "2026-08-01T00:00:00Z"))
    }

    // MARK: - Each of the 11 v1 kinds' payload decode (exact field names)

    @Test("each of the 11 v1 kinds decodes its exact payload shape", arguments: v1KindCases)
    func decodesEachV1Kind(_ testCase: KindCase) throws {
        let discount = try JSONDecoder().decode(DealDiscount.self, from: Data(testCase.json.utf8))
        #expect(discount == testCase.expected, "kind: \(testCase.label)")
    }

    // MARK: - The 9 decode-only kinds land in .unsupported, round-tripping the kind string

    @Test(
        "the 9 non-v1 kinds decode fine to .unsupported(kind:), faithfully round-tripping the kind string",
        arguments: nonV1Kinds
    )
    func nonV1KindsDecodeToUnsupported(_ kind: String) throws {
        let json = #"{"kind":"\#(kind)","points":10}"#
        let discount = try JSONDecoder().decode(DealDiscount.self, from: Data(json.utf8))
        #expect(discount == .unsupported(kind: kind))
    }

    @Test("an unrecognized kind string also decodes to .unsupported(kind:), never throws")
    func unknownKindDecodesToUnsupported() throws {
        let json = #"{"kind":"totallyMadeUp","whatever":true}"#
        let discount = try JSONDecoder().decode(DealDiscount.self, from: Data(json.utf8))
        #expect(discount == .unsupported(kind: "totallyMadeUp"))
    }

    // MARK: - Fail-closed scope: garbage/missing scope -> .products([]) MATCH-NOTHING

    @Test("missing scope key falls back to .products([]) — match nothing, never storewide")
    func missingScopeFallsBackToMatchNothing() throws {
        let deal = try decodeMinimalDeal()
        #expect(deal.scope == .products(ids: []))
    }

    @Test("unrecognized scope type falls back to .products([])")
    func garbageScopeTypeFallsBackToMatchNothing() throws {
        let deal = try decodeMinimalDeal(extraFields: #","scope":{"type":"bogus"}"#)
        #expect(deal.scope == .products(ids: []))
    }

    @Test("scope with wrong shape (string instead of object) falls back to .products([])")
    func malformedScopeShapeFallsBackToMatchNothing() throws {
        let deal = try decodeMinimalDeal(extraFields: #","scope":"not-an-object""#)
        #expect(deal.scope == .products(ids: []))
    }

    // MARK: - Fail-open condition: garbage/missing condition -> .always

    @Test("missing condition key falls back to .always")
    func missingConditionFallsBackToAlways() throws {
        let deal = try decodeMinimalDeal()
        #expect(deal.condition == .always)
    }

    @Test("unrecognized condition type falls back to .always")
    func garbageConditionFallsBackToAlways() throws {
        let deal = try decodeMinimalDeal(extraFields: #","condition":{"type":"bogus"}"#)
        #expect(deal.condition == .always)
    }

    @Test("malformed condition value (wrong type) falls back to .always")
    func malformedConditionValueFallsBackToAlways() throws {
        let deal = try decodeMinimalDeal(extraFields: #","condition":{"type":"minQuantity","value":"six"}"#)
        #expect(deal.condition == .always)
    }

    // MARK: - Fail-hard audience/channel: unrecognized string fails the WHOLE decode

    @Test("unrecognized audience string fails the whole decode")
    func unknownAudienceFailsDecode() throws {
        let json = minimalDealJSON(extraFields: #","audience":"vip""#)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Deal.self, from: Data(json.utf8))
        }
    }

    @Test("unrecognized channel string fails the whole decode")
    func unknownChannelFailsDecode() throws {
        let json = minimalDealJSON(extraFields: #","channel":"drivethru""#)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Deal.self, from: Data(json.utf8))
        }
    }

    // MARK: - 9.99 / 33.33 cent-exactness (never a Double round-trip artifact)

    @Test("9.99 decodes to exactly 999 cents")
    func nineNinetyNinePinsExactCents() throws {
        let discount = try JSONDecoder().decode(
            DealDiscount.self, from: Data(#"{"kind":"fixedPrice","price":9.99}"#.utf8)
        )
        #expect(discount == .fixedPrice(price: Money(cents: 999)))
    }

    @Test("33.33 decodes to exactly 3333 cents")
    func thirtyThreeThirtyThreePinsExactCents() throws {
        let discount = try JSONDecoder().decode(
            DealDiscount.self, from: Data(#"{"kind":"flatAmountOff","amount":33.33}"#.utf8)
        )
        #expect(discount == .flatAmountOff(amount: Money(cents: 3333)))
    }

    // MARK: - Schedule ISO with/without fractional seconds

    @Test("schedule startDate parses fractional-seconds ISO")
    func scheduleParsesFractionalSecondsISO() throws {
        let deal = try decodeMinimalDeal(
            extraFields: #","schedule":{"weekdayMask":127,"dayStartMinute":0,"dayEndMinute":1440,"startDate":"2026-08-01T00:00:00.500Z"}"#
        )
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(deal.schedule?.startDate == fractionalFormatter.date(from: "2026-08-01T00:00:00.500Z"))
    }

    @Test("schedule startDate parses plain (non-fractional) ISO")
    func scheduleParsesPlainISO() throws {
        let deal = try decodeMinimalDeal(
            extraFields: #","schedule":{"weekdayMask":127,"dayStartMinute":0,"dayEndMinute":1440,"startDate":"2026-08-01T00:00:00Z"}"#
        )
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        #expect(deal.schedule?.startDate == plainFormatter.date(from: "2026-08-01T00:00:00Z"))
    }

    @Test("schedule with a malformed shape (missing required minute fields) falls back to nil")
    func malformedScheduleFallsBackToNil() throws {
        let deal = try decodeMinimalDeal(extraFields: #","schedule":{"startDate":"2026-08-01T00:00:00Z"}"#)
        #expect(deal.schedule == nil)
    }

    // MARK: - Missing optional fields default

    @Test("""
    missing perCustomerLimit/usageLimit default to 0; missing isActive defaults false; \
    missing channel defaults .both; missing audience defaults .any
    """)
    func missingOptionalFieldsDefault() throws {
        let deal = try decodeMinimalDeal()
        #expect(deal.perCustomerLimit == 0)
        #expect(deal.usageLimit == 0)
        #expect(deal.isActive == false)
        #expect(deal.channel == .both)
        #expect(deal.audience == .any)
        #expect(deal.scope == .products(ids: []))
        #expect(deal.condition == .always)
        #expect(deal.schedule == nil)
        #expect(deal.couponCode == nil)
        #expect(deal.marginFloorOverrideCents == nil)
    }

    // MARK: - marginFloorOverrideCents clamps to max(0, value) at decode (final-review I3)

    @Test("""
    a negative marginFloorOverrideCents clamps to exactly 0 at decode — never round-trips as a \
    raw negative that could inflate a downstream `max(0, lineTotal - floorBasis)` clamp above \
    lineTotal
    """)
    func negativeMarginFloorOverrideClampsToZero() throws {
        let deal = try decodeMinimalDeal(extraFields: #","marginFloorOverrideCents":-1"#)
        #expect(deal.marginFloorOverrideCents == 0)
    }

    @Test("""
    Int.min decodes without trapping and clamps to 0 — pre-fix, an unclamped Int.min would \
    later trap the first time `DealEngine.clampToCostFloor` computed `lineTotal - floorBasis` \
    (signed overflow: any positive lineTotal minus Int.min overflows Int.max)
    """)
    func intMinMarginFloorOverrideDecodesWithoutTrappingAndClampsToZero() throws {
        let deal = try decodeMinimalDeal(extraFields: #","marginFloorOverrideCents":-9223372036854775808"#)
        #expect(deal.marginFloorOverrideCents == 0)
    }

    // MARK: - The MEMBERWISE init also clamps (B-1 final-review carry, closed in Task 1)

    /// The decode path (above) has clamped `marginFloorOverrideCents` to `max(0, value)` since
    /// the B-1 final review, but the memberwise `init(id:name:...)` did NOT — a caller building
    /// a `Deal` directly (rather than through `JSONDecoder`) could still construct one carrying
    /// a raw negative override, silently breaking the "every consumer downstream can trust
    /// `marginFloorOverrideCents >= 0`" invariant the decode-path comment claims. Both
    /// construction paths must now agree.
    @Test("the memberwise init clamps a negative marginFloorOverrideCents to 0, matching decode")
    func memberwiseInitClampsNegativeMarginFloorOverrideToZero() {
        let deal = Deal(
            id: "deal-x", name: "Direct construction", isActive: true,
            channel: .both, audience: .any, discount: .flatPercentOff(percent: 10),
            memberDiscount: nil, scope: .all, condition: .always, schedule: nil,
            couponCode: nil, perCustomerLimit: 0, usageLimit: 0,
            marginFloorOverrideCents: -500
        )
        #expect(deal.marginFloorOverrideCents == 0)
    }

    // MARK: - memberDiscount codec pin

    @Test("memberDiscount decodes to the flatPercentOff case with the exact percent")
    func memberDiscountDecodesToFlatPercentOff() throws {
        let deal = try decodeMinimalDeal(
            extraFields: #","memberDiscount":{"kind":"flatPercentOff","percent":20}"#
        )
        #expect(deal.memberDiscount == .flatPercentOff(percent: 20))
    }

    @Test("memberDiscount is nil when absent from the doc")
    func memberDiscountNilWhenAbsent() throws {
        let deal = try decodeMinimalDeal()
        #expect(deal.memberDiscount == nil)
    }
}
