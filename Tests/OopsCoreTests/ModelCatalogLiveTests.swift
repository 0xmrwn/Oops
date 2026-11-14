@testable import OopsCore
import XCTest

/// How live words stream each catalog model: the engine streams only a model whose entry says how.
final class ModelCatalogLiveTests: XCTestCase {
    func testOnlyModelsWithALiveContextStream() {
        for model in SpeechModelCatalog.models {
            XCTAssertEqual(model.streams, model.liveContext != nil, model.id)
        }
    }

    func testParakeetUnifiedStreamsAt160By160() {
        XCTAssertEqual(SpeechModelCatalog.parakeetUnifiedEnglish.liveContext, .chunked(chunkMilliseconds: 160, lookaheadMilliseconds: 160))
    }

    func testNemotronStreamsAtItsShortestLookahead() {
        // The trained menu is 13, 6, 1 and 0 frames.
        XCTAssertEqual(SpeechModelCatalog.nemotron35ASR.liveContext, .cacheAware(lookaheadFrames: 0))
    }
}
