import Foundation

/// The Deals Studio's own editable/validated authoring model — NOT `Deal` itself. `Deal`
/// stays `Decodable`-only with its fail-closed/fail-open decode semantics (garbage scope ->
/// match-nothing, garbage condition -> always) intact as the REGISTER's safety net; a draft
/// wants Save DISABLED on bad input instead, never a silent fallback. Every numeric field a
/// manager types lives here as a `String` buffer (the `OrderDiscountModel` string-buffer
/// pattern) so a half-typed "12." or an empty field can be held in the UI without forcing a
/// premature parse — `validationErrors`/`canSave` are the only gate on whether `mirrorWrite()`
/// may run.
///
/// THE LOCKSTEP INVARIANT (the whole point of this type): for every one of the 11 v1 kinds,
/// and every scope/condition/schedule variant, `mirrorWrite().fields` must decode via
/// `Deal.init(from:)` to EXACTLY the `Deal` the manager intended. `mirrorWrite()` therefore
/// builds its wire shape field-for-field against `Deal.swift`'s own decode
/// (scope :181-200, condition :212-232, schedule :260-290, discount :365-414) — this file is
/// the ENCODE-side twin of that DECODE-side contract, never an independent guess at the shape.
///
/// THE ABSENT-vs-NULL RULE ON THE WIRE (read before touching `mirrorWrite()`): every
/// `MirrorWrite` this codebase produces is written via `FirestoreRelay.apply`'s
/// `setData(fields, merge: true)` (`App/Firebase/FirestoreRelay.swift:53`), where an ABSENT
/// key is left untouched on the stored doc and an EXPLICIT `.null` overwrites it. Those two
/// are NOT interchangeable for a complete-doc editor, and this type uses each deliberately:
///
/// - A field the Studio OWNS but the manager has CLEARED (schedule off, coupon emptied,
///   margin-floor override toggled off, a schedule start/end date switched off) emits
///   `.null`. Omitting it would silently preserve the stale stored value, making every one of
///   those clear actions a no-op on an existing deal — the `StoreInfo.mirrorWrite()` idiom
///   (`Contracts/StoreInfo.swift:291-298`: `.textOrNull(...)` per optional string,
///   `location.map { … } ?? .null`) is the house precedent, and this type follows it.
/// - A field the Studio does NOT own (`memberDiscount`, and anything a Portal or future tool
///   authors that this type has never heard of) stays ABSENT so `merge: true` leaves it
///   exactly as it was. NEVER null one of those.
/// - Nested maps (`discount`/`scope`/`condition`/`schedule`) are merged KEY BY KEY by
///   Firestore, not replaced wholesale, so a kind/shape switch would otherwise strand the old
///   shape's siblings inside them (a `tiers` array surviving into a `flatPercentOff` payload).
///   Each nested map is therefore emitted COMPLETE over its own known key vocabulary — every
///   key the matching `Deal.swift` decoder knows, with `.null` for the ones this shape doesn't
///   use. `Catalog.swift:72-74`'s omit-don't-null rule is the OPPOSITE case (a partial edit
///   model where `nil` means "not hydrated"), and does not apply here.
///
/// Decode is unaffected either way: `Deal.init(from:)` reads every optional through
/// `decodeIfPresent`, which treats an explicit JSON `null` and a missing key identically.
///
/// Deliberately NOT ported here: `Deal.memberDiscount` — the Studio has no view/edit access to
/// it in v1 (loyalty-coupled authoring is v2, design doc §1 O-2d), so `mirrorWrite()` never
/// emits a `memberDiscount` key at all. This is safe rather than lossy, per the second bullet
/// above — the SAME reasoning `DealActiveUpdate`'s own doc comment gives for why its one-key
/// merge "can never null anything out." A Studio save of a deal that already carries a
/// `memberDiscount` (e.g. Portal-authored) therefore leaves it exactly as it was: still absent
/// from THIS write's payload, but never stripped from the stored doc. A future task adds
/// member-upgrade VIEWING/authoring on top of this same type; until then, the field simply
/// survives untouched underneath whatever the Studio does edit.
public struct DealDraft: Sendable, Equatable {
    /// Existing id on edit; the caller mints a new one (`UUID().uuidString.lowercased()`,
    /// the `DurableRelayQueue.newId` convention) for a brand-new deal.
    public var id: String
    public var name: String = ""
    public var isActive: Bool = true
    public var channel: DealChannel = .inStore
    public var audience: DealAudience = .any
    public var discount: DraftDiscount = .flatPercentOff(percent: "")
    public var scope: DraftScope = .all
    public var condition: DraftCondition = .always
    public var scheduleEnabled: Bool = false
    public var schedule: DraftSchedule = .init()
    /// Raw as the manager is currently typing it — normalized (trim + uppercase) ONLY at
    /// `mirrorWrite()` time, never mutated here, so the editor can show the live-uppercase
    /// preview without fighting the text field's own cursor/selection state.
    public var couponCode: String = ""
    public var perCustomerLimit: Int = 0
    public var usageLimit: Int = 0
    public var marginFloorOverride: Money? = nil

    public init(id: String) {
        self.id = id
    }

    /// COMPLETE seeding for edit — every field round-trips, including the ones with no
    /// natural inverse elsewhere (schedule minute/date fields, coupon RAW as stored — see
    /// its own doc comment above for why normalization waits for save).
    ///
    /// FAILABLE, and that is the whole point (final-review I3): a `Deal` whose discount is
    /// `.unsupported` — one of the 9 decode-only kinds, or a wholly unrecognized wire string —
    /// has NO Studio representation, and this Studio never authors those (design doc §1 O-2d).
    /// Returning `nil` makes "silently convert a Portal-authored `giftCardTopUp` into a blank
    /// percent-off deal" structurally impossible rather than merely discouraged; the list
    /// (`DealsStudioView`) refuses the row tap for the same reason, so this `nil` is the
    /// belt-and-braces second gate, not the only one.
    public init?(from deal: Deal) {
        guard let seededDiscount = DraftDiscount(deal.discount) else { return nil }
        id = deal.id
        name = deal.name
        isActive = deal.isActive
        channel = deal.channel
        audience = deal.audience
        discount = seededDiscount
        scope = DraftScope(deal.scope)
        condition = DraftCondition(deal.condition)
        if let deviceSchedule = deal.schedule {
            scheduleEnabled = true
            schedule = DraftSchedule(
                weekdayMask: deviceSchedule.weekdayMask,
                dayStartMinute: deviceSchedule.dayStartMinute,
                dayEndMinute: deviceSchedule.dayEndMinute,
                startDate: deviceSchedule.startDate,
                endDate: deviceSchedule.endDate
            )
        } else {
            scheduleEnabled = false
            schedule = DraftSchedule()
        }
        couponCode = deal.couponCode ?? ""
        perCustomerLimit = deal.perCustomerLimit
        usageLimit = deal.usageLimit
        marginFloorOverride = deal.marginFloorOverrideCents.map { Money(cents: $0) }
    }

    /// One case per Global-Constraints validation rule that currently fails. Empty means
    /// `canSave`. Recomputed on every access (no cached/stale state) — the same purity
    /// discipline as `OrderDiscountModel`'s computed totals.
    public var validationErrors: [DraftError] {
        var errors: [DraftError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.nameRequired)
        }
        errors.append(contentsOf: discount.validationErrors())
        errors.append(contentsOf: scope.validationErrors())
        errors.append(contentsOf: condition.validationErrors())
        if scheduleEnabled {
            errors.append(contentsOf: schedule.validationErrors())
        }
        if perCustomerLimit < 0 { errors.append(.perCustomerLimitNegative) }
        if usageLimit < 0 { errors.append(.usageLimitNegative) }
        if let marginFloorOverride {
            // The margin floor is the one money field the editor hands over already
            // cents-backed (a `DealMoneyField` `Binding<Money>`, not a string buffer), so it
            // needs BOTH bounds checked here directly rather than through `amountError`:
            // `Money(dollars:)` clamps a runaway paste to `Int.max` cents, which is positive
            // and would otherwise sail through a lower-bound-only rule (final-review I2).
            if marginFloorOverride.cents < 0 {
                errors.append(.marginFloorOverrideNegative)
            } else if marginFloorOverride.cents > DraftValidation.maxAmountCents {
                errors.append(.amountTooLarge)
            }
        }
        return errors
    }

    public var canSave: Bool { validationErrors.isEmpty }

    /// PRECONDITION `canSave`. Builds the full-doc `MirrorWrite` (collection `"deals"`,
    /// documentID `id`) whose fields decode via `Deal.init(from:)` to exactly the intended
    /// `Deal` — the lockstep invariant this whole type exists to guarantee.
    ///
    /// `"id"` is written INSIDE `fields` too (not just as `documentID`) because `Deal.id` is
    /// a required, non-defaulted decode field (`Deal.swift`'s design-doc-documented "doc id
    /// mirror" — `DealsStore.decode`'s `sanitizedDocument` re-injects the true Firestore
    /// document id defensively on READ, but the doc body itself still carries its own copy,
    /// exactly like every other writer in this codebase that mirrors its own id).
    ///
    /// Always a COMPLETE doc over the fields this Studio OWNS — every one of them is present
    /// on every save, carrying `.null` when the manager cleared it, so a clear is a real
    /// clear under `merge: true` rather than a silent no-op. Fields the Studio does NOT own
    /// (`memberDiscount`, anything Portal-authored) stay ABSENT and survive untouched. See the
    /// type's own "THE ABSENT-vs-NULL RULE ON THE WIRE" doc section above — that rule is the
    /// contract this method implements, and it is the opposite of `Catalog.swift:72-74`'s
    /// omit-don't-null rule for partial edit models. The lone single-field exception in this
    /// file is `DealActiveUpdate` below.
    public func mirrorWrite() -> MirrorWrite {
        precondition(canSave, "DealDraft.mirrorWrite() called while canSave is false — validate before saving")

        let normalizedCoupon = couponCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let fields: [String: FirestoreValue] = [
            "id": .string(id),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "isActive": .bool(isActive),
            "channel": .string(channel.rawValue),
            "audience": .string(audience.rawValue),
            "discount": .map(discount.wireFields() ?? [:]),
            "scope": .map(scope.wireFields()),
            "condition": .map(condition.wireFields() ?? [:]),
            "perCustomerLimit": .int(perCustomerLimit),
            "usageLimit": .int(usageLimit),
            // Schedule OFF clears the whole stored map (a nested `.map` merge would otherwise
            // leave the old window in place and the deal still time-locked).
            "schedule": scheduleEnabled ? .map(schedule.wireFields()) : .null,
            // `.textOrNull` is the house helper for exactly this (StoreInfo.swift:291-294):
            // a cleared coupon must un-gate the deal, not leave it silently coupon-locked.
            "couponCode": .textOrNull(normalizedCoupon),
            // Toggling "Override margin floor" off must restore the item's real cost floor —
            // a preserved stale override is below-cost selling the manager believes they
            // turned off.
            "marginFloorOverrideCents": marginFloorOverride.map { .int($0.cents) } ?? .null,
        ]
        return MirrorWrite(collection: "deals", documentID: id, fields: fields)
    }
}

// MARK: - DraftDiscount

/// Mirrors `DealDiscount`'s 11 v1 (engine-applied) cases exactly — the Studio never authors
/// the 9 decode-only kinds or an `.unsupported` payload, so unlike `DealDiscount` there is no
/// 12th case here. Every user-typed numeric is a `String` buffer; `tieredQty`/`mixedCase`/
/// `bundle` hold `[Draft…]` element arrays instead of `Deal.swift`'s plain structs, again all
/// string-buffered.
public enum DraftDiscount: Sendable, Equatable {
    case flatPercentOff(percent: String)
    case flatAmountOff(amount: String)
    case fixedPrice(price: String)
    case buyXGetYBonus(buyQty: String, bonusQty: String)
    case buyXGetYPercentOff(buyQty: String, percentOff: String)
    case tieredQty(tiers: [DraftQtyTier])
    case mixedCase(tiers: [DraftMixedCaseTier])
    case unlockBonusProduct(productId: String, quantity: String)
    case unlockAmountOffCart(amount: String)
    case unlockPercentOffCart(percent: String)
    case bundle(components: [DraftBundleComponent], bundlePrice: String)

    /// Every payload key `Deal.swift`'s `DealDiscount.CodingKeys` knows (:365-368) EXCEPT the
    /// `kind` discriminator itself — the complete vocabulary a `discount` map may ever carry.
    /// Kept in lockstep with that `CodingKeys` list, not with this type's own cases: the point
    /// is to name every key a stored doc could already be holding, so `completed(_:)` below can
    /// clear the ones the CURRENT kind doesn't use.
    private static let payloadKeys = [
        "percent", "amount", "price", "buyQty", "bonusQty", "percentOff",
        "tiers", "productId", "quantity", "components", "bundlePrice",
    ]

    /// Firestore's `setData(merge: true)` merges a nested map KEY BY KEY rather than replacing
    /// it, so switching a deal from `tieredQty` to `flatPercentOff` would leave the old `tiers`
    /// array sitting inside the merged `discount` map — a payload carrying two kinds' fields at
    /// once. Station's own decode is discriminator-driven and ignores the strays, but the
    /// AmbixServer projector stores this WHOLE object as `deals.payload` and Daisho reads the
    /// same doc, so the wire shape has to be honest. Padding the emitted payload with an
    /// explicit `.null` for every key this kind doesn't use makes each save REPLACE the map's
    /// full known vocabulary, which is the closest a `merge: true` write can get to a wholesale
    /// replacement without changing the shared relay. Unknown-to-Station keys inside `discount`
    /// (a future kind's payload) are deliberately NOT nulled — same "never clear what you don't
    /// own" rule the type doc states for top-level keys.
    private static func completed(_ payload: [String: FirestoreValue]) -> [String: FirestoreValue] {
        var fields = payload
        for key in payloadKeys where fields[key] == nil {
            fields[key] = .null
        }
        return fields
    }

    /// `{"kind": .string(...), ...payload}` field-for-field against `Deal.swift:365-414`,
    /// padded to the full known key vocabulary per `completed(_:)` above. `nil` when this
    /// case's own buffers don't parse/satisfy their bound — the SAME check
    /// `validationErrors()` uses, so a `nil` here can only happen when `canSave` is already
    /// false (never independently).
    func wireFields() -> [String: FirestoreValue]? {
        guard let payload = kindPayload() else { return nil }
        return Self.completed(payload)
    }

    /// This kind's OWN keys only (`kind` + its payload) — `wireFields()` pads the rest.
    private func kindPayload() -> [String: FirestoreValue]? {
        switch self {
        case .flatPercentOff(let percent):
            guard let value = DraftValidation.percent(percent) else { return nil }
            return ["kind": .string("flatPercentOff"), "percent": percentWireValue(value)]

        case .flatAmountOff(let amount):
            guard let value = DraftValidation.positiveDecimal(amount) else { return nil }
            return ["kind": .string("flatAmountOff"), "amount": moneyWireValue(value)]

        case .fixedPrice(let price):
            guard let value = DraftValidation.positiveDecimal(price) else { return nil }
            return ["kind": .string("fixedPrice"), "price": moneyWireValue(value)]

        case .buyXGetYBonus(let buyQty, let bonusQty):
            guard let buy = DraftValidation.positiveInt(buyQty),
                  let bonus = DraftValidation.positiveInt(bonusQty)
            else { return nil }
            return ["kind": .string("buyXGetYBonus"), "buyQty": .int(buy), "bonusQty": .int(bonus)]

        case .buyXGetYPercentOff(let buyQty, let percentOff):
            guard let buy = DraftValidation.positiveInt(buyQty),
                  let percent = DraftValidation.percent(percentOff)
            else { return nil }
            return ["kind": .string("buyXGetYPercentOff"), "buyQty": .int(buy), "percentOff": percentWireValue(percent)]

        case .tieredQty(let tiers):
            guard !tiers.isEmpty else { return nil }
            var wireTiers: [FirestoreValue] = []
            for tier in tiers {
                guard let minQty = DraftValidation.positiveInt(tier.minQty),
                      let unitPrice = DraftValidation.positiveDecimal(tier.unitPrice)
                else { return nil }
                wireTiers.append(.map(["minQty": .int(minQty), "unitPrice": moneyWireValue(unitPrice)]))
            }
            return ["kind": .string("tieredQty"), "tiers": .array(wireTiers)]

        case .mixedCase(let tiers):
            guard !tiers.isEmpty else { return nil }
            var wireTiers: [FirestoreValue] = []
            for tier in tiers {
                guard let minQty = DraftValidation.positiveInt(tier.minQty),
                      let discountPercent = DraftValidation.percent(tier.discountPercent)
                else { return nil }
                wireTiers.append(.map(["minQty": .int(minQty), "discountPercent": percentWireValue(discountPercent)]))
            }
            return ["kind": .string("mixedCase"), "tiers": .array(wireTiers)]

        case .unlockBonusProduct(let productId, let quantity):
            guard let rewardId = DraftValidation.nonEmptyWireId(productId),
                  let qty = DraftValidation.grantQuantity(quantity)
            else { return nil }
            return ["kind": .string("unlockBonusProduct"), "productId": .string(rewardId), "quantity": .int(qty)]

        case .unlockAmountOffCart(let amount):
            guard let value = DraftValidation.positiveDecimal(amount) else { return nil }
            return ["kind": .string("unlockAmountOffCart"), "amount": moneyWireValue(value)]

        case .unlockPercentOffCart(let percent):
            guard let value = DraftValidation.percent(percent) else { return nil }
            return ["kind": .string("unlockPercentOffCart"), "percent": percentWireValue(value)]

        case .bundle(let components, let bundlePrice):
            guard bundleComponentsAreDistinct(components) else { return nil }
            var wireComponents: [FirestoreValue] = []
            for component in components {
                guard let qty = DraftValidation.positiveInt(component.qty) else { return nil }
                wireComponents.append(.map([
                    "productId": .string(DraftValidation.wireId(component.productId)),
                    "qty": .int(qty),
                ]))
            }
            guard let price = DraftValidation.positiveDecimal(bundlePrice) else { return nil }
            return ["kind": .string("bundle"), "components": .array(wireComponents), "bundlePrice": moneyWireValue(price)]
        }
    }

    /// One `DraftError` per bound in Global Constraints. Uses the SAME `DraftValidation`
    /// parse/bound helpers `wireFields()` does, so the two can never silently disagree about
    /// what counts as valid. Every DOLLAR field routes through the shared
    /// `DraftValidation.amountError(_:otherwise:)` helper so the lower bound (`> $0`) and the
    /// upper bound (`DraftValidation.maxAmountDollars`) are reported as distinct,
    /// correctly-worded errors.
    func validationErrors() -> [DraftError] {
        switch self {
        case .flatPercentOff(let percent):
            return DraftValidation.percent(percent) == nil ? [.percentInvalid] : []

        case .flatAmountOff(let amount), .unlockAmountOffCart(let amount):
            return DraftValidation.amountError(amount, otherwise: .amountInvalid).map { [$0] } ?? []

        case .fixedPrice(let price):
            return DraftValidation.amountError(price, otherwise: .amountInvalid).map { [$0] } ?? []

        case .unlockPercentOffCart(let percent):
            return DraftValidation.percent(percent) == nil ? [.percentInvalid] : []

        case .buyXGetYBonus(let buyQty, let bonusQty):
            var errors: [DraftError] = []
            if DraftValidation.positiveInt(buyQty) == nil { errors.append(.buyQtyInvalid) }
            if DraftValidation.positiveInt(bonusQty) == nil { errors.append(.bonusQtyInvalid) }
            return errors

        case .buyXGetYPercentOff(let buyQty, let percentOff):
            var errors: [DraftError] = []
            if DraftValidation.positiveInt(buyQty) == nil { errors.append(.buyQtyInvalid) }
            if DraftValidation.percent(percentOff) == nil { errors.append(.percentInvalid) }
            return errors

        case .tieredQty(let tiers):
            guard !tiers.isEmpty else { return [.tiersEmpty] }
            var errors: [DraftError] = []
            for tier in tiers {
                if DraftValidation.positiveInt(tier.minQty) == nil { errors.append(.tierMinQtyInvalid) }
                if let error = DraftValidation.amountError(tier.unitPrice, otherwise: .tierUnitPriceInvalid) { errors.append(error) }
            }
            return errors

        case .mixedCase(let tiers):
            guard !tiers.isEmpty else { return [.tiersEmpty] }
            var errors: [DraftError] = []
            for tier in tiers {
                if DraftValidation.positiveInt(tier.minQty) == nil { errors.append(.tierMinQtyInvalid) }
                if DraftValidation.percent(tier.discountPercent) == nil { errors.append(.percentInvalid) }
            }
            return errors

        case .unlockBonusProduct(let productId, let quantity):
            var errors: [DraftError] = []
            if DraftValidation.nonEmptyWireId(productId) == nil {
                errors.append(.unlockBonusProductMissing)
            }
            if DraftValidation.grantQuantity(quantity) == nil { errors.append(.unlockBonusProductQuantityInvalid) }
            return errors

        case .bundle(let components, let bundlePrice):
            var errors: [DraftError] = []
            if !bundleComponentsAreDistinct(components) { errors.append(.bundleNeedsTwoDistinctProducts) }
            for component in components where DraftValidation.positiveInt(component.qty) == nil {
                errors.append(.bundleComponentQtyInvalid)
            }
            if let error = DraftValidation.amountError(bundlePrice, otherwise: .amountInvalid) { errors.append(error) }
            return errors
        }
    }
}

extension DraftDiscount {
    /// Seeds every one of the 11 v1 cases from its `Deal.swift` counterpart, formatting each
    /// `Decimal`/`Money`/`Int` back into a clean, re-parseable `String` buffer.
    ///
    /// FAILABLE (final-review I3): `Deal.discount == .unsupported` (one of the 9 decode-only
    /// kinds, or truly unrecognized) has NO Studio representation, and this Studio never
    /// authors those (design doc §1 O-2d). Earlier this reset to an empty `.flatPercentOff("")`
    /// — which silently offered to REWRITE a Portal-authored `giftCardTopUp` deal as a
    /// percent-off deal the moment the manager picked a kind and saved. There is no honest
    /// draft for an unsupported kind, so there is no draft at all: `nil`.
    init?(_ discount: DealDiscount) {
        switch discount {
        case .flatPercentOff(let percent):
            self = .flatPercentOff(percent: percent.description)
        case .flatAmountOff(let amount):
            self = .flatAmountOff(amount: Self.dollarsString(amount))
        case .fixedPrice(let price):
            self = .fixedPrice(price: Self.dollarsString(price))
        case .buyXGetYBonus(let buyQty, let bonusQty):
            self = .buyXGetYBonus(buyQty: String(buyQty), bonusQty: String(bonusQty))
        case .buyXGetYPercentOff(let buyQty, let percentOff):
            self = .buyXGetYPercentOff(buyQty: String(buyQty), percentOff: percentOff.description)
        case .tieredQty(let tiers):
            self = .tieredQty(tiers: tiers.map {
                DraftQtyTier(minQty: String($0.minQty), unitPrice: Self.dollarsString($0.unitPrice))
            })
        case .mixedCase(let tiers):
            self = .mixedCase(tiers: tiers.map {
                DraftMixedCaseTier(minQty: String($0.minQty), discountPercent: $0.discountPercent.description)
            })
        case .unlockBonusProduct(let productId, let quantity):
            self = .unlockBonusProduct(productId: productId, quantity: String(quantity))
        case .unlockAmountOffCart(let amount):
            self = .unlockAmountOffCart(amount: Self.dollarsString(amount))
        case .unlockPercentOffCart(let percent):
            self = .unlockPercentOffCart(percent: percent.description)
        case .bundle(let components, let bundlePrice):
            self = .bundle(
                components: components.map { DraftBundleComponent(productId: $0.productId, qty: String($0.qty)) },
                bundlePrice: Self.dollarsString(bundlePrice)
            )
        case .unsupported:
            return nil
        }
    }

    private static func dollarsString(_ money: Money) -> String {
        (Decimal(money.cents) / Decimal(100)).description
    }
}

/// Shared by both `wireFields()` and `validationErrors()` above: at least 2 components, every
/// `productId` trimmed non-empty, and every trimmed id DISTINCT.
private func bundleComponentsAreDistinct(_ components: [DraftBundleComponent]) -> Bool {
    guard components.count >= 2 else { return false }
    let trimmed = components.map { DraftValidation.wireId($0.productId) }
    guard trimmed.allSatisfy({ !$0.isEmpty }) else { return false }
    return Set(trimmed).count == components.count
}

// MARK: - Tier / component element types

/// One `tieredQty` tier. Deliberately has NO `id` field, matching `QtyTier`'s own
/// no-`id` convention (`Deal.swift`'s doc comment: POS's wire shape leaks a `TieredPrice.id`
/// this codebase's clean convention drops).
public struct DraftQtyTier: Sendable, Equatable {
    public var minQty: String
    public var unitPrice: String

    public init(minQty: String = "", unitPrice: String = "") {
        self.minQty = minQty
        self.unitPrice = unitPrice
    }
}

/// One `mixedCase` tier.
public struct DraftMixedCaseTier: Sendable, Equatable {
    public var minQty: String
    public var discountPercent: String

    public init(minQty: String = "", discountPercent: String = "") {
        self.minQty = minQty
        self.discountPercent = discountPercent
    }
}

/// One `bundle` component.
public struct DraftBundleComponent: Sendable, Equatable {
    public var productId: String
    public var qty: String

    public init(productId: String = "", qty: String = "") {
        self.productId = productId
        self.qty = qty
    }
}

// MARK: - DraftScope

/// Mirrors `DealScope` (`Deal.swift:174-200`). No user-typed numeric buffers — `names`/`ids`
/// come from a picker UI (category multi-select / product search-picker, Task 3), so unlike
/// `DraftDiscount`/`DraftCondition` this type's `wireFields()` never fails to build
/// structurally; only the ≥1-entry Global-Constraints bound can make the DRAFT invalid.
public enum DraftScope: Sendable, Equatable {
    case all
    /// O-2b ruling: category scope matches on category NAME, not id.
    case category(names: Set<String>)
    case products(ids: Set<String>)

    /// `{"type": ..., "ids": [String]}` against `Deal.swift:181-200`. `names`/`ids` are
    /// `Set`s with no defined iteration order, so both go through `DraftValidation.wireIdList`,
    /// which sorts ALPHABETICALLY before hitting the wire — the only way the round-tripped
    /// `Deal.scope`'s `[String]` array (order-sensitive `Equatable`) is deterministic and
    /// independent of the Set's internal hash-seeded order.
    ///
    /// That same helper is also what TRIMS each entry. A scope is matched byte-exact
    /// (`DealEngine.scopeMatches`: `ids.contains(line.productId)` / `names.contains(
    /// line.categoryName)`), so a padded `" sku-1 "` reaching Firestore would decode cleanly,
    /// pass the ≥1-entry bound, list as Active everywhere, and match nothing at any register.
    /// The picker UI is the only intended author of these sets, but "the picker never pads"
    /// is not an invariant this type can enforce — normalizing at the wire boundary is.
    ///
    /// `.all` emits an explicit `ids: .null` rather than omitting the key: nested maps merge
    /// key by key under `setData(merge: true)`, so narrowing a category/products scope back to
    /// "all products" would otherwise strand the old id list inside the stored `scope` map
    /// (final-review I1). `Deal`'s decode never reads `ids` for `type == "all"`, so the null is
    /// invisible to the register and merely keeps the stored doc honest.
    func wireFields() -> [String: FirestoreValue] {
        switch self {
        case .all:
            return ["type": .string("all"), "ids": .null]
        case .category(let names):
            return ["type": .string("category"), "ids": .array(DraftValidation.wireIdList(names).map { .string($0) })]
        case .products(let ids):
            return ["type": .string("products"), "ids": .array(DraftValidation.wireIdList(ids).map { .string($0) })]
        }
    }

    /// The ≥1-entry bound is checked against the NORMALIZED list `wireFields()` will actually
    /// emit, not the raw `Set` — otherwise a scope holding nothing but whitespace entries
    /// passes here and then emits an array that can never match a line.
    func validationErrors() -> [DraftError] {
        switch self {
        case .all:
            return []
        case .category(let names):
            return DraftValidation.wireIdList(names).isEmpty ? [.categoryScopeEmpty] : []
        case .products(let ids):
            return DraftValidation.wireIdList(ids).isEmpty ? [.productsScopeEmpty] : []
        }
    }
}

extension DraftScope {
    init(_ scope: DealScope) {
        switch scope {
        case .all: self = .all
        case .category(let names): self = .category(names: Set(names))
        case .products(let ids): self = .products(ids: Set(ids))
        }
    }
}

// MARK: - DraftCondition

/// Mirrors `DealCondition` (`Deal.swift:206-232`). `minQuantity`/`minSubtotal` are
/// string-buffered, like every user-typed numeric on this type.
public enum DraftCondition: Sendable, Equatable {
    case always
    case minQuantity(String)
    case minSubtotal(String)

    /// `{"type": ..., "value": ...}` against `Deal.swift:212-232`. `nil` when the buffer
    /// doesn't parse/satisfy its bound. `.always` emits an explicit `value: .null` for the same
    /// nested-map-merge reason `DraftScope.wireFields()` documents (final-review I1).
    func wireFields() -> [String: FirestoreValue]? {
        switch self {
        case .always:
            return ["type": .string("always"), "value": .null]
        case .minQuantity(let raw):
            guard let value = DraftValidation.positiveInt(raw) else { return nil }
            return ["type": .string("minQuantity"), "value": .int(value)]
        case .minSubtotal(let raw):
            guard let value = DraftValidation.positiveDecimal(raw) else { return nil }
            return ["type": .string("minSubtotal"), "value": moneyWireValue(value)]
        }
    }

    func validationErrors() -> [DraftError] {
        switch self {
        case .always:
            return []
        case .minQuantity(let raw):
            return DraftValidation.positiveInt(raw) == nil ? [.conditionMinQuantityInvalid] : []
        case .minSubtotal(let raw):
            return DraftValidation.amountError(raw, otherwise: .conditionMinSubtotalInvalid).map { [$0] } ?? []
        }
    }
}

extension DraftCondition {
    init(_ condition: DealCondition) {
        switch condition {
        case .always:
            self = .always
        case .minQuantity(let n):
            self = .minQuantity(String(n))
        case .minSubtotal(let amount):
            self = .minSubtotal((Decimal(amount.cents) / Decimal(100)).description)
        }
    }
}

// MARK: - DraftSchedule

/// Mirrors `DealSchedule` (`Deal.swift:239-290`). Minute/mask fields are plain `Int`s (not
/// string buffers — the editor drives them with steppers/chips, per the plan's Task 3 notes),
/// so unlike `DraftDiscount`/`DraftCondition` this type's `wireFields()` never fails to build
/// structurally; only the Global-Constraints ORDERING bounds (checked ONLY when
/// `DealDraft.scheduleEnabled`) can make the draft invalid.
public struct DraftSchedule: Sendable, Equatable {
    public var weekdayMask: Int
    public var dayStartMinute: Int
    public var dayEndMinute: Int
    public var startDate: Date?
    public var endDate: Date?

    public init(
        weekdayMask: Int = 127,
        dayStartMinute: Int = 0,
        dayEndMinute: Int = 1_440,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.weekdayMask = weekdayMask
        self.dayStartMinute = dayStartMinute
        self.dayEndMinute = dayEndMinute
        self.startDate = startDate
        self.endDate = endDate
    }

    /// `{"weekdayMask", "dayStartMinute", "dayEndMinute", "startDate", "endDate"}` against
    /// `Deal.swift:260-290`. Dates emit `.isoString` (matching the decoder's `DealISO8601`
    /// fractional-then-plain ISO path) and an explicit `.null` when absent — NOT omission
    /// (final-review C1). `Deal`'s own `decodeIfPresent` treats a missing key and an explicit
    /// JSON `null` identically on the READ side, so both decode the same; but this map is
    /// written into an existing doc under `setData(merge: true)`, where an omitted key leaves
    /// the previously-stored date in place. Turning an End date off would then leave the deal
    /// expiring on the old date — a real behavior change `Deal.init(from:)` reads straight
    /// through `schedule.endDate`.
    func wireFields() -> [String: FirestoreValue] {
        [
            "weekdayMask": .int(weekdayMask),
            "dayStartMinute": .int(dayStartMinute),
            "dayEndMinute": .int(dayEndMinute),
            "startDate": startDate.map { .isoString($0) } ?? .null,
            "endDate": endDate.map { .isoString($0) } ?? .null,
        ]
    }

    /// Only ever called by `DealDraft.validationErrors` when `scheduleEnabled` — a disabled
    /// schedule's ordering is never checked (and never reaches the wire either).
    func validationErrors() -> [DraftError] {
        var errors: [DraftError] = []
        if dayStartMinute >= dayEndMinute { errors.append(.scheduleWindowInvalid) }
        if let startDate, let endDate, endDate <= startDate { errors.append(.scheduleDateRangeInvalid) }
        return errors
    }
}

// MARK: - DealActiveUpdate

/// A status-ONLY write to an already-existing `deals/{dealId}` doc — the `SaleStatusUpdate`
/// single-field-merge precedent (`Sale.swift`'s `SaleStatusUpdate`), applied to the active
/// toggle. `FirestoreRelay` writes every `MirrorWrite` with `merge: true`, so this touches
/// ONLY `isActive`; every other field on the existing doc (discount, scope, schedule, …) is
/// left exactly as the last full `DealDraft.mirrorWrite()` wrote it. A one-key merge can never
/// null anything out.
public struct DealActiveUpdate: Sendable, MirrorEmitting {
    public static let collection = "deals"

    /// The target deal's document id.
    public let dealId: String
    public let isActive: Bool

    public init(dealId: String, isActive: Bool) {
        self.dealId = dealId
        self.isActive = isActive
    }

    public func mirrorWrite() -> MirrorWrite {
        MirrorWrite(collection: Self.collection, documentID: dealId, fields: ["isActive": .bool(isActive)])
    }
}

// MARK: - Wire-value builders (Decimal -> FirestoreValue, crossing to Double ONLY here)

/// A validated positive dollar `Decimal` -> cents-exact `Money` -> `.double(money.dollars)`,
/// the SAME wire convention `Sale.swift` already uses for every money field
/// (`.double(subtotal.dollars)` etc.) and the encode-side mirror of `Deal.swift`'s own private
/// `Money(decimalDollars:)` decode helper (replicated below, byte-for-byte, so a user-typed
/// dollar string round-trips to the identical cent on both sides of the wire).
///
/// `FirestoreValue` has no `Decimal`-preserving case (only `.double`), so crossing to `Double`
/// here is unavoidable — exactly the ONE place in this file it happens, matching `Money`'s own
/// "keep math in cents/Decimal; only cross to Double when building the doc" discipline.
private func moneyWireValue(_ dollars: Decimal) -> FirestoreValue {
    .double(Money(decimalDollars: dollars).dollars)
}

/// A validated percent `Decimal` (0-100 scale, no cents concept) -> `.double`.
private func percentWireValue(_ percent: Decimal) -> FirestoreValue {
    .double((percent as NSDecimalNumber).doubleValue)
}

private extension Money {
    /// Mirrors `Deal.swift`'s private `Money(decimalDollars:)` decode helper EXACTLY (same
    /// scale-by-100 + `NSDecimalRound(.plain)` rounding) — this is that helper's encode-side
    /// twin, kept as its own file-local copy for the same reason `Deal.swift`'s own doc
    /// comment gives for not sharing one across files: zero coupling between wire-model files.
    init(decimalDollars dollars: Decimal) {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        self.init(cents: (rounded as NSDecimalNumber).intValue)
    }
}
