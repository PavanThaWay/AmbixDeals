import Foundation

/// `DealDraft`'s validation vocabulary (`DraftError`) and its string-buffer -> validated-value
/// parsing (`DraftValidation`), split out of `DealDraft.swift` in the final-review fix wave
/// purely to keep that file under the house 800-line cap. No logic moved with a change of
/// meaning; the two types are used from `DealDraft.swift` exactly as before (both were
/// already module-internal or public, so the move is access-neutral).
///
/// Read `DealDraft.swift`'s own type doc comment FIRST — everything here exists to serve its
/// "Save is DISABLED on bad input, never a silent fallback" contract.

// MARK: - DraftError

/// One case per Global-Constraints validation rule (`docs/superpowers/plans/
/// 2026-07-28-deals-studio.md` §Global Constraints), each with a user-readable `message` for
/// the editor's field-adjacent warning labels (`StoreInfoSheet`'s `emailBlock` pattern).
public enum DraftError: Equatable, Sendable {
    case nameRequired
    /// `0 < p ≤ 100` — shared by every percent-scale field (`flatPercentOff.percent`,
    /// `buyXGetYPercentOff.percentOff`, `unlockPercentOffCart.percent`, a `mixedCase` tier's
    /// `discountPercent`).
    case percentInvalid
    /// `> 0` dollars — shared by every dollar field (`flatAmountOff.amount`,
    /// `fixedPrice.price`, `unlockAmountOffCart.amount`, `bundle.bundlePrice`).
    case amountInvalid
    /// `≤ DraftValidation.maxAmountDollars` — the UPPER bound every dollar field shares.
    /// Split out from `.amountInvalid` (and from the per-field `.tierUnitPriceInvalid` /
    /// `.conditionMinSubtotalInvalid` / `.marginFloorOverrideNegative` cases) so the manager
    /// reads "that number is too big" instead of the nonsensical "must be greater than $0"
    /// a shared lower-bound message would give a 20-digit paste. See
    /// `DraftValidation.maxAmountDollars` for why an upper bound exists at all.
    case amountTooLarge
    case buyQtyInvalid
    case bonusQtyInvalid
    case tiersEmpty
    case tierMinQtyInvalid
    case tierUnitPriceInvalid
    case bundleNeedsTwoDistinctProducts
    case bundleComponentQtyInvalid
    case unlockBonusProductQuantityInvalid
    case unlockBonusProductMissing
    case categoryScopeEmpty
    case productsScopeEmpty
    case conditionMinQuantityInvalid
    case conditionMinSubtotalInvalid
    case scheduleWindowInvalid
    case scheduleDateRangeInvalid
    case perCustomerLimitNegative
    case usageLimitNegative
    case marginFloorOverrideNegative

    public var message: String {
        switch self {
        case .nameRequired:
            return "Name is required."
        case .percentInvalid:
            return "Percent must be greater than 0 and at most 100."
        case .amountInvalid:
            return "Amount must be greater than $0."
        case .amountTooLarge:
            return "Amount must be at most \(DraftValidation.maxAmountDisplay)."
        case .buyQtyInvalid:
            return "Buy quantity must be at least 1."
        case .bonusQtyInvalid:
            return "Bonus quantity must be at least 1."
        case .tiersEmpty:
            return "At least one tier is required."
        case .tierMinQtyInvalid:
            return "Each tier's minimum quantity must be at least 1."
        case .tierUnitPriceInvalid:
            return "Each tier's unit price must be greater than $0."
        case .bundleNeedsTwoDistinctProducts:
            return "A bundle needs at least 2 distinct products."
        case .bundleComponentQtyInvalid:
            return "Each bundle component's quantity must be at least 1."
        case .unlockBonusProductQuantityInvalid:
            return "Bonus quantity must be at least 1."
        case .unlockBonusProductMissing:
            return "A reward product is required."
        case .categoryScopeEmpty:
            return "At least one category is required."
        case .productsScopeEmpty:
            return "At least one product is required."
        case .conditionMinQuantityInvalid:
            return "Minimum quantity must be at least 1."
        case .conditionMinSubtotalInvalid:
            return "Minimum subtotal must be greater than $0."
        case .scheduleWindowInvalid:
            return "Start time must be before end time."
        case .scheduleDateRangeInvalid:
            return "End date must be after start date."
        case .perCustomerLimitNegative:
            return "Per-customer limit can't be negative."
        case .usageLimitNegative:
            return "Usage limit can't be negative."
        case .marginFloorOverrideNegative:
            return "Margin floor override can't be negative."
        }
    }
}

// MARK: - Numeric parsing (Decimal(string:) never Double — the house pin)

/// Shared string-buffer -> validated-value parsing for every `Draft…` type. Every helper here
/// does double duty as BOTH the "is this valid" check `validationErrors()` needs and the
/// "give me the parsed value" step `wireFields()` needs, so the two can never silently
/// disagree about what counts as valid.
enum DraftValidation {
    /// The UPPER bound every dollar field shares — $100,000.00, an amount no single retail
    /// pricing rule in this store plausibly needs and comfortably below any arithmetic edge.
    ///
    /// WHY AN UPPER BOUND EXISTS AT ALL (final-review I2): the editor's money controls are
    /// cents-backed (`Money(dollars:)` CLAMPS to `Int.max` cents), so a long enough pasted
    /// digit string reformats its own buffer to `"92233720368547760.00"` — which a
    /// lower-bound-only (`> 0`) rule happily accepts. That string then crosses back to cents
    /// via `Money(decimalDollars:)`, where the `NSDecimalNumber.intValue` conversion is
    /// UNDEFINED past `Int.max` and in practice yields a NEGATIVE cent count: a negative
    /// `fixedPrice` on the wire, and `DealEngine.fixedPriceSavings`'s
    /// `line.unitPrice.cents - price.cents` TRAPS on signed overflow the first time a
    /// matching item is rung. A bound here is the only thing that keeps that authorable
    /// number off the wire — `Deal`'s own decode is fail-closed but cannot un-author it.
    static let maxAmountDollars: Decimal = 100_000

    /// The same ceiling in cents, for the one money field the editor hands over as a `Money`
    /// rather than a string buffer (`DealDraft.marginFloorOverride`).
    static let maxAmountCents: Int = 10_000_000

    /// User-facing rendering of the ceiling for `DraftError.amountTooLarge`'s message.
    static let maxAmountDisplay = "$100,000.00"

    /// `0 < p ≤ 100`.
    static func percent(_ raw: String) -> Decimal? {
        guard let value = decimal(raw), value > 0, value <= 100 else { return nil }
        return value
    }

    /// `0 < amount ≤ maxAmountDollars` — every dollar/unit-price/tier-price field.
    static func positiveDecimal(_ raw: String) -> Decimal? {
        guard let value = decimal(raw), value > 0, value <= maxAmountDollars else { return nil }
        return value
    }

    /// `true` only when the buffer parses cleanly to a number ABOVE the ceiling — lets
    /// `validationErrors()` report `.amountTooLarge` instead of the field's generic
    /// "must be greater than $0" case. Unparseable/`≤ 0` input returns `false`, so the
    /// generic case still owns every other rejection.
    static func exceedsAmountCap(_ raw: String) -> Bool {
        guard let value = decimal(raw) else { return false }
        return value > maxAmountDollars
    }

    /// The `DraftError` a dollar buffer that failed `positiveDecimal` deserves: the
    /// ceiling-specific `.amountTooLarge` when the buffer parses to a number above the cap,
    /// else this field's OWN generic "must be greater than $0" case. `nil` when the buffer is
    /// perfectly valid. Shared by `DraftDiscount`/`DraftCondition` so every dollar field
    /// reports the two bounds the same way.
    static func amountError(_ raw: String, otherwise generic: DraftError) -> DraftError? {
        guard positiveDecimal(raw) == nil else { return nil }
        return exceedsAmountCap(raw) ? .amountTooLarge : generic
    }

    /// `≥ 1` — every quantity field (`buyQty`, `bonusQty`, tier `minQty`, bundle `qty`,
    /// `unlockBonusProduct.quantity`, `minQuantity` condition).
    static func positiveInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    /// `Decimal(string:)` is PERMISSIVE — it silently stops at the first character it can't
    /// parse rather than failing (verified empirically on this toolchain: `"12abc"` -> `12`,
    /// `"5.5.5"` -> `5.5`), which would let garbage user input through as a truncated number.
    /// Require the ENTIRE trimmed string to already look like one clean decimal literal
    /// (optional leading sign, digits, AT MOST one `.`, at least one digit somewhere) before
    /// ever handing it to `Decimal(string:)` — the house "never trust the permissive parse
    /// alone" discipline.
    private static func decimal(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isCleanDecimalLiteral(trimmed) else { return nil }
        return Decimal(string: trimmed)
    }

    private static func isCleanDecimalLiteral(_ s: String) -> Bool {
        var rest = Substring(s)
        if rest.first == "-" || rest.first == "+" { rest.removeFirst() }
        guard !rest.isEmpty else { return false }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        guard parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return parts.contains { !$0.isEmpty }
    }
}
