import Foundation
import Testing

@testable import AmbixDeals

/// `CouponTerms` — the small print, derived from the fields the register enforces.
///
/// Every expected string below is a PIN, not an example: the portal's TS twin
/// (`portal/src/receipts/couponTerms.ts`) renders these identical strings for its paper
/// preview, and the GOLDEN TABLE at the bottom of this file is mirrored verbatim in
/// `couponTerms.golden.test.ts`. A wording change is a two-repo change or it is a drift.

private func input(audience: DealAudience = .any,
                   scope: DealScope = .all,
                   condition: DealCondition = .always,
                   schedule: DealSchedule? = nil,
                   channel: DealChannel = .both,
                   perCustomerLimit: Int = 0) -> CouponTermsInput {
    CouponTermsInput(audience: audience, scope: scope, condition: condition,
                     schedule: schedule, channel: channel, perCustomerLimit: perCustomerLimit)
}

private func schedule(mask: Int = 127, start: Int = 0, end: Int = 1_440) -> DealSchedule {
    DealSchedule(weekdayMask: mask, dayStartMinute: start, dayEndMinute: end,
                 startDate: nil, endDate: nil)
}

// MARK: - Nothing restricted, nothing promised

@Test("an unrestricted deal derives no clauses at all")
func unrestrictedDealHasNoClauses() {
    #expect(CouponTerms.clauses(input()) == [])
}

@Test("a full-week, full-day schedule is no restriction and derives nothing")
func openScheduleDerivesNothing() {
    #expect(CouponTerms.clauses(input(schedule: schedule())) == [])
}

// MARK: - Single clauses, pinned

@Test("audience clauses print as authored, including the O-2a aliased tiers",
      arguments: [
          (DealAudience.member, "Members only."),
          (.employee, "Employees only."),
          (.wholesale, "Wholesale only."),
          (.senior, "Seniors only."),
          (.military, "Military only."),
      ] as [(DealAudience, String)])
func audienceClause(_ audience: DealAudience, _ expected: String) {
    #expect(CouponTerms.clauses(input(audience: audience)) == [expected])
}

@Test("category scope names the categories in wire order with the human list join")
func categoryScopeClause() {
    #expect(CouponTerms.clauses(input(scope: .category(names: ["Wine"])))
        == ["Valid on Wine only."])
    #expect(CouponTerms.clauses(input(scope: .category(names: ["Beer", "Wine"])))
        == ["Valid on Beer & Wine only."])
    #expect(CouponTerms.clauses(input(scope: .category(names: ["Beer", "Spirits", "Wine"])))
        == ["Valid on Beer, Spirits & Wine only."])
}

@Test("products scope prints 'select items' — ids cannot be named without a catalog")
func productsScopeClause() {
    #expect(CouponTerms.clauses(input(scope: .products(ids: ["sku-1", "sku-2"])))
        == ["Valid on select items only."])
    // The fail-closed empty decode gets the same sentence, not an invented failure state.
    #expect(CouponTerms.clauses(input(scope: .products(ids: [])))
        == ["Valid on select items only."])
}

@Test("an empty category list derives no clause rather than 'Valid on  only.'")
func emptyCategoryScopeIsSilent() {
    #expect(CouponTerms.clauses(input(scope: .category(names: []))) == [])
}

@Test("minimum-quantity condition prints from 2 up; 1 and below is 'always' in practice")
func minQuantityClause() {
    #expect(CouponTerms.clauses(input(condition: .minQuantity(2))) == ["Min. 2 items."])
    #expect(CouponTerms.clauses(input(condition: .minQuantity(6))) == ["Min. 6 items."])
    #expect(CouponTerms.clauses(input(condition: .minQuantity(1))) == [])
    #expect(CouponTerms.clauses(input(condition: .minQuantity(0))) == [])
}

@Test("minimum-subtotal condition formats from cents: whole dollars bare, else two places")
func minSubtotalClause() {
    #expect(CouponTerms.clauses(input(condition: .minSubtotal(Money(cents: 3_000))))
        == ["Min. purchase $30."])
    #expect(CouponTerms.clauses(input(condition: .minSubtotal(Money(cents: 2_999))))
        == ["Min. purchase $29.99."])
    #expect(CouponTerms.clauses(input(condition: .minSubtotal(Money(cents: 3_005))))
        == ["Min. purchase $30.05."])
    #expect(CouponTerms.clauses(input(condition: .minSubtotal(.zero))) == [])
}

@Test("only the online channel prints — paper in hand at a register is already in-store",
      arguments: [
    (DealChannel.inStore, [String]()),
    (.online, ["Online only."]),
    (.both, []),
] as [(DealChannel, [String])])
func channelClause(_ channel: DealChannel, _ expected: [String]) {
    #expect(CouponTerms.clauses(input(channel: channel)) == expected)
}

@Test("per-customer limit prints whenever the register enforces one")
func perCustomerLimitClause() {
    #expect(CouponTerms.clauses(input(perCustomerLimit: 1)) == ["Limit 1 per customer."])
    #expect(CouponTerms.clauses(input(perCustomerLimit: 3)) == ["Limit 3 per customer."])
    #expect(CouponTerms.clauses(input(perCustomerLimit: 0)) == [])
}

// MARK: - Schedule rendering

@Test("day sets render Mon-first, compress runs of three or more, and list-join the rest")
func dayRendering() {
    // Mon–Fri: bits 1–5.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b0111110)))
        == ["Valid Mon–Fri."])
    // Weekend reads "Sat & Sun", never the bit-order "Sun & Sat".
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b1000001)))
        == ["Valid Sat & Sun."])
    // Thu through Sun chains across the Sat/Sun display seam into one range.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b1110001)))
        == ["Valid Thu–Sun."])
    // Mixed: a compressed run plus a straggler takes the same join as categories.
    // 0b0101110 = bits 1,2,3,5 = Mon,Tue,Wed + Fri.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b0101110)))
        == ["Valid Mon–Wed & Fri."])
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b0000010)))
        == ["Valid Mon."])
}

@Test("time windows: 12-hour, on-the-hour drops minutes, 1440 is 'midnight'")
func timeRendering() {
    #expect(CouponTerms.clauses(input(schedule: schedule(start: 960, end: 1_380)))
        == ["Valid 4 PM–11 PM."])
    #expect(CouponTerms.clauses(input(schedule: schedule(start: 990, end: 1_380)))
        == ["Valid 4:30 PM–11 PM."])
    #expect(CouponTerms.clauses(input(schedule: schedule(start: 1_380, end: 1_440)))
        == ["Valid 11 PM–midnight."])
    #expect(CouponTerms.clauses(input(schedule: schedule(start: 0, end: 720)))
        == ["Valid 12 AM–12 PM."])
    #expect(CouponTerms.clauses(input(schedule: schedule(start: 545, end: 605)))
        == ["Valid 9:05 AM–10:05 AM."])
}

@Test("days and times combine into one clause")
func dayAndTimeCombine() {
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 0b1100000, start: 960, end: 1_380)))
        == ["Valid Fri & Sat, 4 PM–11 PM."])
}

@Test("a stray high bit is masked off the way the register masks it — the Mon restriction still prints")
func garbageMaskBitsAreMaskedNotSilenced() {
    // 130 = Mon + bit 7. The register tests only bits 0–6, so it enforces Mon-only;
    // the paper must say so rather than dropping the clause.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 130))) == ["Valid Mon."])
    // All seven days + garbage = every day = no clause.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 255))) == [])
    // Only garbage bits = no real days = validation's problem, no clause.
    #expect(CouponTerms.clauses(input(schedule: schedule(mask: 128))) == [])
}

// MARK: - Composition

@Test("clauses hold their fixed order and join with single spaces")
func clauseOrderIsFixed() {
    let full = input(audience: .member,
                     scope: .category(names: ["Wine"]),
                     condition: .minSubtotal(Money(cents: 3_000)),
                     schedule: schedule(mask: 0b1100000, start: 960, end: 1_380),
                     channel: .inStore,
                     perCustomerLimit: 1)
    // channel .inStore is present in the input and deliberately contributes nothing.
    #expect(CouponTerms.line(clauses: CouponTerms.clauses(full), note: "")
        == "Members only. Valid on Wine only. Min. purchase $30. Valid Fri & Sat, 4 PM–11 PM. Limit 1 per customer.")
}

@Test("the note prints last, trimmed, and untouched otherwise")
func noteAppendsLast() {
    #expect(CouponTerms.line(clauses: ["Limit 1 per customer."], note: "  See staff for details  ")
        == "Limit 1 per customer. See staff for details")
    #expect(CouponTerms.line(clauses: [], note: "One per visit.") == "One per visit.")
    #expect(CouponTerms.line(clauses: ["In-store only."], note: "") == "In-store only.")
    #expect(CouponTerms.line(clauses: [], note: "   ") == "")
}

@Test("input(for:) carries exactly the deal's six enforced fields")
func inputForDeal() throws {
    let json = """
    {"id":"d1","name":"wknd wine","isActive":true,
     "channel":"inStore","audience":"member",
     "discount":{"kind":"flatPercentOff","percent":10},
     "scope":{"type":"category","ids":["Wine"]},
     "condition":{"type":"minSubtotal","value":30},
     "schedule":{"weekdayMask":96,"dayStartMinute":960,"dayEndMinute":1380},
     "perCustomerLimit":1,"usageLimit":200}
    """
    let deal = try JSONDecoder().decode(Deal.self, from: Data(json.utf8))
    let derived = CouponTerms.clauses(CouponTerms.input(for: deal))
    // usageLimit and the in-store channel deliberately contribute nothing.
    #expect(derived == ["Members only.", "Valid on Wine only.", "Min. purchase $30.",
                        "Valid Fri & Sat, 4 PM–11 PM.", "Limit 1 per customer."])
}

// MARK: - Draft-side mapping

@Test("draft buffers normalize the way the wire write normalizes them")
func draftMappingNormalizes() {
    var draft = DealDraft(id: "d-terms")
    draft.audience = .member
    // Padded, duplicated set entries take wireIdList's trim + sort, so the preview names
    // categories in the exact order the stored doc will.
    draft.scope = .category(names: ["  Wine ", "Beer", "Beer"])
    draft.condition = .minSubtotal("30")
    draft.scheduleEnabled = true
    draft.schedule = DraftSchedule(weekdayMask: 0b1100000, dayStartMinute: 960, dayEndMinute: 1_380)
    draft.perCustomerLimit = 1
    let derived = CouponTerms.clauses(draft.couponTermsInput)
    #expect(derived == ["Members only.", "Valid on Beer & Wine only.", "Min. purchase $30.",
                        "Valid Fri & Sat, 4 PM–11 PM.", "Limit 1 per customer."])
}

@Test("an unparseable condition buffer suppresses its clause, matching a draft that cannot save")
func draftMappingSuppressesUnparseableBuffers() {
    var draft = DealDraft(id: "d-terms")
    draft.condition = .minSubtotal("30..")
    #expect(CouponTerms.clauses(draft.couponTermsInput) == [])
    draft.condition = .minQuantity("lots")
    #expect(CouponTerms.clauses(draft.couponTermsInput) == [])
}

@Test("a disabled schedule derives nothing even when the buffers hold a window")
func draftDisabledScheduleIsSilent() {
    var draft = DealDraft(id: "d-terms")
    draft.scheduleEnabled = false
    draft.schedule = DraftSchedule(weekdayMask: 0b0000010, dayStartMinute: 960, dayEndMinute: 1_380)
    #expect(CouponTerms.clauses(draft.couponTermsInput) == [])
}

@Test("draft money parses to the same cent the wire write emits")
func draftMoneyMatchesWire() {
    var draft = DealDraft(id: "d-terms")
    draft.condition = .minSubtotal("29.99")
    #expect(CouponTerms.clauses(draft.couponTermsInput) == ["Min. purchase $29.99."])
}

// MARK: - The golden table (mirrored verbatim in portal couponTerms.golden.test.ts)

/// Each case: (name, input, note, expected line). The TS twin declares the same table —
/// same names, same inputs, same expected strings — and any edit here without the same
/// edit there is a drift the portal preview will show a customer.
private let goldens: [(String, CouponTermsInput, String, String)] = [
    ("unrestricted", input(), "", ""),
    ("note-only", input(), "One per visit.", "One per visit."),
    ("member", input(audience: .member), "", "Members only."),
    ("category-pair", input(scope: .category(names: ["Beer", "Wine"])), "",
     "Valid on Beer & Wine only."),
    ("select-items", input(scope: .products(ids: ["sku-1"])), "",
     "Valid on select items only."),
    ("min-qty", input(condition: .minQuantity(2)), "", "Min. 2 items."),
    ("min-subtotal-whole", input(condition: .minSubtotal(Money(cents: 3_000))), "",
     "Min. purchase $30."),
    ("min-subtotal-cents", input(condition: .minSubtotal(Money(cents: 2_999))), "",
     "Min. purchase $29.99."),
    ("weekdays", input(schedule: schedule(mask: 0b0111110)), "", "Valid Mon–Fri."),
    ("weekend-evening", input(schedule: schedule(mask: 0b1100000, start: 960, end: 1_380)), "",
     "Valid Fri & Sat, 4 PM–11 PM."),
    ("late-window", input(schedule: schedule(mask: 127, start: 1_380, end: 1_440)), "",
     "Valid 11 PM–midnight."),
    ("online-only", input(channel: .online), "", "Online only."),
    ("in-store-is-silent", input(channel: .inStore), "", ""),
    ("limit-one", input(perCustomerLimit: 1), "", "Limit 1 per customer."),
    ("everything", input(audience: .member,
                         scope: .category(names: ["Wine"]),
                         condition: .minSubtotal(Money(cents: 3_000)),
                         schedule: schedule(mask: 0b1100000, start: 960, end: 1_380),
                         channel: .inStore,
                         perCustomerLimit: 1),
     "Valid on marked vintages.",
     "Members only. Valid on Wine only. Min. purchase $30. Valid Fri & Sat, 4 PM–11 PM. Limit 1 per customer. Valid on marked vintages."),
]

@Test("the golden table both twins pin")
func goldenTable() {
    for (name, input, note, expected) in goldens {
        let line = CouponTerms.line(clauses: CouponTerms.clauses(input), note: note)
        #expect(line == expected, "golden '\(name)'")
    }
}
