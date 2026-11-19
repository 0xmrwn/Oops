import OopsCore
import XCTest

/// Who gets the new-feature card, and how many times.
final class FeatureAnnouncementTests: XCTestCase {
    func testSomeoneWhoUpdatedHearsAboutDictateOnce() {
        XCTAssertEqual(FeatureAnnouncement.pending(offered: [.fix, .dictate], on: [.fix], announced: []), .dictate)
        XCTAssertNil(FeatureAnnouncement.pending(offered: [.fix, .dictate], on: [.fix], announced: [.dictate]), "Later was pressed, or first run offered it")
    }

    func testAFeatureAlreadyOnIsNotNews() {
        XCTAssertNil(FeatureAnnouncement.pending(offered: [.fix, .dictate], on: [.fix, .dictate], announced: []))
    }

    func testFixIsNeverAnnouncedAndABuildWithoutDictateSaysNothing() {
        XCTAssertNil(FeatureAnnouncement.pending(offered: [.fix, .dictate], on: [], announced: [.dictate]))
        XCTAssertNil(FeatureAnnouncement.pending(offered: [.fix], on: [], announced: []))
    }
}
