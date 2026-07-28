import Foundation

/// A single document the register relays into Firestore. The existing
/// `triggerFactory → pgOutbox → syncWorker → PROJECTORS` pipeline mirrors it to
/// Postgres for Portal, and Daisho reads the same Firestore docs — so emitting the
/// correct `collection` + `documentID` + `fields` is the WHOLE contract.
public struct MirrorWrite: Equatable, Sendable {
    /// Subcollection segment under `stores/{storeId}/` — must equal a key the
    /// backend `PROJECTORS` map recognizes (e.g. `sales`, `products`, `inventoryEvents`).
    public let collection: String
    public let documentID: String
    public let fields: [String: FirestoreValue]
    /// Optional nested writes (e.g. `openShifts/{id}/claims/{claimId}`). Path is
    /// relative to THIS document.
    public let subwrites: [MirrorWrite]

    public init(collection: String, documentID: String,
                fields: [String: FirestoreValue], subwrites: [MirrorWrite] = []) {
        self.collection = collection
        self.documentID = documentID
        self.fields = fields
        self.subwrites = subwrites
    }

    /// Absolute Firestore path for a given store, e.g. `stores/<store>/sales/<id>`.
    public func path(storeId: String) -> String {
        "stores/\(storeId)/\(collection)/\(documentID)"
    }
}

/// Anything the register can turn into a `MirrorWrite`. Every contract model
/// (Sale, Product, InventoryEvent, …) conforms to this so the relay treats them
/// uniformly.
public protocol MirrorEmitting: Sendable {
    /// The PROJECTORS collection key this doc lands in.
    static var collection: String { get }
    func mirrorWrite() -> MirrorWrite
}
