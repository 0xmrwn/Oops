import Testing
@testable import OopsCore

struct WheelInkTests {
    private func ink(_ gray: Double?, systemDark: Bool = false, contrast: Bool = false, transparency: Bool = false) -> WheelInk {
        WheelInk(page: gray.map { CaretStyle(color: SIMD3($0, $0, $0)) }, systemDark: systemDark, increaseContrast: contrast, reduceTransparency: transparency)
    }

    @Test func `dark text means dark labels`() {
        #expect(ink(0.1, systemDark: false).dark)
        #expect(ink(0.1, systemDark: true).dark)
    }

    @Test func `light text means light labels`() {
        #expect(!ink(0.95, systemDark: false).dark)
        #expect(!ink(0.95, systemDark: true).dark)
    }

    @Test func `no colour follows the system`() {
        #expect(!ink(nil, systemDark: true).dark)
        #expect(ink(nil, systemDark: false).dark)
        #expect(!ink(0.46, systemDark: true).dark)
        #expect(ink(0.46, systemDark: false).dark)
    }

    @Test func `pure black in dark mode follows the system, except on a web page`() {
        #expect(!ink(0, systemDark: true).dark)
        #expect(ink(0, systemDark: false).dark)
        #expect(ink(0.02, systemDark: true).dark)
        #expect(WheelInk(page: CaretStyle(color: SIMD3(0, 0, 0)), web: true, systemDark: true, increaseContrast: false, reduceTransparency: false).dark)
    }

    @Test func `contrast and transparency use the plain ink`() {
        #expect(ink(nil, contrast: true).plain)
        #expect(ink(nil, transparency: true).plain)
        #expect(!ink(nil).plain)
    }
}
