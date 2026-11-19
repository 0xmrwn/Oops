import OopsCore
import XCTest

/// Which steps first run shows for each choice of features.
final class OnboardingFlowTests: XCTestCase {
    func testWithoutTheChoiceTheFlowIsFixsOwn() {
        XCTAssertEqual(OnboardingStep.setup(for: [.fix, .dictate], choice: false), [.provider, .shortcut, .accessibility, .tryIt, .home])
        XCTAssertEqual(OnboardingStep.setup(for: [], choice: false), [.provider, .shortcut, .accessibility, .tryIt, .home])
    }

    func testFixBringsTheProviderStep() {
        XCTAssertEqual(OnboardingStep.setup(for: [.fix], choice: true), [.features, .provider, .shortcut, .accessibility, .tryIt, .home])
        XCTAssertEqual(OnboardingStep.setup(for: [.fix, .dictate], choice: true), [.features, .provider, .shortcut, .accessibility, .tryIt, .home])
    }

    func testDictateAloneNeedsNoProvider() {
        XCTAssertEqual(OnboardingStep.setup(for: [.dictate], choice: true), [.features, .shortcut, .accessibility, .tryIt, .home])
    }

    func testAnUnfinishedRunResumesAtASavedStep() {
        XCTAssertEqual(OnboardingStep(rawValue: "features"), .features)
        XCTAssertEqual(OnboardingStep(rawValue: "tryIt"), .tryIt)
    }
}
