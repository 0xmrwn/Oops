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

    func testAnUnfinishedRunResumesAtASavedStep() {
        XCTAssertEqual(OnboardingStep(rawValue: "features"), .features)
        XCTAssertEqual(OnboardingStep(rawValue: "tryIt"), .tryIt)
    }
}
