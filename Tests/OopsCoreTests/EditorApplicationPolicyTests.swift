import XCTest
@testable import OopsCore

final class EditorApplicationPolicyTests: XCTestCase {
    private let teams = URL(fileURLWithPath: "/Applications/Microsoft Teams.app", isDirectory: true)
    private var helper: URL { teams.appendingPathComponent("Contents/Helpers/Microsoft Teams WebView.app") }

    private func verdict(_ id: String?, _ url: URL?, foregroundID: String? = "com.microsoft.teams2", foregroundURL: URL? = nil,
                         off: Set<String> = []) -> EditorApplicationPolicy.Verdict {
        EditorApplicationPolicy.verdict(bundleID: id, bundleURL: url, foregroundBundleID: foregroundID,
                                        foregroundBundleURL: foregroundURL ?? teams, turnedOff: off)
    }

    func testHelpersInsideTheFrontmostBundleStandForIt() {
        XCTAssertEqual(verdict("com.microsoft.teams2.helper", helper), .accepted(bundleID: "com.microsoft.teams2", nested: true))
        let renderer = helper.appendingPathComponent("Contents/Frameworks/Microsoft Edge Framework.framework/Versions/149.0/Helpers/Microsoft Teams WebView Helper (Renderer).app")
        XCTAssertEqual(verdict("com.microsoft.teams2.helper", renderer), .accepted(bundleID: "com.microsoft.teams2", nested: true))
        XCTAssertEqual(verdict("com.microsoft.teams2", teams), .accepted(bundleID: "com.microsoft.teams2", nested: false))
    }

    func testOnlyRealContainmentCounts() {
        for url in [URL(fileURLWithPath: "/tmp/Microsoft Teams WebView.app"), URL(fileURLWithPath: teams.path + "-unrelated.app"),
                    helper.appendingPathComponent("../../../../Other.app")] {
            XCTAssertEqual(verdict("com.microsoft.teams2.helper", url), .accepted(bundleID: "com.microsoft.teams2.helper", nested: false), url.path)
        }
        XCTAssertEqual(verdict(nil, nil), .unknown)
    }

    func testAnyOtherAppIsAcceptedUnlessDeniedOrTurnedOff() {
        let obsidian = URL(fileURLWithPath: "/Applications/Obsidian.app")
        XCTAssertEqual(verdict("md.obsidian", obsidian, foregroundID: "md.obsidian", foregroundURL: obsidian), .accepted(bundleID: "md.obsidian", nested: false))
        XCTAssertEqual(verdict("md.obsidian", obsidian, foregroundID: "md.obsidian", foregroundURL: obsidian, off: ["md.obsidian"]), .turnedOff)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        XCTAssertEqual(verdict("com.apple.Terminal", terminal, foregroundID: "com.apple.Terminal", foregroundURL: terminal), .denied)
        let onePassword = URL(fileURLWithPath: "/Applications/1Password.app")
        XCTAssertEqual(verdict("com.1password.1password.helper", onePassword.appendingPathComponent("Contents/Helpers/H.app"),
                               foregroundID: "com.1password.1password", foregroundURL: onePassword), .denied)
    }

    func testMaskedValuesAreSecrets() {
        XCTAssertTrue(SensitiveField.isMasked("••••••"))
        XCTAssertTrue(SensitiveField.isMasked("●●●● "))
        XCTAssertFalse(SensitiveField.isMasked("• one point"))
        XCTAssertFalse(SensitiveField.isMasked(""))
    }

    func testSensitiveFieldsAreRecognisedByTheirDescriptions() {
        for text in ["Password", "Mot de passe", "Enter your PIN", "one-time code", "current-password", "cc-number", "API key"] {
            XCTAssertTrue(SensitiveField.matches(["", text]), text)
        }
        for text in ["Message", "Reply to Alice", "Search", "Spinning up", "Pinned messages", "Write a passage"] {
            XCTAssertFalse(SensitiveField.matches([text]), text)
        }
    }
}
