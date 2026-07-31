import Foundation

/// THE host-adapter contract for turning a Firestore `deals` document into a `Deal`.
///
/// `Deal` is a plain `Decodable`, so any host could in principle feed it any `Decoder`. In
/// practice exactly one bridge is correct, and getting it wrong is silent: it produces a
/// `Deal` that decodes without error and carries a subtly wrong number. This type exists so
/// that bridge lives in the PACKAGE, where every consumer inherits it, rather than in one
/// app's store layer where the next app has to rediscover it.
///
/// ## The defect this exists to prevent (empirically confirmed in production)
///
/// The Firestore SDK hands every numeric field back as an `NSNumber`. Serializing a FLOATING
/// `NSNumber` through `JSONSerialization` re-renders it via `Double`'s lossy binary round-trip,
/// which expands a clean decimal like `33.33` into the JSON *text* `33.329999999999998`.
///
/// `Deal`'s decode rounds every MONEY field to the nearest cent (`Money(decimalDollars:)`), so
/// for dollar amounts the corruption is invisible. PERCENT fields have no such rounding step:
/// `flatPercentOff.percent`, `buyXGetYPercentOff.percentOff`, `unlockPercentOffCart.percent`
/// and a `mixedCase` tier's `discountPercent` decode a dirty double into an equally dirty
/// `Decimal`. A manager then sees `33.3299999999999...` echoed back in the editor, and the next
/// save PERSISTS it — the corruption is now the stored value, not a display artifact.
///
/// The fix: detect a genuinely FRACTIONAL `NSNumber` — not a boolean, not an integer — and
/// rebox it as an `NSDecimalNumber` built from Swift's own shortest-round-trip formatting of
/// the underlying `Double`, before it ever reaches `JSONSerialization`. `NSDecimalNumber`
/// serializes through its own exact decimal text rather than the binary-float path a raw
/// `NSNumber` takes.
///
/// NOTE, and this is the one place this package deliberately diverges from the Station guard it
/// was lifted from: the formatting MUST go through `String(number.doubleValue)`, NOT
/// `String(describing: number)`. Those look interchangeable and are not. `String(describing:)`
/// on an `NSNumber` dispatches to `NSNumber.description`, which formats with `%0.16g` — 16
/// significant digits, not shortest-round-trip. That reproduces `"33.33"` correctly (the value
/// Station's fix was verified against) but turns `99.99` into `"99.98999999999999"`, reboxing
/// the corruption instead of removing it. `String` of a Swift `Double` is shortest-round-trip
/// and gets both right; verified across every magnitude the test suite exercises.
///
/// ## What a host must still do itself
///
/// This package has NO Firebase dependency, so it cannot see a `Timestamp`. A host bridging a
/// live Firestore document MUST convert every `Timestamp` to an ISO-8601 string BEFORE calling
/// `decodeDeal(_:id:)` — `DealSchedule.startDate`/`endDate` already expect ISO strings, and
/// `JSONSerialization` cannot serialize a `Timestamp` at all (a document still carrying one
/// yields `nil` here rather than a partial `Deal`). `FirestoreValue.iso8601` is the formatter to
/// use; it is the same one this package's own writes emit, so the bridge is lossless.
///
/// A host reading through Firestore's NATIVE decoder (`doc.data(as: Deal.self)`) bypasses this
/// type entirely and is NOT guaranteed to produce identical `Decimal`-typed fields. Route
/// through `decodeDeal(_:id:)` instead.
public enum DealDocumentSanitizer {

    /// Bridges one raw `deals` document into a `Deal`: sanitize -> `JSONSerialization` ->
    /// `JSONDecoder`. `nil` on ANY failure (malformed shape, an `audience`/`channel` value
    /// `Deal.init(from:)` fails hard on, content `JSONSerialization` cannot represent such as a
    /// leftover `Timestamp`).
    ///
    /// A `nil` means "skip this ONE document" — never a reason to drop the whole list. Deals are
    /// independent of each other, and one malformed document taking the rest of the store's
    /// pricing with it is the failure mode this package works hardest to avoid.
    public static func decodeDeal(_ raw: [String: Any], id: String) -> Deal? {
        let document = sanitizedDocument(raw, id: id)
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document)
        else { return nil }
        return try? JSONDecoder().decode(Deal.self, from: data)
    }

    /// The sanitize step on its own, for a host that also wants to CACHE the cleaned document
    /// (caching the raw one and re-sanitizing on hydrate works too, but then the cache and the
    /// live path are two chances to drift).
    ///
    /// Injects the TRUE document id, overriding any possibly-stale `"id"` the body carries:
    /// `Deal.id` is a doc-id mirror by design, and the live document id is the authoritative
    /// one.
    public static func sanitizedDocument(_ raw: [String: Any], id: String) -> [String: Any] {
        var withId = raw
        withId["id"] = id
        return (sanitized(withId) as? [String: Any]) ?? withId
    }

    /// Recursively rewrites every fractional `NSNumber` in a decoded-document tree. Non-numeric
    /// values, integers and booleans pass through untouched.
    public static func sanitized(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber:
            return sanitizedNumber(number)
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitized($0) }
        case let array as [Any]:
            return array.map { sanitized($0) }
        default:
            return value
        }
    }

    /// The hard gate itself. Booleans and integers pass through UNCHANGED:
    ///
    /// - `CFGetTypeID` distinguishes a genuine `CFBoolean`-backed `NSNumber` from a numeric one
    ///   (different runtime types under the hood, even though both bridge to `NSNumber` in
    ///   Swift). This is what keeps `true` from ever becoming `1.0`. It is belt-and-braces —
    ///   a boolean's `objCType` is `"c"`, which the switch below already passes through — and
    ///   it is kept because "belt-and-braces on the field that silently flips a deal's
    ///   `isActive`" is worth two lines.
    /// - `objCType` then distinguishes an INTEGER encoding (`i`/`s`/`l`/`q`/their unsigned
    ///   forms/`c`, …) from a FLOATING one (`f`/`d`). An integer has no fractional binary
    ///   representation to lose precision on, so only `f`/`d` are reboxed.
    ///
    /// `f` and `d` are formatted through their OWN Swift type (`Float`/`Double`) so each gets
    /// its own shortest round-trip — widening a `Float` to `Double` first would inject exactly
    /// the binary noise this function exists to remove. Firestore only ever hands back `d`, but
    /// this type is the package's general-purpose host bridge, not a Firestore-only one.
    public static func sanitizedNumber(_ number: NSNumber) -> NSNumber {
        #if canImport(Darwin)
        // `CFGetTypeID`/`CFBooleanGetTypeID` are Darwin-only in Swift. On other platforms the
        // `objCType` switch below is the whole guard, which is sufficient: a Bool still reports
        // `"c"` there and so still falls through untouched.
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number
        }
        #endif
        switch String(cString: number.objCType) {
        case "d":
            let value = number.doubleValue
            return value.isFinite ? decimalNumber(from: String(value), fallback: number) : number
        case "f":
            let value = number.floatValue
            return value.isFinite ? decimalNumber(from: String(value), fallback: number) : number
        default:
            return number
        }
    }

    /// `NSDecimalNumber(string:)` has no failure channel — it answers `NaN` for text it cannot
    /// parse and `0` for some it parses only partially (`"-inf"`), and a `Decimal` cannot hold a
    /// magnitude a `Double` can (`1e300`). A `NaN` `NSDecimalNumber` is not JSON-serializable
    /// either, so a bad rebox would take a whole document down over one field.
    ///
    /// So: reboxing is only ever accepted when it VERIFIABLY round-trips back to the same
    /// double. Anything else hands the original `NSNumber` straight back and lets the existing
    /// decode path treat it exactly as it would have before this sanitizer existed — this
    /// function can improve precision, never degrade it.
    private static func decimalNumber(from text: String, fallback: NSNumber) -> NSNumber {
        let reboxed = NSDecimalNumber(string: text)
        guard reboxed != NSDecimalNumber.notANumber,
              reboxed.doubleValue == fallback.doubleValue
        else { return fallback }
        return reboxed
    }
}
