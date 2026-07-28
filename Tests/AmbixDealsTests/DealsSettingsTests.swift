import Foundation
import Testing

@testable import AmbixDeals

/// `DealsSettings` is the store-wide deals engine config — `stores/{storeId}/settings/deals`,
/// the same singleton-doc seam as `StoreInfo`/`CustomerDisplayConfig`. It is deliberately
/// fail-CLOSED: a missing, empty, or malformed doc must decode to the engine being OFF and
/// the cost floor at its strictest (never a mistyped/missing field silently turning deals or
/// below-cost pricing ON).
@Suite("DealsSettings")
struct DealsSettingsTests {

    // MARK: - Decode matrix: empty doc → all defaults, engine OFF

    @Test("empty doc decodes to all defaults, engine OFF")
    func emptyDocDecodesToDefaults() {
        let settings = DealsSettings.decode([:])
        #expect(settings.dealsEngineEnabled == false)
        #expect(settings.allowBelowCost == false)
        #expect(settings.bonusUnitFloorCents == 1)
    }

    @Test("dealsEngineEnabled decodes independently when present")
    func dealsEngineEnabledDecodesIndependently() {
        let settings = DealsSettings.decode(["dealsEngineEnabled": true])
        #expect(settings.dealsEngineEnabled == true)
        #expect(settings.allowBelowCost == false)
        #expect(settings.bonusUnitFloorCents == 1)
    }

    @Test("allowBelowCost decodes independently when present")
    func allowBelowCostDecodesIndependently() {
        let settings = DealsSettings.decode(["allowBelowCost": true])
        #expect(settings.allowBelowCost == true)
        #expect(settings.dealsEngineEnabled == false)
        #expect(settings.bonusUnitFloorCents == 1)
    }

    @Test("bonusUnitFloorCents decodes independently when present")
    func bonusUnitFloorCentsDecodesIndependently() {
        let settings = DealsSettings.decode(["bonusUnitFloorCents": 250])
        #expect(settings.bonusUnitFloorCents == 250)
        #expect(settings.dealsEngineEnabled == false)
        #expect(settings.allowBelowCost == false)
    }

    // MARK: - Mistyped fields fall back to their default (fail-closed)

    @Test("mistyped dealsEngineEnabled falls back to false, not a crash")
    func mistypedDealsEngineEnabledFallsBackToFalse() {
        let settings = DealsSettings.decode(["dealsEngineEnabled": "yes"])
        #expect(settings.dealsEngineEnabled == false)
    }

    @Test("mistyped allowBelowCost falls back to false")
    func mistypedAllowBelowCostFallsBackToFalse() {
        let settings = DealsSettings.decode(["allowBelowCost": "yes"])
        #expect(settings.allowBelowCost == false)
    }

    @Test("mistyped bonusUnitFloorCents falls back to 1")
    func mistypedBonusUnitFloorCentsFallsBackToOne() {
        let settings = DealsSettings.decode(["bonusUnitFloorCents": "not-a-number"])
        #expect(settings.bonusUnitFloorCents == 1)
    }

    // MARK: - bonusUnitFloorCents clamps to a minimum of 1 (Mechanism B is NEVER zero)

    @Test("bonusUnitFloorCents of 0 clamps to 1")
    func bonusUnitFloorCentsZeroClampsToOne() {
        let settings = DealsSettings.decode(["bonusUnitFloorCents": 0])
        #expect(settings.bonusUnitFloorCents == 1)
    }

    @Test("negative bonusUnitFloorCents clamps to 1")
    func bonusUnitFloorCentsNegativeClampsToOne() {
        let settings = DealsSettings.decode(["bonusUnitFloorCents": -5])
        #expect(settings.bonusUnitFloorCents == 1)
    }

    // MARK: - Document contract

    @Test("collection/documentID address stores/{id}/settings/deals")
    func addressesSettingsDeals() {
        #expect(DealsSettings.collection == "settings")
        #expect(DealsSettings.documentID == "deals")
        let write = DealsSettings().mirrorWrite()
        #expect(write.path(storeId: "store-1") == "stores/store-1/settings/deals")
    }

    @Test("mirrorWrite emits all three fields with their exact wire types")
    func mirrorWriteEmitsExactFields() {
        let write = DealsSettings(dealsEngineEnabled: true, allowBelowCost: true, bonusUnitFloorCents: 300).mirrorWrite()
        #expect(write.fields["dealsEngineEnabled"] == .bool(true))
        #expect(write.fields["allowBelowCost"] == .bool(true))
        #expect(write.fields["bonusUnitFloorCents"] == .int(300))
        #expect(write.fields.count == 3)
    }

    @Test("default init is flag-off / below-cost-off / 1-cent floor")
    func defaultInitIsFlagOff() {
        let settings = DealsSettings()
        #expect(settings.dealsEngineEnabled == false)
        #expect(settings.allowBelowCost == false)
        #expect(settings.bonusUnitFloorCents == 1)
    }

    // MARK: - costFloorPolicy mapping

    @Test("costFloorPolicy maps allowBelowCost and bonusUnitFloorCents straight through")
    func costFloorPolicyMapsFieldsThrough() {
        let settings = DealsSettings(dealsEngineEnabled: true, allowBelowCost: true, bonusUnitFloorCents: 250)
        let policy = settings.costFloorPolicy
        #expect(policy.allowBelowCost == true)
        #expect(policy.bonusUnitFloor == Money(cents: 250))
    }

    @Test("costFloorPolicy on defaults matches CostFloorPolicy's own defaults")
    func costFloorPolicyMatchesDefaultsOnBothSides() {
        let policy = DealsSettings().costFloorPolicy
        #expect(policy == CostFloorPolicy())
    }
}
