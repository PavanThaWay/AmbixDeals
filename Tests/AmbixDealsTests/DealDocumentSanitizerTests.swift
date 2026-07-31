import Foundation
import Testing

@testable import AmbixDeals

/// A JSON-based test CANNOT catch the defect this suite exists for: `JSONDecoder` reading the
/// TEXT `33.33` yields an exact `Decimal`, so the whole corruption is invisible from a string
/// fixture. The bug only appears once a value crosses the `NSNumber` boundary the Firestore SDK
/// actually hands back. Every test here therefore starts from a real `NSNumber`, never a JSON
/// literal — that boundary IS the thing under test.
@Suite("DealDocumentSanitizer — the NSNumber -> Decimal reboxing every host must inherit")
struct DealDocumentSanitizerTests {

    /// What a Firestore snapshot dictionary for a percent-off deal actually looks like in
    /// memory: numbers as `NSNumber`, booleans as `CFBoolean`-backed `NSNumber`.
    private func rawDocument(percent: NSNumber) -> [String: Any] {
        [
            "id": "stale-id",
            "name": "Third Off",
            "isActive": NSNumber(value: true),
            "priority": NSNumber(value: 5),
            "discount": ["kind": "flatPercentOff", "percent": percent] as [String: Any],
            "scope": ["type": "all"] as [String: Any],
        ]
    }

    // MARK: - The defect

    @Test("a naive NSNumber -> JSONSerialization bridge corrupts a percent — this is the bug being fixed")
    func naiveBridgeCorruptsPercent() throws {
        let raw = rawDocument(percent: NSNumber(value: 33.33))
        let data = try JSONSerialization.data(withJSONObject: raw)
        let deal = try JSONDecoder().decode(Deal.self, from: data)

        // Documenting the failure, not endorsing it: 33.33 came back as 33.329999999999998.
        #expect(deal.discount != .flatPercentOff(percent: Decimal(string: "33.33")!))
    }

    @Test("the sanitized bridge preserves the percent EXACTLY")
    func sanitizedBridgePreservesPercent() throws {
        let deal = try #require(
            DealDocumentSanitizer.decodeDeal(rawDocument(percent: NSNumber(value: 33.33)), id: "d1")
        )
        #expect(deal.discount == .flatPercentOff(percent: Decimal(string: "33.33")!))
    }

    @Test(
        "every percent magnitude that showed binary noise round-trips exactly",
        arguments: [33.33, 9.99, 99.99, 0.1, 12.5, 1.05, 66.67, 0.01]
    )
    func percentMagnitudesRoundTripExactly(_ value: Double) throws {
        let deal = try #require(
            DealDocumentSanitizer.decodeDeal(rawDocument(percent: NSNumber(value: value)), id: "d1")
        )
        #expect(deal.discount == .flatPercentOff(percent: Decimal(string: String(value))!),
                "percent: \(value)")
    }

    @Test("a mixedCase tier's discountPercent is reboxed too — the sanitize walk is recursive")
    func nestedTierPercentIsReboxed() throws {
        let raw: [String: Any] = [
            "name": "Mixed", "isActive": NSNumber(value: true),
            "discount": [
                "kind": "mixedCase",
                "tiers": [["minQty": NSNumber(value: 6), "discountPercent": NSNumber(value: 33.33)]],
            ] as [String: Any],
        ]
        let deal = try #require(DealDocumentSanitizer.decodeDeal(raw, id: "d1"))
        #expect(deal.discount == .mixedCase(tiers: [
            MixedCaseTier(minQty: 6, discountPercent: Decimal(string: "33.33")!),
        ]))
    }

    // MARK: - What must NOT change

    @Test("a boolean stays a boolean — isActive never becomes 1.0")
    func booleansPassThroughUntouched() throws {
        let active = try #require(DealDocumentSanitizer.decodeDeal(rawDocument(percent: 10), id: "d1"))
        #expect(active.isActive)

        var rawInactive = rawDocument(percent: 10)
        rawInactive["isActive"] = NSNumber(value: false)
        let inactive = try #require(DealDocumentSanitizer.decodeDeal(rawInactive, id: "d1"))
        #expect(!inactive.isActive)

        #expect(DealDocumentSanitizer.sanitizedNumber(NSNumber(value: true)) == NSNumber(value: true))
        #expect(DealDocumentSanitizer.sanitizedNumber(NSNumber(value: false)) == NSNumber(value: false))
    }

    @Test("an integer NSNumber is returned untouched — nothing to lose precision on")
    func integersPassThroughUntouched() {
        for value in [0, 1, -7, 1_440, Int.max, Int.min] {
            let number = NSNumber(value: value)
            #expect(DealDocumentSanitizer.sanitizedNumber(number) === number, "value: \(value)")
        }
    }

    /// `99.99` is the value that exposed the difference between `String(describing: NSNumber)`
    /// (`%0.16g` -> `"99.98999999999999"`) and `String(Double)` (shortest round-trip ->
    /// `"99.99"`). The first reboxes the corruption; only the second removes it.
    @Test("reboxing uses shortest-round-trip formatting, not NSNumber.description's %0.16g")
    func reboxingUsesShortestRoundTrip() {
        let reboxed = DealDocumentSanitizer.sanitizedNumber(NSNumber(value: 99.99))
        #expect(reboxed == NSDecimalNumber(string: "99.99"))
        #expect(String(describing: NSNumber(value: 99.99)) == "99.98999999999999",
                "if this ever changes, the divergence note in DealDocumentSanitizer is stale")
    }

    @Test("a value no Decimal can hold is handed back untouched — reboxing never degrades a field",
          arguments: [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300])
    func unreboxableNumbersFallBack(_ value: Double) {
        let number = NSNumber(value: value)
        #expect(DealDocumentSanitizer.sanitizedNumber(number) === number, "value: \(value)")
    }

    @Test("a money field still lands on the exact cent it always did")
    func moneyIsUnchanged() throws {
        let raw: [String: Any] = [
            "name": "Off", "isActive": NSNumber(value: true),
            "discount": ["kind": "flatAmountOff", "amount": NSNumber(value: 9.99)] as [String: Any],
        ]
        let deal = try #require(DealDocumentSanitizer.decodeDeal(raw, id: "d1"))
        #expect(deal.discount == .flatAmountOff(amount: Money(cents: 999)))
    }

    @Test("strings, nulls and nested arrays survive the walk unchanged")
    func nonNumericValuesSurvive() throws {
        let raw: [String: Any] = [
            "name": "Scoped", "isActive": NSNumber(value: true),
            "couponCode": "SUMMER10",
            "marginFloorOverrideCents": NSNull(),
            "discount": ["kind": "flatPercentOff", "percent": NSNumber(value: 10)] as [String: Any],
            "scope": ["type": "products", "ids": ["sku-1", "sku-2"]] as [String: Any],
        ]
        let deal = try #require(DealDocumentSanitizer.decodeDeal(raw, id: "d1"))
        #expect(deal.couponCode == "SUMMER10")
        #expect(deal.marginFloorOverrideCents == nil)
        #expect(deal.scope == .products(ids: ["sku-1", "sku-2"]))
    }

    // MARK: - Bridge behavior

    @Test("the TRUE document id overrides whatever stale id the body carries")
    func documentIdWins() throws {
        let deal = try #require(DealDocumentSanitizer.decodeDeal(rawDocument(percent: 10), id: "real-id"))
        #expect(deal.id == "real-id")
    }

    @Test("an unserializable document yields nil for that ONE doc, never a throw")
    func unserializableDocumentYieldsNil() {
        // A leftover Firestore Timestamp is the realistic case; `Date` stands in for any value
        // `JSONSerialization` refuses. The host is contracted to convert these first.
        let raw: [String: Any] = [
            "name": "Sched", "isActive": NSNumber(value: true),
            "discount": ["kind": "flatPercentOff", "percent": NSNumber(value: 10)] as [String: Any],
            "schedule": ["weekdayMask": 127, "dayStartMinute": 0, "dayEndMinute": 1_440,
                         "startDate": Date()] as [String: Any],
        ]
        #expect(DealDocumentSanitizer.decodeDeal(raw, id: "d1") == nil)
    }

    @Test("a document Deal.init(from:) fails hard on yields nil, not a partial Deal")
    func failHardFieldYieldsNil() {
        var raw = rawDocument(percent: 10)
        raw["audience"] = "platinum"
        #expect(DealDocumentSanitizer.decodeDeal(raw, id: "d1") == nil)
    }
}
