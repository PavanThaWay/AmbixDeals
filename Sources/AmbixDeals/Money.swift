import Foundation

/// Money as integer **cents** so register arithmetic (line totals, tax, tender,
/// change) never accumulates binary-float error. The backend stores these as
/// `numeric(12,2)` **dollars**, and `salesProjector` reads plain JS numbers, so the
/// Firestore contract boundary emits `dollars` (a 2-dp Double). Keep math in cents;
/// only cross to `dollars` when building the doc.
public struct Money: Equatable, Hashable, Comparable, Codable, Sendable {
    public let cents: Int

    public init(cents: Int) { self.cents = cents }

    /// Build from a dollar amount (rounds half-up to the nearest cent).
    ///
    /// Reached from user-facing `.decimalPad` fields (Order Discount, `DiscountEntrySheet`),
    /// where an iPad paste can supply an arbitrarily long digit string. `Int(...)` on a
    /// `Double` past `Int.max` — or `NaN`/`infinity` — TRAPS, so a bare
    /// `Int((dollars * 100).rounded())` is a crash-on-paste path. Clamp instead: `NaN → 0`,
    /// out-of-range → the signed cent limit. The money outcome stays safe because every
    /// discount caller re-clamps (allocator caps at the selected subtotal, a line discount
    /// caps at its own total), so a clamped absurd value simply becomes the max legal one.
    public init(dollars: Double) {
        let scaled = (dollars * 100).rounded()
        if let cents = Int(exactly: scaled) {
            self.cents = cents
        } else {
            self.cents = scaled.isNaN ? 0 : (scaled > 0 ? Int.max : Int.min)
        }
    }

    public static let zero = Money(cents: 0)

    /// Dollar value for the Firestore/Postgres `numeric(12,2)` boundary.
    public var dollars: Double { Double(cents) / 100.0 }

    public static func + (l: Money, r: Money) -> Money { Money(cents: l.cents + r.cents) }
    public static func - (l: Money, r: Money) -> Money { Money(cents: l.cents - r.cents) }
    public static func * (m: Money, qty: Int) -> Money { Money(cents: m.cents * qty) }
    public static func < (l: Money, r: Money) -> Bool { l.cents < r.cents }

    /// Multiply by a fractional quantity (e.g. 1.5 lb) rounding to the cent.
    public func times(_ q: Double) -> Money { Money(cents: Int((Double(cents) * q).rounded())) }
}
