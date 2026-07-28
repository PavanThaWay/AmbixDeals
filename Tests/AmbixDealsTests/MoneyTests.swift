import XCTest
@testable import AmbixDeals

final class MoneyTests: XCTestCase {
    func testCentsAndDollars() {
        XCTAssertEqual(Money(dollars: 12.50).cents, 1250)
        XCTAssertEqual(Money(cents: 1250).dollars, 12.50, accuracy: 0.0001)
    }

    func testRoundingHalfUp() {
        // 0.1 * 3 in float is 0.30000000000000004; cents math must stay exact.
        let total = Money(dollars: 0.10) + Money(dollars: 0.10) + Money(dollars: 0.10)
        XCTAssertEqual(total.cents, 30)
    }

    func testFractionalQuantity() {
        // 1.5 lb @ $2.00/lb = $3.00
        XCTAssertEqual(Money(dollars: 2.00).times(1.5).cents, 300)
    }

    func testArithmetic() {
        XCTAssertEqual((Money(dollars: 5.00) - Money(dollars: 1.25)).cents, 375)
        XCTAssertEqual((Money(dollars: 1.00) * 3).cents, 300)
        XCTAssertTrue(Money(cents: 100) > Money(cents: 99))
    }

    // MARK: - init(dollars:) does not trap on pathological input

    /// A huge pasted digit string (an iPad paste bypasses `.decimalPad`) must clamp, not
    /// crash. `Int((dollars * 100).rounded())` used to trap past `Int.max`.
    func testInitDollarsClampsOverflowInsteadOfTrapping() {
        XCTAssertEqual(Money(dollars: 1e30).cents, Int.max)
        XCTAssertEqual(Money(dollars: -1e30).cents, Int.min)
        XCTAssertEqual(Money(dollars: .infinity).cents, Int.max)
        XCTAssertEqual(Money(dollars: -.infinity).cents, Int.min)
        XCTAssertEqual(Money(dollars: .nan).cents, 0)
    }

    /// Ordinary values are unchanged by the overflow guard.
    func testInitDollarsUnchangedForOrdinaryValues() {
        XCTAssertEqual(Money(dollars: 0).cents, 0)
        XCTAssertEqual(Money(dollars: 12.47).cents, 1247)
        XCTAssertEqual(Money(dollars: -3.00).cents, -300)
    }
}
