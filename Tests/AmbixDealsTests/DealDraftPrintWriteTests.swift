import Foundation
import Testing

@testable import AmbixDeals

/// The ENCODE side of `DealPrint` — `DealDraft` authoring a print config onto the wire.
///
/// `DealPrintCodecTests` covers the decode side (every malformed shape failing closed to
/// `nil`). This file covers what a Studio save actually writes, and the lockstep invariant
/// between the two: what a manager authored must decode back to exactly what they meant.
struct DealDraftPrintWriteTests {

    private func printingDraft(id: String = "deal-print") -> DealDraft {
        var draft = validMinimalDraft(id: id)
        draft.couponCode = "save5"
        draft.printEnabled = true
        draft.print.headline = "$5 OFF YOUR NEXT VISIT"
        return draft
    }

    // MARK: - The clear

    /// THE decision this release exists to make.
    ///
    /// `FirestoreRelay` writes with `setData(merge: true)`, where an absent key leaves the
    /// stored value untouched. If turning printing off merely omitted `print`, the stored
    /// config would survive and the deal would keep advertising itself on paper after the
    /// manager switched it off — the switch and the customer's coupon disagreeing, with the
    /// customer's version winning.
    @Test("printing off writes an explicit null, never an absent key")
    func printingOffClears() {
        var draft = printingDraft()
        draft.printEnabled = false

        let fields = draft.mirrorWrite().fields
        #expect(fields["print"] != nil, "an absent key would silently preserve the stored config")
        #expect(fields["print"] == .null)
    }

    /// The other half: a store that never touched printing still writes the null, so the
    /// key is unconditionally owned rather than owned-once-set.
    @Test("a draft that never enabled printing still writes the null")
    func neverEnabledStillClears() {
        #expect(validMinimalDraft().mirrorWrite().fields["print"] == .null)
    }

    // MARK: - The map

    @Test("printing on emits the complete key vocabulary")
    func completeVocabulary() throws {
        var draft = printingDraft()
        draft.print.priority = 7
        draft.print.terms = "One per customer."

        guard case .map(let print)? = draft.mirrorWrite().fields["print"] else {
            Issue.record("expected a print map"); return
        }
        #expect(Set(print.keys) == ["trigger", "priority", "headline", "terms"])
        #expect(print["priority"] == .int(7))
        #expect(print["headline"] == .string("$5 OFF YOUR NEXT VISIT"))
        #expect(print["terms"] == .string("One per customer."))
    }

    /// Terms are optional even when a headline is set, and clearing them must reach the
    /// wire — a nested map merges key by key, so an omitted `terms` would leave the old
    /// small print attached to a new offer.
    @Test("cleared terms write a null inside the map")
    func clearedTerms() throws {
        var draft = printingDraft()
        draft.print.terms = "   "

        guard case .map(let print)? = draft.mirrorWrite().fields["print"] else {
            Issue.record("expected a print map"); return
        }
        #expect(print["terms"] == .null)
    }

    // MARK: - The trigger's shape switch

    /// A trigger map carries different keys per shape. Narrowing "over $30" back to
    /// "always" must not strand `amount: 30` inside the stored map — Station's decode is
    /// discriminator-driven and would ignore it, but the AmbixServer projector stores this
    /// whole object as `deals.payload` and both the Portal and Daisho read it.
    @Test("every trigger shape emits the full payload vocabulary",
          arguments: [
            ("always", DraftPrintTrigger.always, "type"),
            ("categories", .basketHasCategory(names: ["Wine"]), "names"),
            ("products", .basketHasProduct(ids: ["sku-1"]), "ids"),
            ("saleOver", .saleOver("30"), "amount"),
          ] as [(String, DraftPrintTrigger, String)])
    func triggerVocabulary(label: String, trigger: DraftPrintTrigger, used: String) throws {
        var draft = printingDraft()
        draft.print.trigger = trigger

        guard case .map(let print)? = draft.mirrorWrite().fields["print"],
              case .map(let fields)? = print["trigger"] else {
            Issue.record("expected a trigger map for \(label)"); return
        }
        #expect(Set(fields.keys) == ["type", "names", "ids", "amount"])
        for key in ["names", "ids", "amount"] where key != used {
            #expect(fields[key] == .null, "\(label) left \(key) unpadded")
        }
    }

    /// Byte-exact matching at the register (`names.contains(line.categoryName)`) means a
    /// padded entry decodes cleanly, lists as active everywhere, and fires on no basket.
    @Test("trigger entries are trimmed and de-duplicated at the wire")
    func triggerEntriesNormalized() throws {
        var draft = printingDraft()
        draft.print.trigger = .basketHasCategory(names: ["  Wine  ", "Wine", "   "])

        guard case .map(let print)? = draft.mirrorWrite().fields["print"],
              case .map(let trigger)? = print["trigger"],
              case .array(let names)? = trigger["names"] else {
            Issue.record("expected names"); return
        }
        #expect(names == [.string("Wine")])
    }

    // MARK: - Lockstep

    /// The invariant this whole draft type exists for, applied to `print`: what the manager
    /// authored decodes back to exactly what they meant.
    @Test("what the Studio writes is what the register reads")
    func lockstep() throws {
        var draft = printingDraft()
        draft.print.trigger = .saleOver("30")
        draft.print.priority = 3
        draft.print.terms = "Expires in 30 days."

        let decoded = try decodedDeal(from: draft)
        #expect(decoded.print == DealPrint(trigger: .saleOver(Money(dollars: 30)),
                                           priority: 3,
                                           headline: "$5 OFF YOUR NEXT VISIT",
                                           terms: "Expires in 30 days."))
    }

    @Test("a cleared config decodes back to no config at all")
    func clearedLockstep() throws {
        var draft = printingDraft()
        draft.printEnabled = false
        #expect(try decodedDeal(from: draft).print == nil)
    }

    @Test("every trigger shape round-trips through decode",
          arguments: [
            (DraftPrintTrigger.always, DealPrintTrigger.always),
            (.basketHasCategory(names: ["Wine", "Beer"]), .basketHasCategory(names: ["Wine", "Beer"])),
            (.basketHasProduct(ids: ["sku-1"]), .basketHasProduct(ids: ["sku-1"])),
            (.saleOver("19.99"), .saleOver(Money(dollars: 19.99))),
          ] as [(DraftPrintTrigger, DealPrintTrigger)])
    func triggerLockstep(authored: DraftPrintTrigger, expected: DealPrintTrigger) throws {
        var draft = printingDraft()
        draft.print.trigger = authored
        #expect(try decodedDeal(from: draft).print?.trigger == expected)
    }

    // MARK: - Seeding

    @Test("editing an existing deal round-trips its config into the buffers")
    func seeding() throws {
        var draft = printingDraft()
        draft.print.trigger = .saleOver("30")
        draft.print.priority = 2
        draft.print.terms = "Terms apply."

        let reopened = try #require(DealDraft(from: try decodedDeal(from: draft)))
        #expect(reopened.printEnabled)
        #expect(reopened.print == draft.print)
    }

    @Test("a deal with no print config opens with the switch off")
    func seedingAbsent() throws {
        let reopened = try #require(DealDraft(from: try decodedDeal(from: validMinimalDraft())))
        #expect(reopened.printEnabled == false)
        #expect(reopened.print == DraftPrint())
    }

    // MARK: - Validation

    /// `CouponSelector` refuses to advertise a deal with no headline, because the only text
    /// left would be `Deal.name` — an internal label. Decode tolerates that; an editor must
    /// not, or the manager saves a deal they believe prints and which never does.
    @Test("printing on with no offer line blocks the save")
    func headlineRequired() {
        var draft = printingDraft()
        draft.print.headline = "  "
        #expect(draft.validationErrors.contains(.printHeadlineRequired))
        #expect(draft.canSave == false)
    }

    @Test("printing on with no coupon code blocks the save")
    func couponRequired() {
        var draft = printingDraft()
        draft.couponCode = ""
        #expect(draft.validationErrors.contains(.printNeedsCouponCode))
        #expect(draft.canSave == false)
    }

    /// Both rules are scoped to the switch. A deal that doesn't print is not required to
    /// have a headline or a coupon code, and every deal authored before this release is
    /// exactly that.
    @Test("neither rule applies while printing is off")
    func rulesScopedToSwitch() {
        var draft = validMinimalDraft()
        draft.print.headline = ""
        draft.couponCode = ""
        #expect(draft.canSave)
    }

    @Test("an empty trigger list blocks the save",
          arguments: [
            (DraftPrintTrigger.basketHasCategory(names: ["  "]), DraftError.printTriggerCategoriesEmpty),
            (.basketHasProduct(ids: []), .printTriggerProductsEmpty),
            (.saleOver(""), .printTriggerAmountInvalid),
            (.saleOver("0"), .printTriggerAmountInvalid),
          ] as [(DraftPrintTrigger, DraftError)])
    func triggerValidation(trigger: DraftPrintTrigger, expected: DraftError) {
        var draft = printingDraft()
        draft.print.trigger = trigger
        #expect(draft.validationErrors.contains(expected))
        #expect(draft.canSave == false)
    }

    /// A runaway paste reads as "too big", not the nonsensical "must be greater than $0" a
    /// lower-bound-only rule would give — the same split `DraftValidation.amountError`
    /// already applies to every other dollar field.
    @Test("a runaway amount reads as too large")
    func triggerAmountCap() {
        var draft = printingDraft()
        draft.print.trigger = .saleOver("999999999999")
        #expect(draft.validationErrors.contains(.amountTooLarge))
    }

    /// Every new error must carry a message a manager can act on — an empty one would
    /// surface as a blank row under a disabled Save button.
    @Test("every print error explains itself",
          arguments: [DraftError.printHeadlineRequired, .printNeedsCouponCode,
                      .printTriggerCategoriesEmpty, .printTriggerProductsEmpty,
                      .printTriggerAmountInvalid])
    func errorMessages(error: DraftError) {
        #expect(error.message.isEmpty == false)
    }
}
