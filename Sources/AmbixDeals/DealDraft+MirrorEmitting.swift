import Foundation

/// The Deals Studio editor (Phase C-2, Task 3) saves through `relayQueue.enqueue(_ model:
/// MirrorEmitting)` — the ONE write seam every authored contract in this codebase goes
/// through (`CategoryVendorEdit`'s `Category`/`Vendor`, `DealsSettingsStore`'s
/// `DealsSettings`, …). `DealDraft` (Task 1) already builds the complete, lockstep-correct
/// `MirrorWrite` via `mirrorWrite()`; the ONLY thing missing for `RelayQueue.enqueue` to
/// accept a draft directly is the `collection` constant `MirrorEmitting` requires.
///
/// Kept as its OWN file rather than folded into `DealDraft.swift` (Task 1, already
/// shipped/reviewed) — a zero-logic, 3-line conformance box so Task 3's diff never touches
/// a file outside its own scope. `mirrorWrite()` itself still `precondition`s `canSave`, so
/// callers must `guard draft.canSave` before ever handing a draft to `enqueue` — this
/// extension adds no new safety surface of its own, only the protocol box.
extension DealDraft: MirrorEmitting {
    public static let collection = "deals"
}
