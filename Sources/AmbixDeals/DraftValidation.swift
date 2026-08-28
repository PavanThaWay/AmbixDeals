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
    case amountTooPrecise
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
    case scheduleNoDaysSelected
    case perCustomerLimitNegative
    case usageLimitNegative
    case marginFloorOverrideNegative
    /// Printing is ON with no offer line. `DealPrint.headline == nil` means "does not
    /// print", so saving this would produce a deal the manager believes advertises itself
    /// and which silently never does.
    case printHeadlineRequired
    /// Printing is ON with no coupon code. `CouponSelector` refuses to advertise a deal
    /// with nothing to scan back; this is that rule where the manager can still act on it.
    case printNeedsCouponCode
    case printTriggerCategoriesEmpty
    case printTriggerProductsEmpty
    case printTriggerAmountInvalid
    /// Printing is ON with a coupon code a barcode cannot carry unchanged.
    ///
    /// Scoped to printing on purpose: a code like `20%OFF` works perfectly well when it is
    /// only ever typed at the register — `enteredCodes` records the raw text — so
    /// rejecting it outright would break deals that are fine today. It is only broken by
    /// being PRINTED, where the barcode carries a stripped string the register never
    /// matches.
    case printCouponCodeNotScannable([String])

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
        case .amountTooPrecise:
            return "Amount must have at most two decimals."
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
            return "Bonus quantity must be between 1 and \(DraftValidation.maxGrantQuantity)."
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
        case .scheduleNoDaysSelected:
            return "Schedule needs at least one weekday."
        case .scheduleDateRangeInvalid:
            return "End date must be after start date."
        case .perCustomerLimitNegative:
            return "Per-customer limit can't be negative."
        case .usageLimitNegative:
            return "Usage limit can't be negative."
        case .printHeadlineRequired:
            return "Add the offer line customers will read, or turn off receipt printing."
        case .printNeedsCouponCode:
            return "A coupon code is required to print this deal on receipts."
        case .printTriggerCategoriesEmpty:
            return "Pick at least one category for the receipt trigger."
        case .printTriggerProductsEmpty:
            return "Pick at least one product for the receipt trigger."
        case .printTriggerAmountInvalid:
            return "Sale total must be greater than $0."
        case .printCouponCodeNotScannable(let offenders):
            // Names the characters, because "invalid code" leaves a manager staring at a
            // field they cannot see anything wrong with — a space is the common case.
            let list = offenders.joined(separator: " ")
            return "Coupon code can only use letters, numbers and dashes to print as a "
                + "scannable barcode. Remove: \(list)"
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

    /// `0 < amount ≤ maxAmountDollars`, at most two decimals — every dollar/unit-price/
    /// tier-price field. The precision bound exists because the register keeps money in
    /// integer CENTS and the two editors used to snap a third decimal differently
    /// (Decimal half-up here, float `toFixed` on the portal), so "1.005" could save as a
    /// different cent depending on which editor wrote it. Rejecting sub-cent input at
    /// BOTH editors removes the divergent domain instead of picking a winner.
    static func positiveDecimal(_ raw: String) -> Decimal? {
        guard let value = decimal(raw), value > 0, value <= maxAmountDollars,
              isWholeCents(value) else { return nil }
        return value
    }

    /// Whether a dollar `Decimal` lands exactly on a cent — `value * 100` has no
    /// fractional part. The same scale-by-100 the wire encoder uses, so "valid to type"
    /// and "encodes without rounding" are one predicate.
    static func isWholeCents(_ value: Decimal) -> Bool {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return rounded == scaled
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
        if exceedsAmountCap(raw) { return .amountTooLarge }
        // In range but off the cent grid ("1.005"): name the real problem rather than
        // the generic "must be greater than $0", which the value plainly satisfies.
        if let value = decimal(raw), value > 0, !isWholeCents(value) { return .amountTooPrecise }
        return generic
    }

    /// `≥ 1` — every quantity field that is a THRESHOLD (`buyQty`, `bonusQty`, tier `minQty`,
    /// bundle `qty`, `minQuantity` condition). Deliberately unbounded above: for a threshold, a
    /// larger number makes the deal HARDER to trigger, so an absurd value fails safe by
    /// construction. `unlockBonusProduct.quantity` is the one exception in the whole contract —
    /// see `grantQuantity(_:)`.
    static func positiveInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    // MARK: - The one GRANT quantity in the contract

    /// The ceiling on `unlockBonusProduct.quantity`.
    ///
    /// WHY THIS ONE INTEGER NEEDS A CEILING AND THE OTHERS DON'T: every other integer on this
    /// wire is a THRESHOLD — `buyQty`, `bonusQty`, a tier's `minQty`, a bundle component's
    /// `qty`, `condition.minQuantity` — where a runaway value simply means the deal never
    /// triggers. `unlockBonusProduct.quantity` runs the other way: it is the number of free
    /// units GRANTED, bounded only by what happens to be in the cart
    /// (`DealEngine.unlockBonusProductOutcome`: `consumed = min(remaining, line.quantity)`).
    /// An absurd value there is not conservative, it is maximally generous — it discounts every
    /// matching pack in every cart, forever, and nothing downstream questions it.
    ///
    /// The number itself is chosen the same way `maxAmountDollars` is: comfortably past
    /// anything a real retail pricing rule needs (realistic grants are 1–12), and low enough
    /// that a corrupt or machine-authored value lands outside it.
    static let maxGrantQuantity: Int = 100_000

    /// `1 ≤ quantity ≤ maxGrantQuantity` — the authoring-side bound for
    /// `unlockBonusProduct.quantity`. Shared by `wireFields()` and `validationErrors()` so an
    /// over-cap grant is reported to the manager rather than silently encoded.
    ///
    /// Its DECODE-side twin is `DealDiscount.decodedGrantQuantity` in `Deal.swift`, which lands
    /// an out-of-range stored value on `0` (dormant) instead of throwing. The two are
    /// deliberately different shapes for the same bound: an author must be BLOCKED and told;
    /// a register must never lose a whole document over one bad field.
    static func grantQuantity(_ raw: String) -> Int? {
        guard let value = positiveInt(raw), value <= maxGrantQuantity else { return nil }
        return value
    }

    // MARK: - Product ids / category names (the ONE definition of what an id IS on the wire)

    /// THE normalization every product id and category name crosses on its way to the wire,
    /// used by BOTH `wireFields()` and `validationErrors()` at every site that emits one, so
    /// the encoder and the validator can never disagree about what an id is.
    ///
    /// WHY THIS EXISTS (and why trimming is not cosmetic): `DealEngine` matches a reward SKU
    /// with `line.productId == productId` and a product scope with `ids.contains(line.productId)`
    /// — BYTE-EXACT, with no normalization anywhere downstream, in the register, the projector,
    /// or the portal. An id that reaches Firestore carrying a stray space therefore decodes
    /// cleanly, passes every bound, lists as **Active** in Station and in the portal, and never
    /// fires at any register, with no error surfaced anywhere. Trimming HERE — at the wire
    /// boundary, in one shared place — is what keeps that class of silent no-op unauthorable.
    static func wireId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `wireId(_:)`, or `nil` when nothing survives the trim — the "is this a real id" check.
    static func nonEmptyWireId(_ raw: String) -> String? {
        let trimmed = wireId(raw)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A `Set` of picked ids/names rendered as the deterministic wire array: each entry
    /// trimmed via `wireId(_:)` then NFC-normalized, whitespace-only entries DROPPED,
    /// duplicates collapsed, then sorted by Unicode CODE POINT over the NFC forms.
    ///
    /// NFC + code-point ordering (not `sorted()`'s default `String` comparison) because
    /// this array is a TWIN: the portal's `dealWireId.ts` builds the same wire array in
    /// JavaScript, where `===` is code-unit equality and `.sort()` is UTF-16 order —
    /// both diverge from Swift's canonical-equivalence semantics on decomposed accents
    /// and astral-plane characters. NFC makes canonical-equal names byte-equal on both
    /// sides, and code-point order is the one ordering both languages implement
    /// identically. For ASCII (every real id and category name today) all of this is
    /// byte-for-byte what `sorted()` produced, so no stored doc changes.
    ///
    /// The sort is what makes the round-tripped `Deal.scope`'s order-sensitive `[String]`
    /// independent of the `Set`'s hash-seeded iteration order — a scope of `["b", "a"]`
    /// still emits exactly `["a", "b"]`.
    static func wireIdList(_ raw: Set<String>) -> [String] {
        Set(raw.compactMap { nonEmptyWireId($0)?.precomposedStringWithCanonicalMapping })
            .sorted { lhs, rhs in
                lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
            }
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
