import OopsCore
import XCTest

final class CaretStylePageTests: XCTestCase {
    func testDarkTextIsOnALightPage() {
        XCTAssertEqual(CaretStyle(color: SIMD3(0, 0, 0)).pageIsDark, false)
        XCTAssertEqual(CaretStyle(color: SIMD3(0.13, 0.13, 0.15)).pageIsDark, false)
    }

    func testLightTextIsOnADarkPage() {
        XCTAssertEqual(CaretStyle(color: SIMD3(1, 1, 1)).pageIsDark, true)
        XCTAssertEqual(CaretStyle(color: SIMD3(0.85, 0.86, 0.9)).pageIsDark, true)
    }

    func testAMidToneOrNoColourSaysNothing() {
        XCTAssertNil(CaretStyle(color: SIMD3(0.46, 0.46, 0.46)).pageIsDark)
        XCTAssertNil(CaretStyle().pageIsDark)
    }
}
