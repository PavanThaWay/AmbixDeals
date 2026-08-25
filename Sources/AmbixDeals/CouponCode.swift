import Foundation

/// What a coupon code may contain if a customer is ever to redeem the printed one.
///
/// THE ONE DEFINITION, deliberately in this package rather than in Station, because two
/// things have to agree about it and they live on opposite sides of a dependency:
///
/// - the PRINTER, which reduces a code to what a Code128 barcode can carry
///   (`ReceiptCoupon.sanitizedCode` calls straight through to `sanitized(_:)` below), and
/// - the EDITOR, which must refuse to save a code the printer would alter
///   (`DraftPrint.validationErrors`).
///
/// When those two disagree the failure is silent and total: the barcode carries one string
/// and the register matches another, so the coupon simply never redeems. The human-readable
/// line under the bars shows the printed form too, so a cashier typing what they can see
/// fails identically. Nothing anywhere reports it.
///
/// ## The alphabet
///
/// ASCII `A`–`Z`, `0`–`9`, and `-`. Code set B carries far more, but a coupon code is read
/// aloud, written on a whiteboard and typed in by hand at least as often as it is scanned,
/// and keeping it to characters that survive all four is worth more than the extra
/// alphabet.
///
/// **ASCII is load-bearing, not decorative.** Swift's `isNumber` is true for every Unicode
/// number — `½`, the Arabic-Indic digits, the Roman numeral forms — and an earlier version
/// of this filter admitted them by testing `isNumber` without `isASCII`.
///
/// Those characters then reached `GS k 73` as raw UTF-8. Code128 **code set B encodes
/// ASCII 32–126 and nothing else**, so a byte like `0xC2` has no symbol in it: the printer
/// is handed a well-framed command whose payload it cannot render, and prints a malformed
/// barcode or none at all. That is worse than the stripping it sits beside — not a code
/// that fails to match, but one that never becomes bars.
///
/// (The length prefix itself is fine, and an earlier draft of this comment claimed
/// otherwise. `barcodeCode128` takes `UInt8(data.count)` from the BYTE array it is handed,
/// so multi-byte characters are counted correctly. The one length hazard is real but
/// separate: that initialiser traps above 255, and non-ASCII inflation reaches 255 bytes
/// in fewer characters than a plain code would.)
public enum CouponCode {

    /// Whether one character survives the journey to paper unchanged.
    public static func isScannable(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber) || character == "-"
    }

    /// The code as a barcode can actually carry it: upper-cased, everything else removed.
    public static func sanitized(_ code: String) -> String {
        String(code.uppercased().filter(isScannable))
    }

    /// The code as it is STORED, which is what redemption matches against — trimmed and
    /// upper-cased, exactly as `DealDraft.mirrorWrite()` writes it.
    public static func normalized(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Whether a printed barcode of this code would redeem.
    ///
    /// Expressed as an equality between the two functions rather than as a second copy of
    /// the character class, so it cannot drift from either: the printed string must be the
    /// stored string. Anything the sanitizer removes is a character the register will
    /// never see and therefore never match.
    public static func isRedeemableWhenPrinted(_ code: String) -> Bool {
        sanitized(code) == normalized(code)
    }

    /// The distinct characters a printed barcode would drop, in the order they appear, for
    /// a message that can name them.
    ///
    /// Whitespace and other invisibles are rendered as something a manager can actually
    /// read — "remove: ␠" is useless advice if the space is drawn as a space.
    public static func unscannableCharacters(_ code: String) -> [String] {
        var seen = Set<Character>()
        var out: [String] = []
        for character in normalized(code) where !isScannable(character) {
            guard !seen.contains(character) else { continue }
            seen.insert(character)
            out.append(describe(character))
        }
        return out
    }

    private static func describe(_ character: Character) -> String {
        switch character {
        case " ": return "space"
        case "\t": return "tab"
        default:
            // A character with no glyph of its own is named by its scalar rather than
            // printed into a sentence where it would be invisible.
            if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                let scalars = character.unicodeScalars
                    .map { "U+" + String($0.value, radix: 16, uppercase: true) }
                return scalars.joined(separator: " ")
            }
            return String(character)
        }
    }
}
