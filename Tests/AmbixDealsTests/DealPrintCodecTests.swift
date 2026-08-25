import Foundation
import Testing

@testable import AmbixDeals

/// `Deal.print` — the config that decides whether a deal advertises itself on paper.
///
/// The load-bearing property here is the DIRECTION of decode failure. `print` fails CLOSED
/// to `nil`, matching `scope`'s own doctrine that "garbage data must never silently become
/// a storewide discount" — garbage must not silently become paper in a customer's hand
/// either. Every malformed shape below must yield `nil`, never a partial `DealPrint`.

/// A complete deal document, with `print` swapped in per test.
private func dealJSON(print: String?) -> String {
    let printEntry = print.map { ",\"print\":\($0)" } ?? ""
    return """
    {"id":"deal-1","name":"Aug wknd scotch -5","isActive":true,
     "channel":"inStore","audience":"any",
     "discount":{"kind":"flatAmountOff","amount":5.00}\(printEntry)}
    """
}

private func decode(_ json: String) throws -> Deal {
    try JSONDecoder().decode(Deal.self, from: Data(json.utf8))
}

// MARK: - The default

@Test("a deal with no print config decodes to nil, so nothing starts printing by surprise")
func absentPrintIsNil() throws {
    #expect(try decode(dealJSON(print: nil)).print == nil)
}

// MARK: - What decodes

@Test("a complete print config round-trips every field")
func completeConfigDecodes() throws {
    let deal = try decode(dealJSON(print: """
        {"trigger":{"type":"always"},"priority":7,
         "headline":"$5 OFF YOUR NEXT VISIT","terms":"On purchases of $30 or more."}
        """))
    #expect(deal.print?.trigger == .always)
    #expect(deal.print?.priority == 7)
    #expect(deal.print?.headline == "$5 OFF YOUR NEXT VISIT")
    #expect(deal.print?.terms == "On purchases of $30 or more.")
}

@Test("every trigger shape decodes")
func everyTriggerDecodes() throws {
    let cases: [(String, DealPrintTrigger)] = [
        (#"{"type":"always"}"#, .always),
        (#"{"type":"basketHasCategory","names":["Scotch","Bourbon"]}"#,
         .basketHasCategory(names: ["Scotch", "Bourbon"])),
        (#"{"type":"basketHasProduct","ids":["sku-1"]}"#, .basketHasProduct(ids: ["sku-1"])),
        // Dollars on the wire, like every other money field in this package.
        (#"{"type":"saleOver","amount":30.00}"#, .saleOver(Money(cents: 3000))),
    ]
    for (json, expected) in cases {
        let deal = try decode(dealJSON(print: #"{"trigger":\#(json)}"#))
        #expect(deal.print?.trigger == expected, "trigger \(json)")
    }
}

@Test("priority defaults to 0 and copy is optional — a config need only say WHEN")
func minimalConfigDecodes() throws {
    let deal = try decode(dealJSON(print: #"{"trigger":{"type":"always"}}"#))
    #expect(deal.print?.priority == 0)
    #expect(deal.print?.headline == nil)
    #expect(deal.print?.terms == nil)
}

// MARK: - Fail CLOSED

/// Every shape a malformed `print` can take. Each must decode the DEAL successfully and
/// leave `print` nil — a deal must never fail to decode because its advertising is broken,
/// and broken advertising must never become paper.
private let malformed: [(String, String)] = [
    ("no trigger at all", #"{"priority":3,"headline":"$5 OFF"}"#),
    ("unrecognized trigger type", #"{"trigger":{"type":"whenTheMoonIsFull"}}"#),
    ("trigger is not an object", #"{"trigger":"always"}"#),
    ("category trigger missing its names", #"{"trigger":{"type":"basketHasCategory"}}"#),
    ("category names is not an array", #"{"trigger":{"type":"basketHasCategory","names":"Scotch"}}"#),
    ("product trigger missing its ids", #"{"trigger":{"type":"basketHasProduct"}}"#),
    ("saleOver missing its amount", #"{"trigger":{"type":"saleOver"}}"#),
    ("saleOver amount is a string", #"{"trigger":{"type":"saleOver","amount":"30"}}"#),
    ("priority is not a number", #"{"trigger":{"type":"always"},"priority":"high"}"#),
    ("headline is not a string", #"{"trigger":{"type":"always"},"headline":42}"#),
    ("print is not an object", #""always""#),
    ("print is an array", #"[{"trigger":{"type":"always"}}]"#),
]

@Test("every malformed print config fails CLOSED to nil", arguments: malformed)
func malformedFailsClosed(testCase: (label: String, json: String)) throws {
    let deal = try decode(dealJSON(print: testCase.json))
    #expect(deal.print == nil, "\(testCase.label) must not become paper")
    // The rest of the deal is untouched — advertising is not load-bearing for pricing.
    #expect(deal.id == "deal-1")
    #expect(deal.discount == .flatAmountOff(amount: Money(cents: 500)))
}

@Test("an explicit JSON null decodes to nil, the same as an absent key")
func explicitNullIsNil() throws {
    #expect(try decode(dealJSON(print: "null")).print == nil)
}

// MARK: - The memberwise init

@Test("print defaults to nil in the memberwise init, so v0.3.0 is source-compatible")
func memberwiseDefaultsToNil() {
    let deal = Deal(
        id: "d", name: "n", isActive: true, channel: .inStore, audience: .any,
        discount: .flatPercentOff(percent: 10), memberDiscount: nil,
        scope: .all, condition: .always, schedule: nil, couponCode: "SAVE5",
        perCustomerLimit: 0, usageLimit: 0, marginFloorOverrideCents: nil)
    #expect(deal.print == nil)
}
