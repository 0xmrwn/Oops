import XCTest
@testable import OopsCore

/// A token read from the Keychain is a new 2 KB string that only the read owns. Release builds of
/// 0.1.0 freed it before the request header was built, and every ChatGPT correction crashed; fake
/// tokens short enough to be stored inline never showed it. Meaningful in a Release build under Address
/// Sanitizer (`just test-release`): a freed string often still reads right until its memory is reused.
final class ChatGPTTokenLifetimeTests: XCTestCase {
    private let access = "eyJ" + String(repeating: "x", count: 2000)

    private func auth() -> ChatGPTAuth {
        ChatGPTAuth(store: MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(access: access), freshTokens: true),
                    session: .shared) { _ in }
    }

    func testAFreshlyReadTokenOutlivesTheRead() async throws {
        let token = try await auth().validAccessToken()
        XCTAssertEqual("Bearer " + token, "Bearer " + access)
    }

    func testAFreshlyReadTokenReachesTheRequestHeader() async throws {
        let header = try await auth().withAccessToken { token in
            try ChatGPTBackend.request(model: "gpt", effort: nil, serviceTier: nil, instructions: CorrectionPolicy.instructions, text: "teh", token: token).value(forHTTPHeaderField: "Authorization")
        }
        XCTAssertEqual(header, "Bearer " + access)
    }
}
