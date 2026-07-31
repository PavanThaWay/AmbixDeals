import Foundation
import Testing

@testable import AmbixDeals

// MARK: - FirestoreValue -> Any unwrapper (test-side; NOT `FirestoreValue.jsonObject()`)

/// Bridges a `FirestoreValue` tree into `JSONSerialization`-compatible `Any` for the lockstep
/// round-trip sweep below. Deliberately NOT the existing `FirestoreValue.jsonObject()` (built
/// for the Node fidelity harness) — that method boxes `.double` as a raw Swift `Double`, and
/// `JSONSerialization.data(withJSONObject:)` sometimes re-serializes a raw `Double` with
/// binary-noise digits far beyond its shortest decimal representation (verified empirically on
/// this toolchain: a `Decimal("33.33")`-derived double comes back as the JSON text
/// `33.329999999999998`; `9.99`/`99.99`/`0.1`/`1234.56` show the same corruption, while
/// `12.34`/`7.25`/`0.01`/whole numbers happen to print cleanly — an inconsistent, unsafe split
/// that does NOT correlate with "clean 2-decimal money value"). Reading that noisy text back
/// into a `Decimal` — exactly what `Deal`'s discount/condition decode does — reproduces the
/// corrupted digits verbatim, failing the lockstep invariant for roughly half of all
/// realistic money/percent inputs.
///
/// The fix: box `.double`'s payload as an `NSDecimalNumber` reconstructed from Swift's OWN
/// shortest-round-trip `Double` -> `String` conversion (`String(d)`, which DOES reliably
/// reconstruct `"33.33"` from the double `Decimal("33.33")` produces) rather than the raw
/// `Double` itself — `NSDecimalNumber` serializes via its own exact decimal text, confirmed
/// byte-for-byte lossless through this exact `JSONSerialization` -> `JSONDecoder` pipeline for
/// every money/percent magnitude this sweep exercises.
///
/// NOT `private`: `WireBoundaryTests.swift` runs its own assertions through this EXACT
/// pipeline, and a second hand-rolled copy of a helper this subtle is precisely how two test
/// files start disagreeing about what the wire says.
func firestoreValueToAny(_ value: FirestoreValue) -> Any {
    switch value {
    case .string(let s):
        return s
    case .int(let i):
        return i
    case .double(let d):
        return NSDecimalNumber(string: String(d))
    case .bool(let b):
        return b
    case .isoString(let date), .timestamp(let date):
        return FirestoreValue.iso8601.string(from: date)
    case .serverTimestamp:
        // Never expected in a DealDraft-authored doc (see `neverEmitsServerTimestamp` below) —
        // rendered as a harmless sentinel rather than crashing, matching
        // `FirestoreValue.jsonObject()`'s own handling of this case.
        return "<serverTimestamp>"
    case .null:
        return NSNull()
    case .array(let values):
        return values.map(firestoreValueToAny)
    case .map(let dict):
        return dict.mapValues(firestoreValueToAny)
    }
}

/// The lockstep pipeline itself: `mirrorWrite().fields` -> `[String: Any]` -> `JSONSerialization`
/// -> `JSONDecoder` -> `Deal`. NOT `private` — shared with `WireBoundaryTests.swift`.
func decodedDeal(from draft: DealDraft) throws -> Deal {
    let fields = draft.mirrorWrite().fields.mapValues(firestoreValueToAny)
    let data = try JSONSerialization.data(withJSONObject: fields)
    return try JSONDecoder().decode(Deal.self, from: data)
}

/// Recursively checks a `FirestoreValue` tree for `.serverTimestamp` — used to assert a
/// `DealDraft`-authored doc never contains one (it always resolves every field itself; there
/// is no server-resolved timestamp anywhere in a Studio-authored deal).
private func containsServerTimestamp(_ value: FirestoreValue) -> Bool {
    switch value {
    case .serverTimestamp:
        return true
    case .array(let values):
        return values.contains(where: containsServerTimestamp)
    case .map(let dict):
        return dict.values.contains(where: containsServerTimestamp)
    default:
        return false
    }
}

// MARK: - Fixtures

/// A minimal, fully-valid draft: `flatPercentOff(10)`, `.all` scope, `.always` condition,
/// schedule disabled, no coupon, zero limits, no margin-floor override. Every validation-matrix
/// test below copies this and mutates ONE thing, so a failing assertion is unambiguously
/// attributable to that one change. NOT `private` — shared with `WireBoundaryTests.swift`.
func validMinimalDraft(id: String = "deal-valid") -> DealDraft {
    var draft = DealDraft(id: id)
    draft.name = "Valid Deal"
    draft.discount = .flatPercentOff(percent: "10")
    return draft
}

/// One parameterized case for the 11-kind lockstep sweep — the `DraftDiscount` a manager
/// authored, and the `DealDiscount` decoding `mirrorWrite()`'s output must produce EXACTLY.
/// Values are the SAME numbers `DealCodecTests.v1KindCases` pins on the decode side, so the
/// encode and decode sweeps stay visibly in lockstep with each other.
struct DraftKindCase: Sendable {
    let label: String
    let discount: DraftDiscount
    let expected: DealDiscount
}

private let v1DraftKindCases: [DraftKindCase] = [
    DraftKindCase(label: "flatPercentOff",
                  discount: .flatPercentOff(percent: "15"),
                  expected: .flatPercentOff(percent: 15)),
    DraftKindCase(label: "flatAmountOff",
                  discount: .flatAmountOff(amount: "2.50"),
                  expected: .flatAmountOff(amount: Money(cents: 250))),
    DraftKindCase(label: "fixedPrice",
                  discount: .fixedPrice(price: "9.99"),
                  expected: .fixedPrice(price: Money(cents: 999))),
    DraftKindCase(label: "buyXGetYBonus",
                  discount: .buyXGetYBonus(buyQty: "2", bonusQty: "1"),
                  expected: .buyXGetYBonus(buyQty: 2, bonusQty: 1)),
    DraftKindCase(label: "buyXGetYPercentOff",
                  discount: .buyXGetYPercentOff(buyQty: "1", percentOff: "50"),
                  expected: .buyXGetYPercentOff(buyQty: 1, percentOff: 50)),
    DraftKindCase(
        label: "tieredQty",
        discount: .tieredQty(tiers: [
            DraftQtyTier(minQty: "6", unitPrice: "8.99"),
            DraftQtyTier(minQty: "12", unitPrice: "7.99"),
        ]),
        expected: .tieredQty(tiers: [
            QtyTier(minQty: 6, unitPrice: Money(cents: 899)),
            QtyTier(minQty: 12, unitPrice: Money(cents: 799)),
        ])
    ),
    DraftKindCase(
        label: "mixedCase",
        discount: .mixedCase(tiers: [
            DraftMixedCaseTier(minQty: "6", discountPercent: "10"),
            DraftMixedCaseTier(minQty: "12", discountPercent: "20"),
        ]),
        expected: .mixedCase(tiers: [
            MixedCaseTier(minQty: 6, discountPercent: 10),
            MixedCaseTier(minQty: 12, discountPercent: 20),
        ])
    ),
    DraftKindCase(label: "unlockBonusProduct",
                  discount: .unlockBonusProduct(productId: "sku-1", quantity: "1"),
                  expected: .unlockBonusProduct(productId: "sku-1", quantity: 1)),
    DraftKindCase(label: "unlockAmountOffCart",
                  discount: .unlockAmountOffCart(amount: "15"),
                  expected: .unlockAmountOffCart(amount: Money(cents: 1_500))),
    DraftKindCase(label: "unlockPercentOffCart",
                  discount: .unlockPercentOffCart(percent: "10"),
                  expected: .unlockPercentOffCart(percent: 10)),
    DraftKindCase(
        label: "bundle",
        discount: .bundle(
            components: [DraftBundleComponent(productId: "a", qty: "1"), DraftBundleComponent(productId: "b", qty: "2")],
            bundlePrice: "25"
        ),
        expected: .bundle(
            components: [BundleComponent(productId: "a", qty: 1), BundleComponent(productId: "b", qty: 2)],
            bundlePrice: Money(cents: 2_500)
        )
    ),
]

@Suite("DealDraft — validation + lockstep wire encoder")
struct DealDraftTests {

    // MARK: - 1. THE LOCKSTEP SWEEP

    @Test(
        "each of the 11 v1 kinds round-trips through mirrorWrite() -> Deal exactly, alongside a full scope/condition/schedule/coupon/limits/floor payload",
        arguments: v1DraftKindCases
    )
    func lockstepSweepAllKinds(_ testCase: DraftKindCase) throws {
        var draft = DealDraft(id: "deal-lockstep-\(testCase.label)")
        draft.name = "  Tuesday Wine 15  "
        draft.isActive = true
        draft.priority = 5
        draft.channel = .inStore
        draft.audience = .member
        draft.discount = testCase.discount
        draft.scope = .category(names: ["Wine", "Beer"])
        draft.condition = .minQuantity("3")
        draft.scheduleEnabled = true
        draft.schedule = DraftSchedule(
            weekdayMask: 4, dayStartMinute: 0, dayEndMinute: 1_440,
            startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: nil
        )
        draft.couponCode = "  summer10  "
        draft.perCustomerLimit = 2
        draft.usageLimit = 100
        draft.marginFloorOverride = Money(cents: 50)

        #expect(draft.canSave, "kind: \(testCase.label) — validationErrors: \(String(describing: draft.validationErrors))")

        let write = draft.mirrorWrite()
        #expect(write.collection == "deals", "kind: \(testCase.label)")
        #expect(write.documentID == draft.id, "kind: \(testCase.label)")

        let deal = try decodedDeal(from: draft)
        #expect(deal.id == draft.id, "kind: \(testCase.label)")
        #expect(deal.name == "Tuesday Wine 15", "kind: \(testCase.label)")
        #expect(deal.isActive == true, "kind: \(testCase.label)")
        #expect(deal.priority == 5, "kind: \(testCase.label)")
        #expect(deal.channel == .inStore, "kind: \(testCase.label)")
        #expect(deal.audience == .member, "kind: \(testCase.label)")
        #expect(deal.discount == testCase.expected, "kind: \(testCase.label)")
        #expect(deal.memberDiscount == nil, "kind: \(testCase.label)")
        #expect(deal.scope == .category(names: ["Beer", "Wine"]), "kind: \(testCase.label)")
        #expect(deal.condition == .minQuantity(3), "kind: \(testCase.label)")

        let schedule = try #require(deal.schedule)
        #expect(schedule.weekdayMask == 4, "kind: \(testCase.label)")
        #expect(schedule.dayStartMinute == 0, "kind: \(testCase.label)")
        #expect(schedule.dayEndMinute == 1_440, "kind: \(testCase.label)")
        #expect(schedule.startDate == Date(timeIntervalSince1970: 1_800_000_000), "kind: \(testCase.label)")
        #expect(schedule.endDate == nil, "kind: \(testCase.label)")

        #expect(deal.couponCode == "SUMMER10", "kind: \(testCase.label)")
        #expect(deal.perCustomerLimit == 2, "kind: \(testCase.label)")
        #expect(deal.usageLimit == 100, "kind: \(testCase.label)")
        #expect(deal.marginFloorOverrideCents == 50, "kind: \(testCase.label)")
    }

    @Test("scope .all round-trips")
    func scopeAllRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.scope = .all
        let deal = try decodedDeal(from: draft)
        #expect(deal.scope == .all)
    }

    @Test("scope .products round-trips with alphabetically-sorted ids regardless of Set insertion order")
    func scopeProductsRoundTripsSorted() throws {
        var draft = validMinimalDraft()
        draft.scope = .products(ids: ["zeta-sku", "alpha-sku", "mike-sku"])
        let deal = try decodedDeal(from: draft)
        #expect(deal.scope == .products(ids: ["alpha-sku", "mike-sku", "zeta-sku"]))
    }

    @Test("scope .category round-trips with alphabetically-sorted names regardless of Set insertion order")
    func scopeCategoryRoundTripsSorted() throws {
        var draft = validMinimalDraft()
        draft.scope = .category(names: ["Zinfandel", "Ale", "Merlot"])
        let deal = try decodedDeal(from: draft)
        #expect(deal.scope == .category(names: ["Ale", "Merlot", "Zinfandel"]))
    }

    @Test("condition .always round-trips")
    func conditionAlwaysRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.condition = .always
        let deal = try decodedDeal(from: draft)
        #expect(deal.condition == .always)
    }

    @Test("condition .minSubtotal round-trips as a dollar Decimal, Money-exact")
    func conditionMinSubtotalRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.condition = .minSubtotal("33.33")
        let deal = try decodedDeal(from: draft)
        #expect(deal.condition == .minSubtotal(Money(cents: 3_333)))
    }

    /// FLIPPED in the final-review fix wave (C1). The old assertion was key ABSENCE, which
    /// under `setData(merge: true)` leaves whatever schedule the stored doc already carried
    /// exactly in place — so turning "Limit to a schedule" OFF was a silent no-op on an
    /// existing deal. An explicit `.null` is what actually clears it; decode is unaffected
    /// (`decodeIfPresent` treats null and absent identically), which the round-trip below pins.
    @Test("schedule disabled -> an explicit null schedule key (clears the stored window) that decodes back to nil")
    func scheduleDisabledEmitsExplicitNull() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = false
        #expect(draft.mirrorWrite().fields["schedule"] == .null)
        let deal = try decodedDeal(from: draft)
        #expect(deal.schedule == nil)
    }

    @Test("schedule enabled without dates -> Deal.schedule present with nil startDate/endDate")
    func scheduleEnabledNoDatesRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        draft.schedule = DraftSchedule(weekdayMask: 62, dayStartMinute: 600, dayEndMinute: 1_080)
        let deal = try decodedDeal(from: draft)
        let schedule = try #require(deal.schedule)
        #expect(schedule.weekdayMask == 62)
        #expect(schedule.dayStartMinute == 600)
        #expect(schedule.dayEndMinute == 1_080)
        #expect(schedule.startDate == nil)
        #expect(schedule.endDate == nil)
    }

    @Test("schedule enabled with both dates -> Deal.schedule dates round-trip exactly")
    func scheduleEnabledWithDatesRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = Date(timeIntervalSince1970: 1_900_000_000)
        draft.schedule = DraftSchedule(startDate: start, endDate: end)
        let deal = try decodedDeal(from: draft)
        let schedule = try #require(deal.schedule)
        #expect(schedule.startDate == start)
        #expect(schedule.endDate == end)
    }

    @Test("mirrorWrite() never emits .serverTimestamp anywhere in its field tree")
    func neverEmitsServerTimestamp() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        draft.couponCode = "code1"
        draft.marginFloorOverride = Money(cents: 10)
        #expect(!containsServerTimestamp(.map(draft.mirrorWrite().fields)))
    }

    // MARK: - 2. Validation matrix (one failing case per Global-Constraints bound)

    @Test("baseline valid draft has zero validation errors and canSave")
    func baselineDraftIsValid() {
        let draft = validMinimalDraft()
        #expect(draft.validationErrors.isEmpty)
        #expect(draft.canSave)
    }

    @Test("empty or whitespace-only name fails with .nameRequired")
    func emptyNameFailsValidation() {
        var draft = validMinimalDraft()
        draft.name = "   "
        #expect(draft.validationErrors.contains(.nameRequired))
        #expect(!draft.canSave)
    }

    @Test("out-of-range or unparseable percent fails with .percentInvalid")
    func percentOutOfRangeFailsValidation() {
        for invalid in ["0", "101", "", "abc", "-5"] {
            var draft = validMinimalDraft()
            draft.discount = .flatPercentOff(percent: invalid)
            #expect(draft.validationErrors.contains(.percentInvalid), "input: \(invalid)")
        }
    }

    @Test("non-positive flatAmountOff.amount fails with .amountInvalid")
    func nonPositiveAmountFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .flatAmountOff(amount: "0")
        #expect(draft.validationErrors.contains(.amountInvalid))
    }

    @Test("non-positive fixedPrice.price fails with .amountInvalid")
    func nonPositiveFixedPriceFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .fixedPrice(price: "-1")
        #expect(draft.validationErrors.contains(.amountInvalid))
    }

    @Test("buyXGetYBonus.buyQty < 1 fails with .buyQtyInvalid")
    func buyQtyBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .buyXGetYBonus(buyQty: "0", bonusQty: "1")
        #expect(draft.validationErrors.contains(.buyQtyInvalid))
    }

    @Test("buyXGetYBonus.bonusQty < 1 fails with .bonusQtyInvalid")
    func bonusQtyBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .buyXGetYBonus(buyQty: "1", bonusQty: "0")
        #expect(draft.validationErrors.contains(.bonusQtyInvalid))
    }

    @Test("empty tiers list fails with .tiersEmpty for both tieredQty and mixedCase")
    func emptyTiersFailsValidation() {
        var tieredDraft = validMinimalDraft()
        tieredDraft.discount = .tieredQty(tiers: [])
        #expect(tieredDraft.validationErrors.contains(.tiersEmpty))

        var mixedDraft = validMinimalDraft()
        mixedDraft.discount = .mixedCase(tiers: [])
        #expect(mixedDraft.validationErrors.contains(.tiersEmpty))
    }

    @Test("a tieredQty tier's minQty < 1 fails with .tierMinQtyInvalid")
    func tierMinQtyBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .tieredQty(tiers: [DraftQtyTier(minQty: "0", unitPrice: "5")])
        #expect(draft.validationErrors.contains(.tierMinQtyInvalid))
    }

    @Test("a tieredQty tier's non-positive unitPrice fails with .tierUnitPriceInvalid")
    func tierUnitPriceNonPositiveFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .tieredQty(tiers: [DraftQtyTier(minQty: "1", unitPrice: "0")])
        #expect(draft.validationErrors.contains(.tierUnitPriceInvalid))
    }

    @Test("a mixedCase tier's discountPercent out of range fails with .percentInvalid")
    func mixedCaseTierPercentOutOfRangeFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .mixedCase(tiers: [DraftMixedCaseTier(minQty: "1", discountPercent: "101")])
        #expect(draft.validationErrors.contains(.percentInvalid))
    }

    @Test("fewer than 2 bundle components fails with .bundleNeedsTwoDistinctProducts")
    func bundleTooFewComponentsFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .bundle(components: [DraftBundleComponent(productId: "a", qty: "1")], bundlePrice: "10")
        #expect(draft.validationErrors.contains(.bundleNeedsTwoDistinctProducts))
    }

    @Test("duplicate bundle component productIds fail with .bundleNeedsTwoDistinctProducts")
    func bundleDuplicateProductIdsFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .bundle(
            components: [DraftBundleComponent(productId: "a", qty: "1"), DraftBundleComponent(productId: "a", qty: "2")],
            bundlePrice: "10"
        )
        #expect(draft.validationErrors.contains(.bundleNeedsTwoDistinctProducts))
    }

    @Test("a bundle component's qty < 1 fails with .bundleComponentQtyInvalid")
    func bundleComponentQtyBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .bundle(
            components: [DraftBundleComponent(productId: "a", qty: "0"), DraftBundleComponent(productId: "b", qty: "1")],
            bundlePrice: "10"
        )
        #expect(draft.validationErrors.contains(.bundleComponentQtyInvalid))
    }

    @Test("non-positive bundlePrice fails with .amountInvalid")
    func bundlePriceNonPositiveFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .bundle(
            components: [DraftBundleComponent(productId: "a", qty: "1"), DraftBundleComponent(productId: "b", qty: "1")],
            bundlePrice: "0"
        )
        #expect(draft.validationErrors.contains(.amountInvalid))
    }

    @Test("unlockBonusProduct.quantity < 1 fails with .unlockBonusProductQuantityInvalid")
    func unlockBonusProductQuantityBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .unlockBonusProduct(productId: "sku-1", quantity: "0")
        #expect(draft.validationErrors.contains(.unlockBonusProductQuantityInvalid))
    }

    @Test("unlockBonusProduct with no product picked fails with .unlockBonusProductMissing")
    func unlockBonusProductMissingProductFailsValidation() {
        var draft = validMinimalDraft()
        draft.discount = .unlockBonusProduct(productId: "   ", quantity: "1")
        #expect(draft.validationErrors.contains(.unlockBonusProductMissing))
    }

    @Test("category scope with zero names fails with .categoryScopeEmpty")
    func categoryScopeEmptyFailsValidation() {
        var draft = validMinimalDraft()
        draft.scope = .category(names: [])
        #expect(draft.validationErrors.contains(.categoryScopeEmpty))
    }

    @Test("products scope with zero ids fails with .productsScopeEmpty")
    func productsScopeEmptyFailsValidation() {
        var draft = validMinimalDraft()
        draft.scope = .products(ids: [])
        #expect(draft.validationErrors.contains(.productsScopeEmpty))
    }

    @Test("all-products scope is always valid")
    func allScopeIsAlwaysValid() {
        var draft = validMinimalDraft()
        draft.scope = .all
        #expect(draft.validationErrors.isEmpty)
    }

    @Test("condition minQuantity < 1 fails with .conditionMinQuantityInvalid")
    func conditionMinQuantityBelowOneFailsValidation() {
        var draft = validMinimalDraft()
        draft.condition = .minQuantity("0")
        #expect(draft.validationErrors.contains(.conditionMinQuantityInvalid))
    }

    @Test("condition minSubtotal <= 0 fails with .conditionMinSubtotalInvalid")
    func conditionMinSubtotalNonPositiveFailsValidation() {
        var draft = validMinimalDraft()
        draft.condition = .minSubtotal("0")
        #expect(draft.validationErrors.contains(.conditionMinSubtotalInvalid))
    }

    @Test("schedule with dayStartMinute >= dayEndMinute fails with .scheduleWindowInvalid")
    func scheduleWindowInvalidFailsValidation() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        draft.schedule = DraftSchedule(dayStartMinute: 900, dayEndMinute: 800)
        #expect(draft.validationErrors.contains(.scheduleWindowInvalid))
    }

    @Test("schedule with endDate not after startDate fails with .scheduleDateRangeInvalid")
    func scheduleDateRangeInvalidFailsValidation() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        let earlier = Date(timeIntervalSince1970: 1_000_000_000)
        draft.schedule = DraftSchedule(startDate: later, endDate: earlier)
        #expect(draft.validationErrors.contains(.scheduleDateRangeInvalid))
    }

    @Test("a disabled schedule's own invalid ordering is never checked")
    func disabledScheduleOrderingIsNeverChecked() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = false
        draft.schedule = DraftSchedule(dayStartMinute: 900, dayEndMinute: 800)
        #expect(!draft.validationErrors.contains(.scheduleWindowInvalid))
        #expect(draft.canSave)
    }

    @Test("negative perCustomerLimit fails with .perCustomerLimitNegative")
    func negativePerCustomerLimitFailsValidation() {
        var draft = validMinimalDraft()
        draft.perCustomerLimit = -1
        #expect(draft.validationErrors.contains(.perCustomerLimitNegative))
    }

    @Test("negative usageLimit fails with .usageLimitNegative")
    func negativeUsageLimitFailsValidation() {
        var draft = validMinimalDraft()
        draft.usageLimit = -1
        #expect(draft.validationErrors.contains(.usageLimitNegative))
    }

    @Test("negative marginFloorOverride fails with .marginFloorOverrideNegative")
    func negativeMarginFloorOverrideFailsValidation() {
        var draft = validMinimalDraft()
        draft.marginFloorOverride = Money(cents: -1)
        #expect(draft.validationErrors.contains(.marginFloorOverrideNegative))
    }

    @Test("nil marginFloorOverride is always valid")
    func nilMarginFloorOverrideIsValid() {
        var draft = validMinimalDraft()
        draft.marginFloorOverride = nil
        #expect(!draft.validationErrors.contains(.marginFloorOverrideNegative))
    }

    // MARK: - 3. init(from:) seeding round-trip (one per structural family)

    @Test("seeding round-trip: simple leaf-field family (flatPercentOff), category scope, minQuantity condition, schedule with dates, coupon, limits, floor")
    func seedingRoundTripSimpleFamily() throws {
        let original = Deal(
            id: "deal-seed-a",
            name: "Seed A",
            isActive: false,
            priority: 7,
            channel: .online,
            audience: .wholesale,
            discount: .flatPercentOff(percent: 25),
            memberDiscount: nil,
            scope: .category(names: ["Beer", "Wine"]),
            condition: .minQuantity(4),
            schedule: DealSchedule(
                weekdayMask: 62, dayStartMinute: 480, dayEndMinute: 1_200,
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            couponCode: "SPRING5",
            perCustomerLimit: 3,
            usageLimit: 50,
            marginFloorOverrideCents: 200
        )

        let draft = try #require(DealDraft(from: original))
        #expect(draft.canSave, "validationErrors: \(String(describing: draft.validationErrors))")

        let roundTripped = try decodedDeal(from: draft)
        #expect(roundTripped == original)
    }

    @Test("seeding round-trip: tier-list family (tieredQty), products scope, minSubtotal condition, no schedule")
    func seedingRoundTripTierListFamily() throws {
        let original = Deal(
            id: "deal-seed-b",
            name: "Seed B",
            isActive: true,
            priority: 0,
            channel: .both,
            audience: .any,
            discount: .tieredQty(tiers: [
                QtyTier(minQty: 6, unitPrice: Money(cents: 899)),
                QtyTier(minQty: 12, unitPrice: Money(cents: 799)),
            ]),
            memberDiscount: nil,
            scope: .products(ids: ["sku-a", "sku-b"]),
            condition: .minSubtotal(Money(cents: 2_500)),
            schedule: nil,
            couponCode: nil,
            perCustomerLimit: 0,
            usageLimit: 0,
            marginFloorOverrideCents: nil
        )

        let draft = try #require(DealDraft(from: original))
        #expect(draft.canSave, "validationErrors: \(String(describing: draft.validationErrors))")

        let roundTripped = try decodedDeal(from: draft)
        #expect(roundTripped == original)
    }

    @Test("seeding round-trip: component-list family (bundle), all scope, always condition, schedule without dates")
    func seedingRoundTripComponentListFamily() throws {
        let original = Deal(
            id: "deal-seed-c",
            name: "Seed C",
            isActive: true,
            priority: 2,
            channel: .inStore,
            audience: .member,
            discount: .bundle(
                components: [BundleComponent(productId: "a", qty: 1), BundleComponent(productId: "b", qty: 2)],
                bundlePrice: Money(cents: 2_500)
            ),
            memberDiscount: nil,
            scope: .all,
            condition: .always,
            schedule: DealSchedule(weekdayMask: 127, dayStartMinute: 0, dayEndMinute: 1_440, startDate: nil, endDate: nil),
            couponCode: nil,
            perCustomerLimit: 1,
            usageLimit: 10,
            marginFloorOverrideCents: 0
        )

        let draft = try #require(DealDraft(from: original))
        #expect(draft.canSave, "validationErrors: \(String(describing: draft.validationErrors))")

        let roundTripped = try decodedDeal(from: draft)
        #expect(roundTripped == original)
    }

    @Test("seeding round-trip: cart-unlock family (unlockBonusProduct), category scope, minQuantity condition, coupon, limits, floor")
    func seedingRoundTripCartUnlockFamily() throws {
        let original = Deal(
            id: "deal-seed-d",
            name: "Seed D",
            isActive: false,
            priority: 1,
            channel: .online,
            audience: .senior,
            discount: .unlockBonusProduct(productId: "sku-reward", quantity: 2),
            memberDiscount: nil,
            scope: .category(names: ["Snacks"]),
            condition: .minQuantity(1),
            schedule: nil,
            couponCode: "WELCOME",
            perCustomerLimit: 5,
            usageLimit: 25,
            marginFloorOverrideCents: 100
        )

        let draft = try #require(DealDraft(from: original))
        #expect(draft.canSave, "validationErrors: \(String(describing: draft.validationErrors))")

        let roundTripped = try decodedDeal(from: draft)
        #expect(roundTripped == original)
    }

    /// The Studio has no view/edit access to `memberDiscount` in v1 (see `DealDraft`'s own type
    /// doc comment) — `mirrorWrite()` never emits a `memberDiscount` key. That is SAFE, not
    /// lossy: every `MirrorWrite` in this codebase is written via `FirestoreRelay.apply`'s
    /// `setData(fields, merge: true)` (`App/Firebase/FirestoreRelay.swift:53`), and Firestore's
    /// `merge: true` leaves a top-level key ABSENT from the payload untouched on the stored
    /// doc — the same property `DealActiveUpdate` relies on to touch only `isActive`. The
    /// load-bearing assertion here is therefore key ABSENCE (never `.null`, which under
    /// `merge: true` WOULD clear the existing field) — checked directly on the wire fields, not
    /// inferred from decoding the payload in isolation (a decode of just this write's own
    /// fields can never observe what a merge onto an existing doc preserves).
    @Test("seeding a deal with a memberDiscount never emits a memberDiscount key — merge:true means it survives untouched, never dropped")
    func seedingWithMemberDiscountOmitsKeyEntirely() throws {
        let original = Deal(
            id: "deal-seed-e",
            name: "Seed E",
            isActive: true,
            priority: 0,
            channel: .both,
            audience: .member,
            discount: .flatPercentOff(percent: 10),
            memberDiscount: .flatPercentOff(percent: 20),
            scope: .all,
            condition: .always,
            schedule: nil,
            couponCode: nil,
            perCustomerLimit: 0,
            usageLimit: 0,
            marginFloorOverrideCents: nil
        )

        let draft = try #require(DealDraft(from: original))
        #expect(draft.canSave)
        #expect(draft.mirrorWrite().fields["memberDiscount"] == nil)
    }

    // MARK: - 4. Coupon normalization

    @Test("coupon code is trimmed and uppercased at save")
    func couponNormalizedAtSave() throws {
        var draft = validMinimalDraft()
        draft.couponCode = "  summer10  "
        let deal = try decodedDeal(from: draft)
        #expect(deal.couponCode == "SUMMER10")
    }

    /// FLIPPED in the final-review fix wave (C1) — see `scheduleDisabledEmitsExplicitNull`
    /// for the reasoning. Clearing a coupon is how a manager makes a promo auto-apply; under
    /// key absence the deal stayed coupon-gated and silently never fired.
    @Test("empty coupon code emits an explicit null (clears the stored code) that decodes back to nil")
    func emptyCouponEmitsExplicitNull() throws {
        var draft = validMinimalDraft()
        draft.couponCode = ""
        #expect(draft.mirrorWrite().fields["couponCode"] == .null)
        let deal = try decodedDeal(from: draft)
        #expect(deal.couponCode == nil)
    }

    @Test("whitespace-only coupon code is treated as empty and emits an explicit null")
    func whitespaceOnlyCouponEmitsExplicitNull() throws {
        var draft = validMinimalDraft()
        draft.couponCode = "   "
        #expect(draft.mirrorWrite().fields["couponCode"] == .null)
        let deal = try decodedDeal(from: draft)
        #expect(deal.couponCode == nil)
    }

    // MARK: - 5. DealActiveUpdate

    @Test("DealActiveUpdate emits exactly one field: isActive")
    func dealActiveUpdateEmitsExactlyOneField() {
        let update = DealActiveUpdate(dealId: "deal-1", isActive: true)
        let write = update.mirrorWrite()
        #expect(write.collection == "deals")
        #expect(write.documentID == "deal-1")
        #expect(write.fields.count == 1)
        #expect(write.fields["isActive"] == .bool(true))
    }

    @Test("DealActiveUpdate(isActive: false) round-trips false")
    func dealActiveUpdateFalseRoundTrips() {
        let update = DealActiveUpdate(dealId: "deal-2", isActive: false)
        let write = update.mirrorWrite()
        #expect(write.fields.count == 1)
        #expect(write.fields["isActive"] == .bool(false))
    }

    // MARK: - 6. C1 — a CLEARED optional emits an explicit null (merge:true then really clears)

    /// Read this together with `seedingWithMemberDiscountOmitsKeyEntirely` above — they pin the
    /// two OPPOSITE intents that the C1 defect conflated. A field the Studio OWNS and the
    /// manager CLEARED must emit `.null`, so `setData(merge: true)` overwrites the stored
    /// value; a field the Studio does NOT own must stay ABSENT, so the same merge preserves it.
    @Test("every Studio-owned optional the manager cleared emits an explicit null on the wire")
    func clearedOptionalsEmitExplicitNulls() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = false
        draft.couponCode = ""
        draft.marginFloorOverride = nil

        let fields = draft.mirrorWrite().fields
        #expect(fields["schedule"] == .null)
        #expect(fields["couponCode"] == .null)
        #expect(fields["marginFloorOverrideCents"] == .null)
    }

    @Test("an explicit null decodes exactly like an absent key for every cleared field")
    func explicitNullsDecodeIdenticallyToAbsentKeys() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = false
        draft.couponCode = ""
        draft.marginFloorOverride = nil

        let deal = try decodedDeal(from: draft)
        #expect(deal.schedule == nil)
        #expect(deal.couponCode == nil)
        #expect(deal.marginFloorOverrideCents == nil)
    }

    @Test("a set margin floor still round-trips; only the CLEARED state nulls")
    func marginFloorOverridePresentRoundTrips() throws {
        var draft = validMinimalDraft()
        draft.marginFloorOverride = Money(cents: 250)
        #expect(draft.mirrorWrite().fields["marginFloorOverrideCents"] == .int(250))
        let deal = try decodedDeal(from: draft)
        #expect(deal.marginFloorOverrideCents == 250)
    }

    @Test("a schedule with no start/end date emits explicit null dates that decode back to nil")
    func scheduleWithoutDatesEmitsExplicitNullDates() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        draft.schedule = DraftSchedule(weekdayMask: 62, dayStartMinute: 600, dayEndMinute: 1_080)

        guard case .map(let schedule)? = draft.mirrorWrite().fields["schedule"] else {
            Issue.record("expected a schedule map")
            return
        }
        #expect(schedule["startDate"] == .null)
        #expect(schedule["endDate"] == .null)

        let deal = try decodedDeal(from: draft)
        #expect(deal.schedule?.startDate == nil)
        #expect(deal.schedule?.endDate == nil)
    }

    @Test("turning only the END date off nulls just that key and keeps the start date")
    func scheduleEndDateClearedNullsOnlyThatKey() throws {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        draft.schedule = DraftSchedule(startDate: start, endDate: nil)

        guard case .map(let schedule)? = draft.mirrorWrite().fields["schedule"] else {
            Issue.record("expected a schedule map")
            return
        }
        #expect(schedule["startDate"] == .isoString(start))
        #expect(schedule["endDate"] == .null)

        let deal = try decodedDeal(from: draft)
        #expect(deal.schedule?.startDate == start)
        #expect(deal.schedule?.endDate == nil)
    }

    /// THE C1 BOUNDARY, pinned as a set: `mirrorWrite()` may emit exactly the top-level keys
    /// the Studio owns and NOT ONE MORE. Anything absent from this list (`memberDiscount`
    /// today, whatever Portal adds tomorrow) survives `merge: true` untouched precisely
    /// because it never appears here — nulling one would silently destroy it.
    @Test("mirrorWrite() emits exactly the top-level keys the Studio owns — never a key it doesn't")
    func mirrorWriteEmitsExactlyTheStudioOwnedTopLevelKeys() {
        var draft = validMinimalDraft()
        draft.scheduleEnabled = true
        draft.couponCode = "SAVE5"
        draft.marginFloorOverride = Money(cents: 100)

        let expected: Set<String> = [
            "id", "name", "isActive", "priority", "channel", "audience", "discount", "scope",
            "condition", "perCustomerLimit", "usageLimit", "schedule", "couponCode",
            "marginFloorOverrideCents",
        ]
        #expect(Set(draft.mirrorWrite().fields.keys) == expected)

        // The same key set whether every optional is set or every optional is cleared —
        // a complete doc, not a shape that varies with what the manager filled in.
        var cleared = validMinimalDraft()
        cleared.scheduleEnabled = false
        cleared.couponCode = ""
        cleared.marginFloorOverride = nil
        #expect(Set(cleared.mirrorWrite().fields.keys) == expected)
    }

    // MARK: - 7. I1 — nested maps carry their FULL vocabulary (no stale siblings on a switch)

    /// The complete `discount` payload vocabulary `Deal.swift`'s `DealDiscount.CodingKeys`
    /// knows, minus the `kind` discriminator itself.
    static let discountPayloadKeys = [
        "percent", "amount", "price", "buyQty", "bonusQty", "percentOff",
        "tiers", "productId", "quantity", "components", "bundlePrice",
    ]

    @Test(
        "every kind's discount map carries the full known payload vocabulary — the keys it doesn't use are explicitly null",
        arguments: v1DraftKindCases
    )
    func discountMapIsCompleteForEveryKind(_ testCase: DraftKindCase) throws {
        var draft = validMinimalDraft()
        draft.discount = testCase.discount

        guard case .map(let discount)? = draft.mirrorWrite().fields["discount"] else {
            Issue.record("kind \(testCase.label): expected a discount map")
            return
        }
        for key in Self.discountPayloadKeys {
            #expect(discount[key] != nil,
                    "kind \(testCase.label): '\(key)' absent — a stale sibling would survive merge:true")
        }
        // The padding must not disturb the lockstep: the same draft still decodes exactly.
        let deal = try decodedDeal(from: draft)
        #expect(deal.discount == testCase.expected, "kind: \(testCase.label)")
    }

    /// The concrete failure the padding closes: a deal saved as `tieredQty` and later switched
    /// to `flatPercentOff` must not leave its `tiers` array inside the merged `discount` map.
    @Test("a kind switch nulls the previous shape's payload keys")
    func kindSwitchNullsThePreviousShapesKeys() {
        var draft = validMinimalDraft()
        draft.discount = .flatPercentOff(percent: "15")

        guard case .map(let discount)? = draft.mirrorWrite().fields["discount"] else {
            Issue.record("expected a discount map")
            return
        }
        #expect(discount["kind"] == .string("flatPercentOff"))
        #expect(discount["tiers"] == .null)
        #expect(discount["components"] == .null)
        #expect(discount["bundlePrice"] == .null)
        #expect(discount["productId"] == .null)
        #expect(discount["buyQty"] == .null)
    }

    @Test("scope .all nulls ids so a narrowed-then-widened scope can't keep the old id list")
    func scopeAllNullsTheIdsKey() throws {
        var draft = validMinimalDraft()
        draft.scope = .all

        guard case .map(let scope)? = draft.mirrorWrite().fields["scope"] else {
            Issue.record("expected a scope map")
            return
        }
        #expect(scope["type"] == .string("all"))
        #expect(scope["ids"] == .null)
        #expect(try decodedDeal(from: draft).scope == .all)
    }

    @Test("condition .always nulls the value key")
    func conditionAlwaysNullsTheValueKey() throws {
        var draft = validMinimalDraft()
        draft.condition = .always

        guard case .map(let condition)? = draft.mirrorWrite().fields["condition"] else {
            Issue.record("expected a condition map")
            return
        }
        #expect(condition["type"] == .string("always"))
        #expect(condition["value"] == .null)
        #expect(try decodedDeal(from: draft).condition == .always)
    }

    // MARK: - 8. I2 — money fields have an UPPER bound (overflow can never reach the wire)

    /// The reviewer's own reproduction, both ends of it: the 20-digit paste and the buffer
    /// `Money(dollars:)`'s `Int.max` clamp reformats it into. Under a `> 0`-only rule both
    /// validated fine and `mirrorWrite()` emitted `-9.223372036854776e+16` — a NEGATIVE
    /// `fixedPrice` that traps `DealEngine.fixedPriceSavings` on the first matching ring.
    @Test("a runaway money input is rejected with .amountTooLarge instead of encoding negative cents")
    func runawayMoneyInputIsRejected() {
        for raw in ["99999999999999999999", "92233720368547760.00", "100000.01"] {
            var draft = validMinimalDraft()
            draft.discount = .fixedPrice(price: raw)
            #expect(draft.validationErrors.contains(.amountTooLarge), "input: \(raw)")
            #expect(!draft.canSave, "input: \(raw)")
        }
    }

    @Test("the ceiling itself is valid — the bound is inclusive, not a surprise off-by-one")
    func moneyCeilingIsInclusive() throws {
        var draft = validMinimalDraft()
        draft.discount = .fixedPrice(price: "100000")
        #expect(draft.canSave, "validationErrors: \(String(describing: draft.validationErrors))")
        let deal = try decodedDeal(from: draft)
        #expect(deal.discount == .fixedPrice(price: Money(cents: 10_000_000)))
    }

    @Test("every dollar field shares the ceiling, not just fixedPrice")
    func everyDollarFieldSharesTheCeiling() {
        let tooBig = "99999999999999999999"

        var amountOff = validMinimalDraft()
        amountOff.discount = .flatAmountOff(amount: tooBig)
        #expect(amountOff.validationErrors.contains(.amountTooLarge))

        var cartAmount = validMinimalDraft()
        cartAmount.discount = .unlockAmountOffCart(amount: tooBig)
        #expect(cartAmount.validationErrors.contains(.amountTooLarge))

        var tier = validMinimalDraft()
        tier.discount = .tieredQty(tiers: [DraftQtyTier(minQty: "1", unitPrice: tooBig)])
        #expect(tier.validationErrors.contains(.amountTooLarge))

        var bundle = validMinimalDraft()
        bundle.discount = .bundle(
            components: [DraftBundleComponent(productId: "a", qty: "1"), DraftBundleComponent(productId: "b", qty: "1")],
            bundlePrice: tooBig
        )
        #expect(bundle.validationErrors.contains(.amountTooLarge))

        var subtotal = validMinimalDraft()
        subtotal.condition = .minSubtotal(tooBig)
        #expect(subtotal.validationErrors.contains(.amountTooLarge))

        // The one money field the editor hands over already cents-backed — `Money(dollars:)`
        // clamps a runaway paste to `Int.max` cents, which is POSITIVE and sailed through the
        // old `< 0`-only rule.
        var floor = validMinimalDraft()
        floor.marginFloorOverride = Money(cents: .max)
        #expect(floor.validationErrors.contains(.amountTooLarge))
        #expect(!floor.canSave)
    }

    @Test("an over-cap amount still reports the generic lower-bound error for genuinely bad input")
    func belowBoundInputKeepsItsOwnError() {
        var draft = validMinimalDraft()
        draft.discount = .fixedPrice(price: "0")
        #expect(draft.validationErrors.contains(.amountInvalid))
        #expect(!draft.validationErrors.contains(.amountTooLarge))
    }

    // MARK: - 9. I3 — an unsupported kind has NO draft (never a silent conversion)

    /// A Portal-authored `giftCardTopUp` (or any of the 9 decode-only kinds) previously seeded
    /// a blank `.flatPercentOff("")` draft — so picking a kind and saving rewrote
    /// `discount.kind` and quietly turned someone else's deal into a percent-off deal. There
    /// is no honest draft for a kind this Studio cannot author, so there is no draft at all.
    @Test("DealDraft(from:) refuses an unsupported discount kind instead of converting it to percent-off")
    func unsupportedDiscountKindHasNoDraft() {
        let portalAuthored = Deal(
            id: "deal-unsupported",
            name: "Legacy Gift Card Promo",
            isActive: true,
            priority: 0,
            channel: .both,
            audience: .any,
            discount: .unsupported(kind: "giftCardTopUp"),
            memberDiscount: nil,
            scope: .all,
            condition: .always,
            schedule: nil,
            couponCode: nil,
            perCustomerLimit: 0,
            usageLimit: 0,
            marginFloorOverrideCents: nil
        )
        #expect(DealDraft(from: portalAuthored) == nil)
    }

    @Test("every v1 kind still seeds a draft — only .unsupported is refused", arguments: v1DraftKindCases)
    func everyV1KindStillSeedsADraft(_ testCase: DraftKindCase) throws {
        var source = validMinimalDraft(id: "deal-seedable-\(testCase.label)")
        source.discount = testCase.discount
        let deal = try decodedDeal(from: source)
        #expect(DealDraft(from: deal) != nil, "kind: \(testCase.label)")
    }
}
