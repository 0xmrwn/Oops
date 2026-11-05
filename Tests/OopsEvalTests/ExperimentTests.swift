import Foundation
import XCTest
@testable import OopsEval

final class ExperimentTests: XCTestCase {
    private func identity() -> Experiment {
        Experiment(casesSha256: "cases", configSha256: "settings", sourceSha256: "source", sourceRevision: "revision",
                   prompt: "rules contract", promptSha256: "prompt", attempts: 2)
    }

    func testResumeRejectsEveryGenerationIdentityChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = identity()
        for (name, content) in ["cases.jsonl": "case\n", "config.json": "{}"] {
            let data = Data(content.utf8)
            try data.write(to: directory.appendingPathComponent(name))
            original.snapshots[name] = Experiment.digest(data)
        }
        try Manifest.encoder.encode(original).write(to: directory.appendingPathComponent("experiment.json"))
        XCTAssertNoThrow(try original.validate(in: directory))
        let results = directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        let record = results.appendingPathComponent("api--model.jsonl")
        try Data("record\n".utf8).write(to: record)
        XCTAssertThrowsError(try original.validate(in: directory))
        try FileManager.default.removeItem(at: record)
        var changed = original
        changed.prompt = "different"
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.casesSha256 = "changed"
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.configSha256 = "changed"
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.sourceSha256 = "changed"
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.attempts = 5
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.limit = 10
        XCTAssertThrowsError(try changed.validate(in: directory))
        changed = original; changed.pricesSha256 = "changed"
        XCTAssertThrowsError(try changed.validate(in: directory))
        try Data("changed".utf8).write(to: directory.appendingPathComponent("cases.jsonl"))
        XCTAssertThrowsError(try original.validate(in: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("cases.jsonl"))
        XCTAssertThrowsError(try original.validate(in: directory))
    }

    func testLegacyRunsCannotBeSilentlyAdopted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try identity().validate(in: directory))
    }

    func testOnlyOneGeneratorCanOwnARun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let first = try RunLock(directory)
            XCTAssertThrowsError(try RunLock(directory))
            withExtendedLifetime(first) {}
        }
        XCTAssertNoThrow(try RunLock(directory))
    }

    func testSnapshotsPreserveFamiliesAndAlternativeAnswers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("input.json")
        try Data("{\"providers\":[]}".utf8).write(to: config)
        var item = EvalCase(id: "a", input: "teh cat", expected: "the cat", label: .accepted)
        item.alternatives = ["The cat"]; item.family = "root"
        var experiment = identity()
        experiment.snapshots = ["cases.jsonl": Experiment.digest(try Corpus.data([item])), "config.json": Experiment.digest(try Data(contentsOf: config))]
        try experiment.save(in: directory, cases: [item], config: config)
        let copy = try Corpus.read(directory.appendingPathComponent("cases.jsonl"))
        XCTAssertEqual(copy.first?.family, "root")
        XCTAssertEqual(Runner.verdict("The cat", for: item), .exact)
        XCTAssertEqual(Checks.verdict("The cat", for: item), "exact")
    }
}
