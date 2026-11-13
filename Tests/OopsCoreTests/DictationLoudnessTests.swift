import XCTest
@testable import OopsCore

final class DictationLoudnessTests: XCTestCase {
    /// A block of a sine at `amplitude`, as the audio thread sums it.
    private func level(amplitude: Float, dc: Float = 0) -> Float {
        let count = 480
        var sum: Float = 0, squares: Float = 0
        for index in 0 ..< count {
            let value = dc + amplitude * sin(2 * .pi * 440 * Float(index) / 48_000)
            sum += value; squares += value * value
        }
        return DictationLoudness.normalized(rms: DictationLoudness.rms(sum: sum, sumOfSquares: squares, count: count))
    }

    func testSilenceReadsZero() {
        XCTAssertEqual(level(amplitude: 0), 0)
        XCTAssertEqual(DictationLoudness.rms(sum: 0, sumOfSquares: 0, count: 0), 0)
    }

    func testFullScaleSineReadsOne() {
        XCTAssertEqual(level(amplitude: 1), 1)
    }

    func testLevelRisesWithAmplitude() {
        let levels = [0.006, 0.01, 0.03, 0.1, 0.3].map { level(amplitude: Float($0)) }
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, levels.count)
        XCTAssertGreaterThan(levels[0], 0)
        XCTAssertLessThan(levels[4], 1)
    }

    func testConstantOffsetIsNotLoudness() {
        XCTAssertEqual(level(amplitude: 0, dc: 0.5), 0)
        XCTAssertEqual(level(amplitude: 0.1, dc: 0.5), level(amplitude: 0.1), accuracy: 0.01)
    }

    func testAttackIsFasterThanRelease() {
        let dt: Float = 1 / 60
        let rise = DictationLoudness.smoothed(0, toward: 1, dt: dt)
        let fall = 1 - DictationLoudness.smoothed(1, toward: 0, dt: dt)
        XCTAssertGreaterThan(rise, fall)
        XCTAssertGreaterThan(rise, 0.3)
    }

    func testLevelDecaysToZeroAfterInputStops() {
        var level: Float = 1
        var previous = level
        for _ in 0 ..< 180 {
            level = DictationLoudness.smoothed(level, toward: 0, dt: 1 / 60)
            XCTAssertLessThanOrEqual(level, previous)
            previous = level
        }
        XCTAssertEqual(level, 0)
    }

    func testSmoothingNeverOvershootsAndIgnoresNegativeTime() {
        XCTAssertLessThanOrEqual(DictationLoudness.smoothed(0.2, toward: 0.6, dt: 10), 0.6)
        XCTAssertEqual(DictationLoudness.smoothed(0.2, toward: 0.6, dt: -1), 0.2)
    }
}
