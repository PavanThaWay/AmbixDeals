import Foundation

/// The two INDEPENDENT cost floors the engine enforces (see `pos-engine-core.md` §2/§3 and
/// the plan's Global Constraints):
/// - Mechanism A (general post-hoc clamp, `max(0, lineTotal − floorBasis)`, `floorBasis` the
///   winning deal's `marginFloorOverrideCents` when present else `lineCost`) runs in the
///   merge/clamp pass — `allowBelowCost` lifts that one entirely.
/// - Mechanism B (`bonusUnitFloor`) is baked into the `buyXGetYBonus`/`unlockBonusProduct`
///   formulas themselves: `max(unitCost ?? .zero, bonusUnitFloor)`, which `allowBelowCost`
///   NEVER lifts (owner policy 2026-06-10, ABC "never literally free alcohol" compliance).
public struct CostFloorPolicy: Sendable, Equatable {
    public let allowBelowCost: Bool
    public let bonusUnitFloor: Money

    public init(allowBelowCost: Bool = false, bonusUnitFloor: Money = Money(cents: 1)) {
        self.allowBelowCost = allowBelowCost
        self.bonusUnitFloor = bonusUnitFloor
    }
}
