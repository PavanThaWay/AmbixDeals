import Foundation
import Testing

@testable import AmbixDeals

/// The four wire-boundary defects an adversarial review raised against this contract, each
/// pinned from BOTH directions: the bad input can no longer reach the wire, AND a
/// currently-correct document still decodes to exactly the value it always did.
///
/// The unifying failure these guard against is the quiet one: a deal that decodes cleanly,
/// passes every bound, lists as **Active** in Station and in the portal, and silently applies
/// to nothing — or applies far too generously — at the register. Nothing in `DealEngine`
/// normalizes a product id (`line.productId == productId`, `ids.contains(line.productId)`),
/// so a stray space is indistinguishable from a typo'd SKU once it is stored.
///
/// Shares `firestoreValueToAny` / `decodedDeal(from:)` / `validMinimalDraft()` with
/// `DealDraftTests.swift` deliberately — one pipeline, one definition of "what the wire says."

// MARK: - Small readers over an emitted field tree

private func discountFields(_ draft: DealDraft) throws -> [String: FirestoreValue] {
    guard case .map(let fields)? = draft.mirrorWrite().fields["discount"] else {
        throw WireBoundaryFailure.notAMap("discount")
    }
    return fields
}

private func scopeIds(_ draft: DealDraft) throws -> [String] {
    guard case .map(let fields)? = draft.mirrorWrite().fields["scope"],
          case .array(let ids)? = fields["ids"]
    else { throw WireBoundaryFailure.notAMap("scope.ids") }
    return try ids.map {
        guard case .string(let s) = $0 else { throw WireBoundaryFailure.notAMap("scope.ids[]") }
        return s
    }
}

private enum WireBoundaryFailure: Error { case notAMap(String) }

// MARK: - 1. Product ids are normalized at the wire boundary

@Suite("Wire boundary — product ids and category names")
struct WireIdBoundaryTests {

    @Test("unlockBonusProduct.productId reaches the wire trimmed, never with the padding the manager typed")
    func unlockBonusProductIdIsTrimmed() throws {
        var draft = validMinimalDraft()
        draft.discount = .unlockBonusProduct(productId: " sku-1 ", quantity: "2")

        #expect(draft.canSave)
        #expect(try discountFields(draft)["productId"] == .string("sku-1"))
        #expect(try decodedDeal(from: draft).discount == .unlockBonusProduct(productId: "sku-1", quantity: 2))
    }

    @Test("every bundle component's productId reaches the wire trimmed")
    func bundleComponentIdsAreTrimmed() throws {
        var draft = validMinimalDraft()
        draft.discount = .bundle(
            components: [
                DraftBundleComponent(productId: "  sku-a", qty: "1"),
                DraftBundleComponent(productId: "sku-b\n", qty: "2"),
            ],
            bundlePrice: "25.00"
        )

        #expect(draft.canSave)
        let deal = try decodedDeal(from: draft)
        #expect(deal.discount == .bundle(
            components: [
                BundleComponent(productId: "sku-a", qty: 1),
                BundleComponent(productId: "sku-b", qty: 2),
            ],
            bundlePrice: Money(cents: 2_500)
        ))
    }

    @Test("a products scope reaches the wire trimmed — a padded id would list Active and match nothing")
    func productsScopeIdsAreTrimmed() throws {
        var draft = validMinimalDraft()
        draft.scope = .products(ids: [" sku-1 ", "sku-2", "\tsku-3\n"])

        #expect(draft.canSave)
        #expect(try scopeIds(draft) == ["sku-1", "sku-2", "sku-3"])
        #expect(try decodedDeal(from: draft).scope == .products(ids: ["sku-1", "sku-2", "sku-3"]))
    }

    @Test("a category scope reaches the wire trimmed — category matching is byte-exact too")
    func categoryScopeNamesAreTrimmed() throws {
        var draft = validMinimalDraft()
        draft.scope = .category(names: ["Wine ", " Beer"])

        #expect(draft.canSave)
        #expect(try decodedDeal(from: draft).scope == .category(names: ["Beer", "Wine"]))
    }

    @Test("two scope entries that differ ONLY by padding collapse to one, never a duplicate on the wire")
    func paddingOnlyDuplicatesCollapse() throws {
        var draft = validMinimalDraft()
        draft.scope = .products(ids: ["sku-1", " sku-1", "sku-1 "])

        #expect(try scopeIds(draft) == ["sku-1"])
    }

    @Test("a scope holding nothing but whitespace fails the ≥1-entry rule instead of emitting unmatchable ids")
    func whitespaceOnlyScopeIsRejected() {
        var products = validMinimalDraft()
        products.scope = .products(ids: ["   ", "\n"])
        #expect(products.validationErrors == [.productsScopeEmpty])
        #expect(!products.canSave)

        var categories = validMinimalDraft()
        categories.scope = .category(names: ["  "])
        #expect(categories.validationErrors == [.categoryScopeEmpty])
        #expect(!categories.canSave)
    }

    @Test("a whitespace-only reward product is still .unlockBonusProductMissing, not a blank id on the wire")
    func whitespaceOnlyRewardProductIsRejected() {
        var draft = validMinimalDraft()
        draft.discount = .unlockBonusProduct(productId: "   ", quantity: "1")
        #expect(draft.validationErrors == [.unlockBonusProductMissing])
    }

    @Test("bundle components that differ ONLY by padding are still 'not distinct' — the validator and the encoder agree")
    func paddingOnlyBundleComponentsAreNotDistinct() {
        var draft = validMinimalDraft()
        draft.discount = .bundle(
            components: [
                DraftBundleComponent(productId: "sku-a", qty: "1"),
                DraftBundleComponent(productId: " sku-a ", qty: "1"),
            ],
            bundlePrice: "10"
        )
        #expect(draft.validationErrors.contains(.bundleNeedsTwoDistinctProducts))
    }

    // MARK: Wire compatibility

    @Test("an already-clean scope is byte-identical to what it emitted before normalization existed")
    func cleanScopeIsUnchanged() throws {
        var products = validMinimalDraft()
        products.scope = .products(ids: ["zeta-sku", "alpha-sku", "mike-sku"])
        #expect(try scopeIds(products) == ["alpha-sku", "mike-sku", "zeta-sku"])

        var categories = validMinimalDraft()
        categories.scope = .category(names: ["Zinfandel", "Ale", "Merlot"])
        #expect(try scopeIds(categories) == ["Ale", "Merlot", "Zinfandel"])
    }

    @Test("an already-clean id is emitted verbatim — normalization is a no-op on good input")
    func cleanIdsAreEmittedVerbatim() throws {
        var draft = validMinimalDraft()
        draft.discount = .unlockBonusProduct(productId: "sku-1", quantity: "2")
        #expect(try discountFields(draft)["productId"] == .string("sku-1"))
    }

    @Test("a padded id STORED in an existing doc still decodes verbatim — decode is untouched")
    func decodeNeverTrims() throws {
        let json = """
        {"id":"d1","name":"N","isActive":true,
         "discount":{"kind":"unlockBonusProduct","productId":" sku-1 ","quantity":2},
         "scope":{"type":"products","ids":[" sku-1 ","sku-2"]}}
        """
        let deal = try JSONDecoder().decode(Deal.self, from: Data(json.utf8))
        #expect(deal.discount == .unlockBonusProduct(productId: " sku-1 ", quantity: 2))
        #expect(deal.scope == .products(ids: [" sku-1 ", "sku-2"]))
    }
}
