import Foundation

/// A Firebase-free representation of a Firestore field value.
///
/// Keeping `AmbixStationCore` free of the Firebase SDK means contracts can be
/// unit-tested anywhere. The app-layer `FirebaseRelay` maps each case to a real
/// Firestore value (`.timestamp` → `FIRTimestamp`, `.serverTimestamp` →
/// `FieldValue.serverTimestamp()`, etc.); the Node fidelity harness maps the same
/// tree to JSON. One contract, two faithful renderers.
public indirect enum FirestoreValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// An ISO-8601 instant stored as a STRING field (e.g. `sale.saleTime`, which
    /// `salesProjector` reads as a string and writes to `timestamptz`).
    case isoString(Date)
    /// A Firestore `Timestamp` field (e.g. product `createdAt`/`updatedAt`).
    case timestamp(Date)
    /// `FieldValue.serverTimestamp()` — resolved by the server on write.
    case serverTimestamp
    case null
    case array([FirestoreValue])
    case map([String: FirestoreValue])

    /// Convenience: a string field that becomes `.null` when empty/nil — matches the
    /// backend `textOrNull` guard so the register never writes empty strings where
    /// the projector expects NULL.
    public static func textOrNull(_ s: String?) -> FirestoreValue {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .null }
        return .string(s)
    }
}

public extension FirestoreValue {
    /// Stable ISO-8601 (UTC, fractional seconds) for `.isoString` rendering and JSON.
    /// `nonisolated(unsafe)`: configured once in this initializer, then only ever read
    /// via the thread-safe `string(from:)` — never reconfigured — so shared concurrent
    /// reads are safe even though `ISO8601DateFormatter` is not `Sendable`.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// JSON-friendly rendering used by the Node contract-fidelity harness and tests.
    /// `.timestamp`/`.serverTimestamp` render as ISO strings here purely for
    /// inspection — the real SDK renders them as Firestore Timestamps.
    func jsonObject() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .isoString(let d), .timestamp(let d): return FirestoreValue.iso8601.string(from: d)
        case .serverTimestamp: return "<serverTimestamp>"
        case .null: return NSNull()
        case .array(let a): return a.map { $0.jsonObject() }
        case .map(let m): return m.mapValues { $0.jsonObject() }
        }
    }
}
