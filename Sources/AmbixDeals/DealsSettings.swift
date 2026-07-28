import Foundation

/// Store-wide deals engine configuration — `stores/{storeId}/settings/deals`. Singleton
/// doc, the SAME `MirrorWrite` seam as `StoreInfo`/`CustomerDisplayConfig` (see
/// `Contracts/StoreInfo.swift`): authored once on any register's Settings sheet, read
/// live by every other register.
///
/// Deliberately fail-CLOSED, field by field:
/// - `dealsEngineEnabled` (O-1) missing/mistyped → `false`. A malformed or partial doc
///   must never silently turn the deals engine on.
/// - `allowBelowCost` (O-4) missing/mistyped → `false`. Mechanism A's post-hoc clamp
///   stays ON by default; only an explicit, correctly-typed `true` lifts it.
/// - `bonusUnitFloorCents` (O-4) missing/mistyped → `1`, and any decoded value is
///   further clamped to `max(1, value)` — Mechanism B's per-bonus-unit floor is NEVER
///   allowed to reach 0 (the "never literally free alcohol" invariant `CostFloorPolicy`
///   depends on; see that type's doc comment). A store cannot configure this away.
public struct DealsSettings: Sendable, Equatable, MirrorEmitting {
    public static let collection = "settings"
    public static let documentID = "deals"

    /// O-1: the master switch. Off means the deals engine plays no part in ringing a
    /// sale — no discounts computed, nothing traced.
    public let dealsEngineEnabled: Bool
    /// O-4: whether Mechanism A's post-hoc clamp (`max(0, lineTotal - floorBasis)`) is
    /// lifted for this store.
    public let allowBelowCost: Bool
    /// O-4: Mechanism B's per-bonus-unit floor, in cents. NEVER lifted by
    /// `allowBelowCost` — see `CostFloorPolicy`'s doc comment.
    public let bonusUnitFloorCents: Int

    public init(dealsEngineEnabled: Bool = false, allowBelowCost: Bool = false, bonusUnitFloorCents: Int = 1) {
        self.dealsEngineEnabled = dealsEngineEnabled
        self.allowBelowCost = allowBelowCost
        self.bonusUnitFloorCents = bonusUnitFloorCents
    }

    /// Maps this settings doc straight onto the `DealEngine` cost-floor policy it
    /// configures — the one seam between "what the store typed in Settings" and "what
    /// the engine actually enforces."
    public var costFloorPolicy: CostFloorPolicy {
        CostFloorPolicy(allowBelowCost: allowBelowCost, bonusUnitFloor: Money(cents: bonusUnitFloorCents))
    }

    public func mirrorWrite() -> MirrorWrite {
        MirrorWrite(collection: Self.collection, documentID: Self.documentID, fields: [
            "dealsEngineEnabled": .bool(dealsEngineEnabled),
            "allowBelowCost": .bool(allowBelowCost),
            "bonusUnitFloorCents": .int(bonusUnitFloorCents),
        ])
    }

    /// Total, tolerant decode from a Firestore document. Missing or mistyped fields fall
    /// back to their safe default (see the type doc comment for the direction each one
    /// fails in) — never throws, and never lets a malformed doc widen what the deals
    /// engine is allowed to do.
    public static func decode(_ raw: [String: Any]) -> DealsSettings {
        let dealsEngineEnabled = raw["dealsEngineEnabled"] as? Bool ?? false
        let allowBelowCost = raw["allowBelowCost"] as? Bool ?? false
        // Int-or-Double tolerant, matching `DailySaleDecoder`'s `unitsPerItem` decode —
        // Firestore hands whole numbers back as either depending on the writer.
        let floorCents = (raw["bonusUnitFloorCents"] as? Int)
            ?? Int((raw["bonusUnitFloorCents"] as? Double) ?? 1)
        return DealsSettings(
            dealsEngineEnabled: dealsEngineEnabled,
            allowBelowCost: allowBelowCost,
            bonusUnitFloorCents: max(1, floorCents)
        )
    }
}
