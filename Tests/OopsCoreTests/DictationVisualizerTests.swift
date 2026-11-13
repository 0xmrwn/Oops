import XCTest
@testable import OopsCore

final class DictationVisualizerTests: XCTestCase {
    func testStoredKindDefaultsToHexAndReadsItsRawValue() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictationVisualizerTests"))
        defaults.removePersistentDomain(forName: "DictationVisualizerTests")
        XCTAssertEqual(DictationVisualizer.stored(in: defaults), .hex)
        defaults.set("ripple", forKey: DictationVisualizer.defaultsKey)
        XCTAssertEqual(DictationVisualizer.stored(in: defaults), .ripple)
        defaults.set("gone", forKey: DictationVisualizer.defaultsKey)
        XCTAssertEqual(DictationVisualizer.stored(in: defaults), .hex)
        defaults.removePersistentDomain(forName: "DictationVisualizerTests")
    }

    // MARK: History

    func testHistoryRecordsOneSampleAnIntervalNewestFirst() {
        var history = LoudnessHistory(capacity: 4, interval: 0.25)
        for (index, level) in [Float(0.1), 0.2, 0.3, 0.4, 0.5].enumerated() {
            history.advance(to: Double(index) * 0.25, level: level)
        }
        XCTAssertEqual((0..<4).map { history[$0] }, [0.4, 0.3, 0.2, 0.1])
        XCTAssertEqual(history.next, 0.5)
        XCTAssertEqual(history[4], 0)
        XCTAssertEqual(history[-1], 0)
    }

    func testHistoryKeepsTheLoudestLevelOfEachInterval() {
        var history = LoudnessHistory(capacity: 4, interval: 0.1)
        history.advance(to: 0, level: 0)
        history.advance(to: 0.03, level: 0.9) // a syllable shorter than an interval
        history.advance(to: 0.06, level: 0.1)
        history.advance(to: 0.1, level: 0.2)
        XCTAssertEqual(history[0], 0.9)
        XCTAssertEqual(history.next, 0.2)
    }

    func testHistoryProgressGlidesBetweenSamplesAndIgnoresRepeatedTimes() {
        var history = LoudnessHistory(capacity: 4, interval: 0.1)
        history.advance(to: 0, level: 0.5)
        history.advance(to: 0.05, level: 0.5)
        XCTAssertEqual(history.progress, 0.5, accuracy: 1e-9)
        let before = history
        history.advance(to: 0.05, level: 0.5)
        history.advance(to: 0.02, level: 0.5)
        XCTAssertEqual(history[0], before[0]); XCTAssertEqual(history[1], before[1])
    }

    func testHistoryFillsAGapWithWhatWasLastHeardThenScrollsItAway() {
        var history = LoudnessHistory(capacity: 3, interval: 0.1)
        history.advance(to: 0, level: 0.8)
        history.advance(to: 60, level: 0)
        XCTAssertEqual((0..<3).map { history[$0] }, [0.8, 0.8, 0.8])
        for step in 1...3 { history.advance(to: 60 + Double(step) * 0.1 + 0.01, level: 0) }
        XCTAssertTrue(history.isSilent)
    }

    func testHistoryResumedAfterSilenceRecordsSilenceForTheGap() {
        var history = LoudnessHistory(capacity: 3, interval: 0.1)
        history.advance(to: 0, level: 0.8)
        history.reset()
        XCTAssertTrue(history.isSilent)
        history.advance(to: 0, level: 0)
        history.advance(to: 30, level: 0.6)
        XCTAssertEqual((0..<3).map { history[$0] }, [0, 0, 0])
        XCTAssertEqual(history.next, 0.6)
    }

    // MARK: Ripple

    func testSilenceSendsNoRings() {
        var emitter = RippleEmitter()
        for frame in 0..<240 { emitter.step(time: Double(frame) / 120, level: 0) }
        XCTAssertTrue(emitter.rings.isEmpty)
    }

    func testAnOnsetSendsOneRingAndAHeldLevelNoMore() {
        var emitter = RippleEmitter()
        for frame in 0..<12 { emitter.step(time: Double(frame) / 120, level: 0) }
        for frame in 12..<120 { emitter.step(time: Double(frame) / 120, level: 0.6) }
        XCTAssertEqual(emitter.rings.count, 1)
        XCTAssertEqual(emitter.rings.first?.amplitude, 0.6)
    }

    func testARingTakesThePeakOfTheAttackThatSentIt() {
        var emitter = RippleEmitter()
        emitter.step(time: 0, level: 0)
        for (frame, level) in [Float(0.15), 0.4, 0.8, 0.95, 0.7, 0.5].enumerated() { emitter.step(time: Double(frame + 1) / 120, level: level) }
        XCTAssertEqual(emitter.rings.map(\.amplitude), [0.95])
    }

    func testRingsExpireAfterTheirLifetime() {
        var emitter = RippleEmitter()
        emitter.step(time: 0, level: 0)
        emitter.step(time: 0.01, level: 0.7)
        XCTAssertEqual(emitter.rings.count, 1)
        emitter.step(time: 0.01 + RippleEmitter.lifetime, level: 0.7)
        XCTAssertTrue(emitter.rings.isEmpty)
    }

    func testSpeechSendsRingsAtAboutItsSyllableRateAndNeverCloserThanTheRefractoryGap() {
        var emitter = RippleEmitter()
        var births: [Double] = []
        // The first phrase of the synthetic curve: 9 syllables between 2.0 s and about 4.2 s.
        for frame in Int(1.5 * 120)..<Int(4.6 * 120) {
            let time = Double(frame) / 120
            emitter.step(time: time, level: SyntheticLoudness.level(at: time))
            if let ring = emitter.rings.last, ring.born == time { births.append(time) }
        }
        XCTAssertGreaterThanOrEqual(births.count, 7)
        XCTAssertLessThanOrEqual(births.count, 10)
        for (earlier, later) in zip(births, births.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, RippleEmitter.refractory - 1e-9)
        }
    }
}

final class VisualizerSyntheticLoudnessTests: XCTestCase {
    private let frames = Array(stride(from: 0.0, to: SyntheticLoudness.period, by: 1.0 / 120))

    func testLevelStaysWithinZeroAndOne() {
        for time in frames { XCTAssert((0...1).contains(SyntheticLoudness.level(at: time)), "\(time)") }
    }

    func testSameTimeGivesTheSameLevelAndTheCurveLoops() {
        for time in [0.0, 2.3, 5.51, 7.64, 9.0] {
            XCTAssertEqual(SyntheticLoudness.level(at: time), SyntheticLoudness.level(at: time))
            XCTAssertEqual(SyntheticLoudness.level(at: time), SyntheticLoudness.level(at: time + SyntheticLoudness.period * 3), accuracy: 1e-5)
        }
    }

    func testOpensAndClosesInTrueSilence() {
        for time in stride(from: 0.0, to: SyntheticLoudness.silenceEnds, by: 0.01) { XCTAssertEqual(SyntheticLoudness.level(at: time), 0) }
        for time in stride(from: 10.5, to: SyntheticLoudness.period, by: 0.01) { XCTAssertEqual(SyntheticLoudness.level(at: time), 0) }
    }

    func testBurstReachesNearlyFullScaleAndSpeechStaysWellBelowIt() {
        XCTAssertGreaterThan(frames.map(SyntheticLoudness.level(at:)).max() ?? 0, 0.95)
        let phrase = frames.filter { $0 < SyntheticLoudness.burstStarts }.map(SyntheticLoudness.level(at:))
        XCTAssertLessThan(phrase.max() ?? 1, 0.85)
        XCTAssertGreaterThan(phrase.max() ?? 0, 0.4)
    }

    func testSyllablesModulateTheLevelWithinAWord() {
        // Inside the first word the level dips between syllables rather than holding flat.
        let word = stride(from: 2.0, to: 2.6, by: 1.0 / 120).map(SyntheticLoudness.level(at:))
        let peaks = zip(zip(word, word.dropFirst()), word.dropFirst(2)).filter { $0.0.1 > $0.0.0 && $0.0.1 >= $0.1 && $0.0.1 > 0.3 }
        XCTAssertGreaterThanOrEqual(peaks.count, 3)
        XCTAssertLessThan(word.dropFirst(30).min() ?? 1, 0.3)
    }
}
