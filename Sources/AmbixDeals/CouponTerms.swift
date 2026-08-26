import Foundation

// MARK: - CouponTermsInput

/// The enforced facts a printed coupon's small print is derived from — exactly the fields
/// `DealEngine` and the pricing path actually consult at redemption, nothing else.
///
/// This type exists so the composer cannot quietly grow a clause the register does not
/// enforce: to print a new promise, the value it derives from has to be added HERE, and
/// this struct only admits fields with an enforcement site behind them. `usageLimit` is
/// deliberately absent — a store-wide redemption cap is an operational budget, not a
/// promise made to the customer holding this one coupon.
public struct CouponTermsInput: Sendable, Equatable {
    public let audience: DealAudience
    public let scope: DealScope
    public let condition: DealCondition
    public let schedule: DealSchedule?
    public let channel: DealChannel
    public let perCustomerLimit: Int

    public init(audience: DealAudience,
                scope: DealScope,
                condition: DealCondition,
                schedule: DealSchedule?,
                channel: DealChannel,
                perCustomerLimit: Int) {
        self.audience = audience
        self.scope = scope
        self.condition = condition
        self.schedule = schedule
        self.channel = channel
        self.perCustomerLimit = perCustomerLimit
    }
}

// MARK: - CouponTerms

/// Composes a coupon's TERMS line from the deal's enforced fields.
///
/// The paper may only promise what the register will actually give. Before this existed,
/// terms was a free-text box nothing read back — small print could claim "min. purchase
/// $30" while the register redeemed on any sale. Now every clause below is derived from a
/// field with a real enforcement site, at COUPON-ASSEMBLY time, so editing the rule edits
/// the paper the same way the printed expiry already follows `schedule.endDate`. The old
/// free text survives as `DealPrint.terms`, an optional NOTE appended after the clauses
/// for the things rules cannot say ("See staff for details").
///
/// This is not a reversal of `DealPrint.headline`'s "nothing is derived" ruling — that
/// ruling keeps an internal label (`Deal.name`) from being dressed up as an offer. These
/// clauses derive from enforced predicates, not from prose, and the offer itself still
/// only ever prints in the owner's own words.
///
/// ## Twin
///
/// `portal/src/receipts/couponTerms.ts` (AmbixServer) renders these exact strings for the
/// portal's paper preview; both sides pin the same golden table. Every format here is
/// hand-rolled (no `DateFormatter`, no locale) so the twins cannot drift by environment.
///
/// ## Wording decisions, pinned by the goldens
///
/// - `.products` scope prints "select items" — the wire carries product IDS, and naming
///   them would need a catalog the print path deliberately does not take.
/// - `senior`/`military` print as authored even though the engine's O-2a aliasing enforces
///   them at member level: paper stricter than the register never sends a customer into a
///   refusal, and it is what the owner wrote.
/// - `minQuantity(1)` and below produce no clause — a sale has an item by definition.
/// - Dates never appear; the EXPIRY line owns the end date and printing it twice invites
///   the two to disagree.
public enum CouponTerms {

    /// The derived clauses, in their fixed print order. Empty when nothing is restricted.
    public static func clauses(_ input: CouponTermsInput) -> [String] {
        var out: [String] = []
        if let audience = audienceClause(input.audience) { out.append(audience) }
        if let scope = scopeClause(input.scope) { out.append(scope) }
        if let condition = conditionClause(input.condition) { out.append(condition) }
        if let schedule = input.schedule, let window = scheduleClause(schedule) { out.append(window) }
        if let channel = channelClause(input.channel) { out.append(channel) }
        if input.perCustomerLimit > 0 {
            out.append("Limit \(input.perCustomerLimit) per customer.")
        }
        return out
    }

    /// The full TERMS line as it prints: clauses, then the owner's note.
    ///
    /// The note is trimmed but otherwise untouched — it is the owner's own text and gets
    /// no punctuation "help". Either part may be empty; both empty composes "".
    public static func line(clauses: [String], note: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = clauses.joined(separator: " ")
        if derived.isEmpty { return trimmedNote }
        if trimmedNote.isEmpty { return derived }
        return derived + " " + trimmedNote
    }

    /// A stored deal's enforced facts, ready to compose.
    public static func input(for deal: Deal) -> CouponTermsInput {
        CouponTermsInput(audience: deal.audience,
                         scope: deal.scope,
                         condition: deal.condition,
                         schedule: deal.schedule,
                         channel: deal.channel,
                         perCustomerLimit: deal.perCustomerLimit)
    }

    // MARK: - Clauses

    private static func audienceClause(_ audience: DealAudience) -> String? {
        switch audience {
        case .any: return nil
        case .member: return "Members only."
        case .employee: return "Employees only."
        case .wholesale: return "Wholesale only."
        case .senior: return "Seniors only."
        case .military: return "Military only."
        }
    }

    private static func scopeClause(_ scope: DealScope) -> String? {
        switch scope {
        case .all:
            return nil
        case .category(let names):
            guard !names.isEmpty else { return nil }
            return "Valid on \(listJoin(names)) only."
        case .products:
            // Includes the fail-closed empty decode: a match-nothing deal is validation's
            // problem, and inventing a different sentence for it would leak an internal
            // failure state onto a customer's coupon.
            return "Valid on select items only."
        }
    }

    private static func conditionClause(_ condition: DealCondition) -> String? {
        switch condition {
        case .always:
            return nil
        case .minQuantity(let n):
            guard n >= 2 else { return nil }
            return "Min. \(n) items."
        case .minSubtotal(let amount):
            guard amount.cents > 0 else { return nil }
            return "Min. purchase \(moneyText(amount))."
        }
    }

    /// "Valid Fri–Sat, 4 PM–11 PM." — day part omitted when every day is set (127) or the
    /// mask is empty/garbage (≤ 0: a never-valid deal is validation's problem, not the
    /// paper's); time part omitted at the full-day window. Both omitted composes nothing.
    private static func scheduleClause(_ schedule: DealSchedule) -> String? {
        let days = dayText(mask: schedule.weekdayMask)
        let allDay = schedule.dayStartMinute <= 0 && schedule.dayEndMinute >= 1_440
        let times = allDay ? nil
            : "\(timeText(minute: schedule.dayStartMinute))–\(timeText(minute: schedule.dayEndMinute))"
        switch (days, times) {
        case (nil, nil): return nil
        case (let days?, nil): return "Valid \(days)."
        case (nil, let times?): return "Valid \(times)."
        case (let days?, let times?): return "Valid \(days), \(times)."
        }
    }

    /// Only `.online` prints. A paper coupon redeemed at a register IS the in-store
    /// channel, so "In-store only." on physical paper is tautology — and because
    /// `DealDraft` is born `.inStore`, it would be tautology on EVERY Studio-authored
    /// coupon, boilerplate that dilutes the clauses that carry real information. An
    /// online-only deal advertised on paper is the case that genuinely needs the warning.
    private static func channelClause(_ channel: DealChannel) -> String? {
        switch channel {
        case .both, .inStore: return nil
        case .online: return "Online only."
        }
    }

    // MARK: - Formatting (each hand-rolled; the TS twin mirrors these byte for byte)

    /// "A", "A & B", "A, B & C" — the human list join, over the wire's own order.
    private static func listJoin(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " & " + items[items.count - 1]
    }

    /// Whole dollars drop the cents ("$30"); anything else keeps two places ("$29.99").
    /// Formats from integer cents — the representation both twins share — never a float.
    private static func moneyText(_ money: Money) -> String {
        let whole = money.cents / 100
        let rem = money.cents % 100
        guard rem != 0 else { return "$\(whole)" }
        return "$\(whole)." + (rem < 10 ? "0\(rem)" : "\(rem)")
    }

    /// Days render Mon-first (so the weekend is contiguous: "Sat–Sun", never "Sun & Sat"),
    /// runs of three or more compress to a range, and the pieces take the same list join
    /// as categories: "Mon–Wed, Fri & Sun". Bit 0 is Sunday, matching `DealSchedule`.
    private static func dayText(mask: Int) -> String? {
        // The register's own gate tests only bits 0–6 (`1 << weekday`), so a stray high
        // bit is masked off HERE TOO before deciding "every day, no clause" — otherwise a
        // garbage mask like 130 (Mon + bit 7) would print no day restriction while the
        // register refuses six days of the week: paper looser than the rule, the exact
        // direction this whole file exists to prevent.
        let effective = mask & 127
        guard effective > 0, effective < 127 else { return nil }
        let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let displayOrder = [1, 2, 3, 4, 5, 6, 0]  // Mon..Sun as bit indices
        let set = displayOrder.filter { effective & (1 << $0) != 0 }
        guard !set.isEmpty else { return nil }

        var pieces: [String] = []
        var runStart = 0
        // Runs are contiguous positions in the DISPLAY order, so Thu+Fri+Sat compresses
        // even though their bit indices wrap nothing; Sun only chains after Sat.
        func flush(_ endExclusive: Int) {
            let length = endExclusive - runStart
            let first = labels[set[runStart]]
            let last = labels[set[endExclusive - 1]]
            if length >= 3 {
                pieces.append("\(first)–\(last)")
            } else {
                for i in runStart..<endExclusive { pieces.append(labels[set[i]]) }
            }
            runStart = endExclusive
        }
        let positions = set.map { displayOrder.firstIndex(of: $0)! }
        for i in 1..<set.count where positions[i] != positions[i - 1] + 1 {
            flush(i)
        }
        flush(set.count)
        return listJoin(pieces)
    }

    /// Minute-of-day to clock text: 0 = "12 AM", 720 = "12 PM", 1440 = "midnight" (the
    /// window's exclusive end — "11 PM–midnight" reads as a person says it, where
    /// "11 PM–12 AM" reads like a wraparound). On-the-hour drops ":00".
    private static func timeText(minute: Int) -> String {
        if minute >= 1_440 { return "midnight" }
        let hour = minute / 60
        let mins = minute % 60
        let suffix = hour < 12 ? "AM" : "PM"
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        guard mins != 0 else { return "\(hour12) \(suffix)" }
        return "\(hour12):" + (mins < 10 ? "0\(mins)" : "\(mins)") + " \(suffix)"
    }
}

// MARK: - Draft-side input

public extension DealDraft {

    /// The draft's enforced facts AS THEY WOULD SAVE — for composing the editor's live
    /// preview. Every buffer goes through the same normalization `wireFields()` applies
    /// (`wireIdList` ordering for scopes, the `positiveInt`/`positiveDecimal` parses for
    /// condition buffers), so the preview's clauses match what the register will derive
    /// from the stored doc, not what happens to be sitting in a text field mid-keystroke.
    /// An unparseable condition buffer suppresses its clause, matching a draft that
    /// cannot save.
    var couponTermsInput: CouponTermsInput {
        CouponTermsInput(audience: audience,
                         scope: scope.termsScope,
                         condition: condition.termsCondition,
                         schedule: scheduleEnabled ? schedule.termsSchedule : nil,
                         channel: channel,
                         perCustomerLimit: perCustomerLimit)
    }
}

private extension DraftScope {
    var termsScope: DealScope {
        switch self {
        case .all: return .all
        case .category(let names): return .category(names: DraftValidation.wireIdList(names))
        case .products(let ids): return .products(ids: DraftValidation.wireIdList(ids))
        }
    }
}

private extension DraftCondition {
    var termsCondition: DealCondition {
        switch self {
        case .always:
            return .always
        case .minQuantity(let raw):
            guard let value = DraftValidation.positiveInt(raw) else { return .always }
            return .minQuantity(value)
        case .minSubtotal(let raw):
            guard let dollars = DraftValidation.positiveDecimal(raw) else { return .always }
            return .minSubtotal(Money(termsDecimalDollars: dollars))
        }
    }
}

private extension DraftSchedule {
    var termsSchedule: DealSchedule {
        DealSchedule(weekdayMask: weekdayMask,
                     dayStartMinute: dayStartMinute,
                     dayEndMinute: dayEndMinute,
                     startDate: startDate,
                     endDate: endDate)
    }
}

private extension Money {
    /// Mirrors `Deal.swift`'s private `Money(decimalDollars:)` decode helper EXACTLY (same
    /// scale-by-100 + `NSDecimalRound(.plain)`), for the same zero-coupling-between-files
    /// reason `DealDraft.swift`'s own copy documents. A distinct label because a shared
    /// `private` initializer cannot cross files and the signatures must not collide.
    init(termsDecimalDollars dollars: Decimal) {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.init(cents: (rounded as NSDecimalNumber).intValue)
    }
}
