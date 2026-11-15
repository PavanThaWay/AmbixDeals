import Foundation

/// Station's own wire model for a pricing deal (Firestore `deals` doc / Phase A projector
/// row). Decoded directly via `JSONDecoder` — this is a CLEAN discriminated codable, not a
/// port of Ambix POS's Swift-synthesized `_0`/reference-date enum shapes. The Phase A
/// projector reads `discount.kind` off exactly this shape and stores the whole discount
/// object as `payload`, so the `kind` discriminator MUST live inside the `discount` object,
/// never as a sibling field on `Deal` itself.
///
/// Decode is deliberately ASYMMETRIC by field, matching how badly a wrong guess can hurt if
/// the doc is malformed, missing a field, or from a future schema version Station doesn't
/// know about yet:
/// - `scope` fails CLOSED to `.products(ids: [])` — MATCH NOTHING — on anything malformed or
///   missing (a 2026-07-14 POS-side fix, kept here verbatim): garbage data must never
///   silently become a storewide discount.
/// - `condition` fails OPEN to `.always` on anything malformed or missing — an unreadable
///   trigger still needs SOME condition to evaluate against, and "always eligible" is the
///   conservative choice given `scope`/`schedule`/`audience` still gate the deal elsewhere.
/// - `schedule` fails to `nil` (unscheduled = no time-of-day/day-of-week restriction) rather
///   than blocking the whole deal from decoding.
/// - `audience` and `channel` FAIL THE WHOLE DECODE on an unrecognized string. Unlike scope,
///   silently widening either one would make a deal apply to MORE customers or MORE channels
///   than it was authored for — the failure mode runs the wrong direction, so there is no
///   safe fallback value; the caller must drop the doc instead of risking over-application.
/// - `isActive` missing defaults to `false` — fail-closed: a deal authored without an
///   explicit active flag must never silently start firing.
/// - `channel` missing defaults to `.both` — a deal authored without a channel applies
///   everywhere (documented divergence from a stricter "missing = inStore only" default).
/// - `perCustomerLimit`/`usageLimit` missing default to `0` (0 = unlimited).
public struct Deal: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    public let name: String
    public let isActive: Bool
    public let channel: DealChannel
    public let audience: DealAudience
    public let discount: DealDiscount
    public let memberDiscount: DealDiscount?
    public let scope: DealScope
    public let condition: DealCondition
    public let schedule: DealSchedule?
    /// `nil`/empty = auto-apply (no coupon entry required).
    public let couponCode: String?
    /// `0` = unlimited.
    public let perCustomerLimit: Int
    /// `0` = unlimited.
    public let usageLimit: Int
    public let marginFloorOverrideCents: Int?
    /// Whether this deal advertises itself on a receipt. `nil` = never printed, which is
    /// what every deal authored before v0.3.0 decodes to.
    public let print: DealPrint?
    /// The parsed payload of a grouped promotion (`itemOffer`, `quantityGroup`, `mixGroup`,
    /// `buyGetGroup`, `slotBundle`). `nil` for every other deal AND for a grouped deal whose
    /// payload failed the strict decode; `discount` is `.unsupported` either way, so nothing
    /// fires. Use `groupedKind` to tell a grouped row from a malformed one.
    public let grouped: GroupedPromotion?
    /// Bumped by the server's write path on every edit of a grouped promotion. `nil` when absent or unusable.
    public let revision: Int?

    /// The grouped kind named by `discount`, even when `grouped` is `nil`.
    public var groupedKind: GroupedPromotionKind? {
        guard case .unsupported(let raw) = discount else { return nil }
        return GroupedPromotionKind(rawValue: raw)
    }

    public init(
        id: String,
        name: String,
        isActive: Bool,
        channel: DealChannel,
        audience: DealAudience,
        discount: DealDiscount,
        memberDiscount: DealDiscount?,
        scope: DealScope,
        condition: DealCondition,
        schedule: DealSchedule?,
        couponCode: String?,
        perCustomerLimit: Int,
        usageLimit: Int,
        marginFloorOverrideCents: Int?,
        // DEFAULTED, unlike every other parameter here, and deliberately: it makes the
        // v0.3.0 addition source-COMPATIBLE, so Station and Daisho repin on their own
        // schedule with no atomic fleet update — the same property the v0.2.0 `priority`
        // removal was careful to preserve.
        print: DealPrint? = nil,
        grouped: GroupedPromotion? = nil,
        revision: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.channel = channel
        self.audience = audience
        self.discount = discount
        self.memberDiscount = memberDiscount
        self.scope = scope
        self.condition = condition
        self.schedule = schedule
        self.couponCode = couponCode
        self.perCustomerLimit = perCustomerLimit
        self.usageLimit = usageLimit
        // Sanitized the same way the decode path (below) sanitizes — see
        // `sanitizedMarginFloorOverride` for both bounds' rationale. Without this, a caller
        // building a `Deal` directly (bypassing `JSONDecoder`) could still construct one
        // carrying a raw negative override, which the decode-path comment's "every consumer
        // downstream can trust the invariant" claim did not actually hold until now.
        self.marginFloorOverrideCents = Deal.sanitizedMarginFloorOverride(marginFloorOverrideCents)
        self.print = print
        // Kept only when it agrees with `discount` (a grouped row is `.unsupported(kind)` and the
        // payload names that same kind), the way the margin override above is cleaned.
        if case .unsupported(let raw) = discount, let grouped, grouped.kind.rawValue == raw {
            self.grouped = grouped
        } else {
            self.grouped = nil
        }
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isActive, channel, audience, discount, memberDiscount,
             scope, condition, schedule, couponCode, perCustomerLimit, usageLimit,
             marginFloorOverrideCents, print, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false

        // `channel`/`audience`: missing -> documented default; present-but-unrecognized ->
        // THROW (fail the whole decode). See type doc comment for the fail-hard rationale.
        if let raw = try container.decodeIfPresent(String.self, forKey: .channel) {
            guard let parsed = DealChannel(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .channel, in: container, debugDescription: "Unrecognized channel '\(raw)'"
                )
            }
            channel = parsed
        } else {
            channel = .both
        }

        if let raw = try container.decodeIfPresent(String.self, forKey: .audience) {
            guard let parsed = DealAudience(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .audience, in: container, debugDescription: "Unrecognized audience '\(raw)'"
                )
            }
            audience = parsed
        } else {
            audience = .any
        }

        discount = try container.decode(DealDiscount.self, forKey: .discount)
        memberDiscount = try container.decodeIfPresent(DealDiscount.self, forKey: .memberDiscount)

        // `scope`/`condition`/`schedule`: `try?` swallows BOTH a missing key and a malformed
        // shape (wrong type, unrecognized discriminator, missing required sub-field) into the
        // same fallback — see type doc comment for why each field's fallback direction differs.
        scope = (try? container.decodeIfPresent(DealScope.self, forKey: .scope)) ?? .products(ids: [])
        condition = (try? container.decodeIfPresent(DealCondition.self, forKey: .condition)) ?? .always
        schedule = (try? container.decodeIfPresent(DealSchedule.self, forKey: .schedule)) ?? nil

        couponCode = try container.decodeIfPresent(String.self, forKey: .couponCode)
        perCustomerLimit = try container.decodeIfPresent(Int.self, forKey: .perCustomerLimit) ?? 0
        usageLimit = try container.decodeIfPresent(Int.self, forKey: .usageLimit) ?? 0
        // Sanitized at the DECODE boundary — see `sanitizedMarginFloorOverride`.
        marginFloorOverrideCents = Deal.sanitizedMarginFloorOverride(
            try container.decodeIfPresent(Int.self, forKey: .marginFloorOverrideCents)
        )
        // `try?` — the same swallow `scope`/`condition`/`schedule` use above, and it is
        // what makes the whole print config fail CLOSED to `nil` on every malformed shape:
        // a missing trigger, an unrecognized trigger type, a wrong-typed field, a required
        // sub-field absent. `DealPrint`'s own decode throws normally; the DIRECTION of the
        // failure is decided here, exactly as `scope`'s doc comment describes.
        //
        // Closed rather than open because the failure lands in a customer's hand. `scope`
        // fails closed so garbage can never silently become a storewide discount; garbage
        // must not silently become an offer on paper either. A deal whose advertising is
        // broken still PRICES correctly — only its coupon stops printing.
        print = (try? container.decodeIfPresent(DealPrint.self, forKey: .print)) ?? nil

        // A bad grouped payload never fails the Deal: `try?` leaves `grouped` nil and the
        // row still lists as `.unsupported`, so nothing prices it and nothing edits it.
        if case .unsupported(let raw) = discount, GroupedPromotionKind(rawValue: raw) != nil {
            grouped = try? container.decode(GroupedPromotion.self, forKey: .discount)
        } else {
            grouped = nil
        }
        revision = (try? container.decodeIfPresent(Int.self, forKey: .revision)) ?? nil
    }

    /// The margin-floor override, bounded at BOTH ends before any consumer sees it.
    /// `DealEngine.clampToCostFloor` reads this value directly as
    /// `maxDiscount = max(0, lineTotal - floorBasis)` where `floorBasis` is this override when
    /// present, else the line's real cost — so each end fails a different, specific way:
    ///
    /// - **Below 0 -> `0`** (unchanged behavior). A negative `floorBasis` INFLATES `maxDiscount`
    ///   above `lineTotal`, silently disabling the cost floor even with `allowBelowCost == false`
    ///   — the opposite of what a "floor" is. `Int.min` is worse: `lineTotal - Int.min` traps on
    ///   signed overflow the first time any line clamps against it.
    /// - **Above `DraftValidation.maxAmountCents` -> `nil`** (the bound this was missing). The
    ///   old clamp was LOWER-BOUND-ONLY, so a 12-digit override sailed straight through, and a
    ///   `floorBasis` larger than any line total yields `maxDiscount == 0` on EVERY line: the
    ///   deal exists, reads Active in Station and in the portal, and discounts nothing, forever,
    ///   with nothing anywhere reporting a problem.
    ///
    /// `nil` rather than a clamp-to-ceiling is the deliberate choice, because clamping does not
    /// fix the symptom — a $100,000 floor still exceeds every realistic line total and still
    /// discounts nothing. An override this far out of range cannot have been authored through
    /// `DealDraft` (`validationErrors` rejects it with `.amountTooLarge`), so it is corruption,
    /// and the safe reading of corruption is "don't trust it": `nil` falls back to the item's
    /// REAL cost floor, which both protects margin and lets the deal actually apply. Clamping to
    /// `0` would be the unsafe direction — that means no floor at all.
    ///
    /// This is the DECODE-side twin of `DealDraft.validationErrors`'s two-bound check on
    /// `marginFloorOverride`, sharing its ceiling so the author and the register agree on what
    /// a plausible floor is.
    static func sanitizedMarginFloorOverride(_ cents: Int?) -> Int? {
        guard let cents, cents <= DraftValidation.maxAmountCents else { return nil }
        return max(0, cents)
    }
}

// MARK: - DealChannel / DealAudience

/// Wire strings match the case names exactly (`"inStore"`, `"online"`, `"both"`).
public enum DealChannel: String, Sendable, Equatable {
    case inStore, online, both
}

/// Wire strings match the AmbixServer migration CHECK constraint exactly. `senior`/`military`
/// resolve as `member` at `DealEngine`'s audience-gate resolution site (O-2a ruling) — that
/// aliasing is `DealEngine`'s concern; this type only needs to decode/round-trip the six
/// distinct wire strings faithfully.
public enum DealAudience: String, Sendable, Equatable {
    case any, member, employee, wholesale, senior, military
}

// MARK: - DealScope

/// Line/cart matching predicate. Decode failure (missing, wrong shape, unrecognized `type`,
/// or a `type` whose required `ids` array is missing/wrong-typed) is handled by the CALLER
/// (`Deal.init(from:)`) via `try?`, which is what makes this fail CLOSED to `.products([])` —
/// this type's own `init(from:)` just throws normally on anything it can't parse.
public enum DealScope: Sendable, Equatable {
    case all
    /// O-2b ruling: the wire array holds category NAME strings, not ids.
    case category(names: [String])
    case products(ids: [String])
}

extension DealScope: Decodable {
    private enum CodingKeys: String, CodingKey { case type, ids }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "all":
            self = .all
        case "category":
            self = .category(names: try container.decode([String].self, forKey: .ids))
        case "products":
            self = .products(ids: try container.decode([String].self, forKey: .ids))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unrecognized scope type '\(type)'"
            )
        }
    }
}

// MARK: - DealCondition

/// Trigger predicate gating whether a deal's discount fires. Decode failure is handled by the
/// caller (`Deal.init(from:)`) via `try?`, which is what makes this fail OPEN to `.always`.
public enum DealCondition: Sendable, Equatable {
    case always
    case minQuantity(Int)
    case minSubtotal(Money)
}

extension DealCondition: Decodable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "always":
            self = .always
        case "minQuantity":
            self = .minQuantity(try container.decode(Int.self, forKey: .value))
        case "minSubtotal":
            // A threshold, so an out-of-range stored value is clamped to what the editors
            // accept rather than dropped.
            let dollars = try container.decode(Decimal.self, forKey: .value)
            self = .minSubtotal(Money(clampedStoredDollars: dollars))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unrecognized condition type '\(type)'"
            )
        }
    }
}

// MARK: - DealSchedule

/// Time-of-day / day-of-week / date-range window a deal is active within. `nil` on the
/// owning `Deal` means "always in schedule" (no restriction) — that fallback lives at the
/// `Deal.init(from:)` call site, not here.
public struct DealSchedule: Sendable, Equatable {
    /// Sunday = bit 0; `127` = all seven days set.
    public let weekdayMask: Int
    /// Inclusive.
    public let dayStartMinute: Int
    /// EXCLUSIVE; `1440` means "through the end of the day".
    public let dayEndMinute: Int
    /// Inclusive.
    public let startDate: Date?
    /// EXCLUSIVE.
    public let endDate: Date?

    public init(weekdayMask: Int, dayStartMinute: Int, dayEndMinute: Int, startDate: Date?, endDate: Date?) {
        self.weekdayMask = weekdayMask
        self.dayStartMinute = dayStartMinute
        self.dayEndMinute = dayEndMinute
        self.startDate = startDate
        self.endDate = endDate
    }
}

extension DealSchedule: Decodable {
    private enum CodingKeys: String, CodingKey {
        case weekdayMask, dayStartMinute, dayEndMinute, startDate, endDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The three minute/mask fields are REQUIRED — any one missing or wrong-typed throws,
        // which the caller (`Deal.init(from:)`) turns into "no schedule at all" (`nil`), never
        // a half-populated `DealSchedule`.
        weekdayMask = try container.decode(Int.self, forKey: .weekdayMask)
        dayStartMinute = try container.decode(Int.self, forKey: .dayStartMinute)
        dayEndMinute = try container.decode(Int.self, forKey: .dayEndMinute)

        // `startDate`/`endDate` are each independently optional; an unparseable individual
        // date string degrades to `nil` for just that field rather than invalidating the
        // whole schedule (a deliberate, narrower fallback than the "missing minute fields"
        // case above, since a schedule with only a weekday/time window and no date bounds is
        // still a perfectly valid, useful schedule).
        if let raw = try container.decodeIfPresent(String.self, forKey: .startDate) {
            startDate = DealISO8601.parse(raw)
        } else {
            startDate = nil
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .endDate) {
            endDate = DealISO8601.parse(raw)
        } else {
            endDate = nil
        }
    }
}

// MARK: - DealDiscount

/// The discount mechanic a deal applies. `kind` is the wire discriminator INSIDE this object
/// (matches the Phase A projector, which reads `discount.kind` and stores the whole object as
/// `payload`). Field names/shapes below are Station's OWN wire convention.
public enum DealDiscount: Sendable, Equatable {
    /// 0–100 scale.
    case flatPercentOff(percent: Decimal)
    /// Per quantity unit.
    case flatAmountOff(amount: Money)
    /// Per-ring target price.
    case fixedPrice(price: Money)
    case buyXGetYBonus(buyQty: Int, bonusQty: Int)
    case buyXGetYPercentOff(buyQty: Int, percentOff: Decimal)
    case tieredQty(tiers: [QtyTier])
    case mixedCase(tiers: [MixedCaseTier])
    case unlockBonusProduct(productId: String, quantity: Int)
    case unlockAmountOffCart(amount: Money)
    case unlockPercentOffCart(percent: Decimal)
    case bundle(components: [BundleComponent], bundlePrice: Money)
    /// Any of the 20 schema-legal `kind` strings that are NOT one of the 11 v1 (engine-
    /// applied) kinds above, OR a wholly unrecognized string. Decodes fine — this is
    /// schema-forward, engine-conservative — but `DealEngine` never fires it
    /// (`DealNotFiredReason.unsupportedKind`). The original `kind` string round-trips
    /// faithfully so a caller can still show/log what it was.
    case unsupported(kind: String)
}

/// One quantity-break tier for `.tieredQty`. Deliberately has NO `id` field — POS's own wire
/// shape leaks a `TieredPrice.id` that Station's clean convention drops.
public struct QtyTier: Sendable, Equatable {
    public let minQty: Int
    public let unitPrice: Money

    public init(minQty: Int, unitPrice: Money) {
        self.minQty = minQty
        self.unitPrice = unitPrice
    }
}

extension QtyTier: Decodable {
    private enum CodingKeys: String, CodingKey { case minQty, unitPrice }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minQty = try container.decode(Int.self, forKey: .minQty)
        let dollars = try container.decode(Decimal.self, forKey: .unitPrice)
        unitPrice = Money(decimalDollars: dollars)
    }
}

/// One quantity-break tier for `.mixedCase`.
public struct MixedCaseTier: Sendable, Equatable, Decodable {
    public let minQty: Int
    public let discountPercent: Decimal

    public init(minQty: Int, discountPercent: Decimal) {
        self.minQty = minQty
        self.discountPercent = discountPercent
    }
}

/// One product+quantity component of a `.bundle`.
public struct BundleComponent: Sendable, Equatable, Decodable {
    public let productId: String
    public let qty: Int

    public init(productId: String, qty: Int) {
        self.productId = productId
        self.qty = qty
    }
}

extension DealDiscount: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, percent, amount, price, buyQty, bonusQty, percentOff, tiers,
             productId, quantity, components, bundlePrice
    }

    /// The stored-number bounds (AmbixDeals 0.10.0). Every price and count a v1 kind carries
    /// must lie in the range the promotion editors accept (money `0...DraftValidation
    /// .maxAmountCents`, see `Money(storedDollars:)`; counts `1...DraftValidation.maxQuantity`
    /// as whole numbers, see `storedCount(_:)`). A value outside it makes THIS discount
    /// `.unsupported(kind:)`: the engine never fires it and the Studio never edits it, while
    /// the deal itself still decodes and lists, so it can be fixed or paused from the Portal.
    /// A required key that is absent or not a number still throws, exactly as before.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "flatPercentOff":
            self = .flatPercentOff(percent: try container.decode(Decimal.self, forKey: .percent))
        case "flatAmountOff":
            let amount = Money(storedDollars: try container.decode(Decimal.self, forKey: .amount))
            self = amount.map { .flatAmountOff(amount: $0) } ?? .unsupported(kind: kind)
        case "fixedPrice":
            let price = Money(storedDollars: try container.decode(Decimal.self, forKey: .price))
            self = price.map { .fixedPrice(price: $0) } ?? .unsupported(kind: kind)
        case "buyXGetYBonus":
            let buyQty = Self.storedCount(try container.decode(Double.self, forKey: .buyQty))
            let bonusQty = Self.storedCount(try container.decode(Double.self, forKey: .bonusQty))
            if let buyQty, let bonusQty {
                self = .buyXGetYBonus(buyQty: buyQty, bonusQty: bonusQty)
            } else {
                self = .unsupported(kind: kind)
            }
        case "buyXGetYPercentOff":
            let buyQty = Self.storedCount(try container.decode(Double.self, forKey: .buyQty))
            let percentOff = try container.decode(Decimal.self, forKey: .percentOff)
            self = buyQty.map { .buyXGetYPercentOff(buyQty: $0, percentOff: percentOff) } ?? .unsupported(kind: kind)
        case "tieredQty":
            let stored = try container.decode([StoredQtyTier].self, forKey: .tiers)
            let tiers = stored.compactMap { tier -> QtyTier? in
                guard let minQty = Self.storedCount(tier.minQty),
                      let unitPrice = Money(storedDollars: tier.unitPrice) else { return nil }
                return QtyTier(minQty: minQty, unitPrice: unitPrice)
            }
            self = tiers.count == stored.count ? .tieredQty(tiers: tiers) : .unsupported(kind: kind)
        case "mixedCase":
            let stored = try container.decode([StoredMixedCaseTier].self, forKey: .tiers)
            let tiers = stored.compactMap { tier in
                Self.storedCount(tier.minQty).map { MixedCaseTier(minQty: $0, discountPercent: tier.discountPercent) }
            }
            self = tiers.count == stored.count ? .mixedCase(tiers: tiers) : .unsupported(kind: kind)
        case "unlockBonusProduct":
            let productId = try container.decode(String.self, forKey: .productId)
            // NOT `try container.decode(Int.self, …)` — see `decodedGrantQuantity`.
            self = .unlockBonusProduct(
                productId: productId,
                quantity: Self.decodedGrantQuantity(container)
            )
        case "unlockAmountOffCart":
            let amount = Money(storedDollars: try container.decode(Decimal.self, forKey: .amount))
            self = amount.map { .unlockAmountOffCart(amount: $0) } ?? .unsupported(kind: kind)
        case "unlockPercentOffCart":
            self = .unlockPercentOffCart(percent: try container.decode(Decimal.self, forKey: .percent))
        case "bundle":
            let stored = try container.decode([StoredBundleComponent].self, forKey: .components)
            let price = Money(storedDollars: try container.decode(Decimal.self, forKey: .bundlePrice))
            let components = stored.compactMap { component in
                Self.storedCount(component.qty).map { BundleComponent(productId: component.productId, qty: $0) }
            }
            if let price, components.count == stored.count {
                self = .bundle(components: components, bundlePrice: price)
            } else {
                self = .unsupported(kind: kind)
            }
        default:
            // Unknown OR one of the 9 non-v1 (decode-only) kinds land here — decodes fine,
            // `DealEngine` never fires it. See the case's own doc comment.
            self = .unsupported(kind: kind)
        }
    }

    /// A stored count (`buyQty`, `bonusQty`, a tier's `minQty`, a bundle component's `qty`):
    /// a whole number in `1...DraftValidation.maxQuantity`, else `nil`. Read as a `Double` so
    /// a fractional or very large stored number reaches this check instead of failing the
    /// whole document.
    private static func storedCount(_ value: Double) -> Int? {
        guard value >= 1, value <= Double(DraftValidation.maxQuantity), value.rounded() == value else { return nil }
        return Int(value)
    }

    /// `unlockBonusProduct.quantity`, decoded DORMANT-on-anything-unusable rather than
    /// throwing, with its own lower ceiling. The discount's other counts go through
    /// `storedCount(_:)` (1...`DraftValidation.maxQuantity`, the whole discount dormant on a
    /// miss); this one differs for two reasons that both point the same direction:
    ///
    /// 1. **It is a GRANT, not a threshold.** The other counts (`buyQty`, `bonusQty`, tier
    ///    `minQty`, bundle `qty`) are thresholds. This one is the number of
    ///    free units handed out, bounded only by the cart (`unlockBonusProductOutcome`), so a
    ///    runaway value is maximally GENEROUS: it discounts every matching pack in every cart.
    ///    Anything past `DraftValidation.maxGrantQuantity` is therefore neutralized to `0`,
    ///    where the engine's own `guard quantity > 0` makes the deal inert.
    /// 2. **A throw here costs the WHOLE document.** `Deal.init(from:)` reads `discount` with a
    ///    bare `try` (not the `try?` that `scope`/`condition`/`schedule` get), so one
    ///    unrepresentable number — a JS-authored `1e23`, a `2.5` in an integer field, a value
    ///    past `Int64` — used to fail the entire deal doc. That deal then vanishes from every
    ///    register while the portal still lists it **Active**: strictly worse than a dormant
    ///    deal, because a dormant deal stays visible and diagnosable. Verified: `try?` on the
    ///    container recovers cleanly from all three; the document itself parses fine.
    ///
    /// A NEGATIVE quantity is passed through unchanged (`guard quantity > 0` already makes it
    /// inert) so a stored value still round-trips faithfully for anyone logging it.
    ///
    /// The authoring-side twin is `DraftValidation.grantQuantity(_:)`, which BLOCKS the save
    /// and tells the manager instead of silently landing on `0` — an author should be
    /// corrected; a register should never lose a document.
    private static func decodedGrantQuantity(_ container: KeyedDecodingContainer<CodingKeys>) -> Int {
        // `try?` FLATTENS the `Int??` here, so one `guard let` covers both "the key is absent"
        // and "the value is present but unusable" — the two land on the same dormant `0`.
        guard let quantity = try? container.decodeIfPresent(Int.self, forKey: .quantity) else {
            return 0
        }
        return quantity <= DraftValidation.maxGrantQuantity ? quantity : 0
    }
}

/// A `tieredQty` tier as stored, before its count and price are judged (`DealDiscount.init(from:)`).
private struct StoredQtyTier: Decodable {
    let minQty: Double
    let unitPrice: Decimal
}

/// A `mixedCase` tier as stored, before its count is judged.
private struct StoredMixedCaseTier: Decodable {
    let minQty: Double
    let discountPercent: Decimal
}

/// A `bundle` component as stored, before its count is judged.
private struct StoredBundleComponent: Decodable {
    let productId: String
    let qty: Double
}

// MARK: - Decimal-dollars -> Money (never a Double round-trip)

private extension Money {
    /// `dollars` scaled to cents and rounded half-up, still as a `Decimal`, so a range check
    /// can judge the stored value itself before anything converts it to `Int`.
    static func roundedCents(_ dollars: Decimal) -> Decimal {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return rounded
    }

    /// A stored price or amount, or `nil` when its cents lie outside
    /// `0...DraftValidation.maxAmountCents` (the range every promotion editor accepts).
    init?(storedDollars dollars: Decimal) {
        let cents = Self.roundedCents(dollars)
        guard cents >= 0, cents <= Decimal(DraftValidation.maxAmountCents) else { return nil }
        self.init(cents: (cents as NSDecimalNumber).intValue)
    }

    /// A stored threshold held to `0...DraftValidation.maxAmountCents`.
    init(clampedStoredDollars dollars: Decimal) {
        let cents = min(max(Self.roundedCents(dollars), 0), Decimal(DraftValidation.maxAmountCents))
        self.init(cents: (cents as NSDecimalNumber).intValue)
    }

    /// Builds `Money` from a wire dollar amount that decoded straight into `Decimal` (JSON
    /// numbers decode into `Decimal` without an intermediate `Double`, so `9.99`/`33.33`
    /// round-trip to the exact cent). Deliberately does NOT go through `Money(dollars:)`,
    /// which takes a `Double` and would reintroduce binary-float error for values like these.
    init(decimalDollars dollars: Decimal) {
        self.init(cents: (Self.roundedCents(dollars) as NSDecimalNumber).intValue)
    }
}

// MARK: - Local ISO-8601 parsing (Core cannot import the App's FirestoreValue helpers)

/// Deal's OWN copy of the house "fractional-seconds first, then plain" ISO-8601 fallback
/// (mirrors `DailySaleDecoder.DailyDate` / `FirestoreValue.iso8601` elsewhere in Core), kept
/// LOCAL to this file rather than shared: `AmbixStationCore` is Foundation-only, so nothing
/// here strictly requires it to live elsewhere, but duplicating the two formatters keeps
/// `Deal.swift` a self-contained wire model with zero coupling to other Core modules'
/// decode helpers.
private enum DealISO8601 {
    /// `nonisolated(unsafe)`: configured once here, then only ever read via the thread-safe
    /// `date(from:)` — never reconfigured — so shared concurrent reads are safe even though
    /// `ISO8601DateFormatter` is not `Sendable` (same rationale as `FirestoreValue.iso8601`).
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}
