import Foundation
import Testing

@testable import AmbixDeals

/// The alphabet a printed coupon code may use.
///
/// This is the rule that stops a store printing a barcode nobody can redeem. The failure
/// it prevents is silent and total: the printer strips the code to what Code128 can carry,
/// the register matches the stored string exactly, and the two are no longer the same —
/// so the coupon simply never works, the human-readable line under the bars shows the
/// stripped form too, and nothing anywhere reports it.
struct CouponCodeTests {

    // MARK: - What survives

    @Test("plain codes are untouched", arguments: ["SAVE5", "SAVE-5", "A1", "2FOR20", "-"])
    func plainCodesSurvive(code: String) {
        #expect(CouponCode.isRedeemableWhenPrinted(code))
        #expect(CouponCode.sanitized(code) == code)
        #expect(CouponCode.unscannableCharacters(code).isEmpty)
    }

    /// Case and surrounding whitespace are NORMALIZED, not stripped — the stored code is
    /// upper-cased and trimmed too, so these still match.
    @Test("case and surrounding whitespace are fine", arguments: ["save5", "  SAVE5  ", "Save5"])
    func normalizationIsNotMutilation(code: String) {
        #expect(CouponCode.isRedeemableWhenPrinted(code))
        #expect(CouponCode.sanitized(code) == "SAVE5")
    }

    // MARK: - What does not

    /// The reported case: `SAVE_5` prints and scans as `SAVE5`, which the exact-match gate
    /// never accepts.
    @Test("an underscore makes the printed code unredeemable")
    func underscoreIsRejected() {
        #expect(CouponCode.isRedeemableWhenPrinted("SAVE_5") == false)
        #expect(CouponCode.sanitized("SAVE_5") == "SAVE5")
        #expect(CouponCode.unscannableCharacters("SAVE_5") == ["_"])
    }

    @Test("every character a barcode would drop", arguments: [
        ("20%OFF", ["%"]),
        ("SAVE 5", ["space"]),
        ("SAVE!5", ["!"]),
        ("A.B", ["."]),
        ("A/B", ["/"]),
        ("CAFÉ", ["É"]),
    ] as [(String, [String])])
    func rejectedCharactersAreNamed(code: String, offenders: [String]) {
        #expect(CouponCode.isRedeemableWhenPrinted(code) == false)
        #expect(CouponCode.unscannableCharacters(code) == offenders)
    }

    /// A space is the one a manager cannot see. Naming it "space" rather than printing it
    /// into the sentence is the difference between an actionable message and a blank.
    @Test("invisible characters are named, not printed")
    func invisiblesAreNamed() {
        #expect(CouponCode.unscannableCharacters("SAVE 5") == ["space"])
        #expect(CouponCode.unscannableCharacters("SAVE\t5") == ["tab"])
    }

    @Test("each offending character is named once, in the order it appears")
    func offendersAreDistinctAndOrdered() {
        #expect(CouponCode.unscannableCharacters("A_B%C_D") == ["_", "%"])
    }

    // MARK: - The ASCII clause, which is not decoration

    /// `Character.isNumber` is true for EVERY Unicode number, and an earlier filter tested
    /// it without `isASCII`. Those characters reached `GS k 73`, whose length byte counts
    /// BYTES while the string was measured in CHARACTERS — a single one of these produced
    /// a barcode with a wrong length prefix and a garbled payload.
    ///
    /// Worse than the stripping it sits beside: not a code that fails to match, but a byte
    /// stream the printer cannot parse.
    @Test("non-ASCII numerals are refused, not silently encoded", arguments: [
        "\u{00BD}",  // ½  VULGAR FRACTION ONE HALF
        "\u{0663}",  // ٣  ARABIC-INDIC DIGIT THREE
        "\u{2160}",  // Ⅰ  ROMAN NUMERAL ONE
    ])
    func nonAsciiNumeralsAreRefused(character: String) {
        let scalar = character.unicodeScalars.first!
        #expect(Character(scalar).isNumber, "precondition: Swift calls this a number")
        #expect(Character(scalar).isASCII == false)
        #expect(CouponCode.isScannable(Character(scalar)) == false,
                "isNumber alone would admit this and corrupt the barcode's length prefix")
        #expect(CouponCode.isRedeemableWhenPrinted("SAVE" + character) == false)
    }

    // MARK: - The draft rule

    private func printingDraft(code: String) -> DealDraft {
        var draft = DealDraft(id: "deal-1")
        draft.name = "Weekend Wine"
        draft.discount = .flatPercentOff(percent: "10")
        draft.couponCode = code
        draft.printEnabled = true
        draft.print.headline = "$5 OFF"
        return draft
    }

    @Test("a printing deal cannot be saved with an unscannable code")
    func printingDealRefusesIt() {
        let draft = printingDraft(code: "SAVE_5")
        #expect(draft.canSave == false)
        #expect(draft.validationErrors.contains(.printCouponCodeNotScannable(["_"])))
    }

    @Test("a printing deal with a plain code saves")
    func printingDealAcceptsAPlainCode() {
        #expect(printingDraft(code: "SAVE5").canSave)
    }

    /// SCOPED TO PRINTING, and that is the whole design. A code like `20%OFF` works
    /// perfectly well when it is only ever typed at the register, so rejecting it outright
    /// would break deals that are fine today. It is only broken by being printed.
    @Test("a deal that does not print may keep any code")
    func nonPrintingDealsAreUnaffected() {
        var draft = printingDraft(code: "20%OFF")
        draft.printEnabled = false
        #expect(draft.canSave)
    }

    /// One instruction per empty field: "add a code" and "remove these characters" must
    /// never both appear about the same blank input.
    @Test("an empty code reports only that it is missing")
    func emptyCodeReportsOneThing() {
        let errors = printingDraft(code: "   ").validationErrors
        #expect(errors.contains(.printNeedsCouponCode))
        #expect(errors.contains { if case .printCouponCodeNotScannable = $0 { return true }; return false } == false)
    }

    @Test("the message names the characters to remove")
    func messageNamesTheCharacters() {
        let message = DraftError.printCouponCodeNotScannable(["_", "space"]).message
        #expect(message.contains("_"))
        #expect(message.contains("space"))
        #expect(message.isEmpty == false)
    }
}
