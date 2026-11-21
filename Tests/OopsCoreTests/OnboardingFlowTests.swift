import OopsCore
import XCTest

/// Which steps first run shows for each choice of features.
final class OnboardingFlowTests: XCTestCase {
    func testFixBringsTheProviderStep() {
        XCTAssertEqual(OnboardingStep.setup(for: [.fix]), [.features, .provider, .shortcut, .accessibility, .tryIt, .home])
        XCTAssertEqual(OnboardingStep.setup(for: [.fix, .dictate]), [.features, .provider, .shortcut, .accessibility, .tryIt, .home])
    }

    func testDictateAloneNeedsNoProvider() {
        XCTAssertEqual(OnboardingStep.setup(for: [.dictate]), [.features, .shortcut, .accessibility, .tryIt, .home])
    }

    func testDictatesTryNeedsItsShortcutSaved() {
        XCTAssertEqual(OnboardingStep.tries(for: [.fix, .dictate], dictateShortcut: true), [.fix, .dictate])
        XCTAssertEqual(OnboardingStep.tries(for: [.fix, .dictate], dictateShortcut: false), [.fix])
        XCTAssertEqual(OnboardingStep.tries(for: [.dictate], dictateShortcut: true), [.dictate])
        XCTAssertEqual(OnboardingStep.tries(for: [.dictate], dictateShortcut: false), [])
        XCTAssertEqual(OnboardingStep.tries(for: [.fix], dictateShortcut: true), [.fix])
    }

    func testTryItWithNothingToTryIsPassedOver() {
        let alone = OnboardingStep.setup(for: [.dictate])
        XCTAssertEqual(OnboardingStep.accessibility.next(in: alone, tries: [.dictate]), .tryIt)
        XCTAssertEqual(OnboardingStep.accessibility.next(in: alone, tries: []), .home)
        XCTAssertEqual(OnboardingStep.tryIt.next(in: alone, tries: []), .home)
        // The run a new-feature card opens ends after its Shortcut step.
        XCTAssertNil(OnboardingStep.shortcut.next(in: [.shortcut, .tryIt], tries: []))
        XCTAssertEqual(OnboardingStep.shortcut.next(in: [.shortcut, .tryIt], tries: [.dictate]), .tryIt)
        XCTAssertNil(OnboardingStep.home.next(in: alone, tries: [.dictate]))
    }

    func testAnUnfinishedRunResumesAtASavedStep() {
        XCTAssertEqual(OnboardingStep(rawValue: "features"), .features)
        XCTAssertEqual(OnboardingStep(rawValue: "tryIt"), .tryIt)
    }
}
