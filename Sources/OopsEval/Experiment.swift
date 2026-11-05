import CryptoKit
import Foundation
import OopsCore

/// Generation identity is immutable. Judgments can be replaced without changing these measurements.
struct Experiment: Codable, Equatable {
    var schemaVersion = 2
    var kind = "generation"
    var casesSha256: String
    var configSha256: String
    var sourceSha256: String
    var sourceRevision: String
    var prompt: String
    var promptSha256: String
    var attempts: Int
    var limit: Int?
    var pricesSha256: String? = nil
    var snapshots: [String: String] = [:]
    var runtime: [String: String] = [:]

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func make(cases: URL, selected: [EvalCase], config: URL, attempts: Int, limit: Int?) throws -> Experiment {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = root.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            throw CorrectionError.message("Run lanes from the Oops checkout so its source can be fingerprinted.")
        }
        let files = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift" && ($0.path.contains("/OopsCore/") || $0.path.contains("/OopsEval/"))
        }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw CorrectionError.message("No evaluation source found in this checkout.") }
        var data = Data()
        for file in files + [root.appendingPathComponent("Package.swift")] {
            data.append(Data(file.path.replacingOccurrences(of: root.path + "/", with: "").utf8)); data.append(0)
            data.append(try Data(contentsOf: file)); data.append(0)
        }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["rev-parse", "HEAD"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let revision = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CorrectionError.message("Can't identify the source revision.") }
        var experiment = Experiment(casesSha256: digest(try Data(contentsOf: cases)), configSha256: digest(try Data(contentsOf: config)),
                          sourceSha256: digest(data), sourceRevision: revision, prompt: CorrectionPolicy.instructions,
                          promptSha256: digest(Data(CorrectionPolicy.instructions.utf8)), attempts: attempts, limit: limit)
        if let prices = try LanesConfig.read(config).prices {
            experiment.pricesSha256 = digest(try Data(contentsOf: config.deletingLastPathComponent().appendingPathComponent(prices)))
        }
        experiment.snapshots = ["cases.jsonl": digest(try Corpus.data(selected)), "config.json": experiment.configSha256]
        if let prices = experiment.pricesSha256 { experiment.snapshots["prices.json"] = prices }
        let system = ProcessInfo.processInfo
        experiment.runtime = ["os": system.operatingSystemVersionString, "processors": String(system.processorCount),
                              "memory_bytes": String(system.physicalMemory)]
        if let executable = Bundle.main.executableURL {
            experiment.runtime["executable_sha256"] = digest(try Data(contentsOf: executable))
        }
        return experiment
    }

    func validate(in directory: URL) throws {
        let url = directory.appendingPathComponent("experiment.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let old = try Manifest.decoder.decode(Experiment.self, from: Data(contentsOf: url))
            guard old == self else {
                throw CorrectionError.message("Experiment changed (corpus, prompt, source, settings or attempts). Use a new --run; resume cannot mix experiments.")
            }
            try verifySnapshots(in: directory)
            let results = directory.appendingPathComponent("results")
            let files = (try? FileManager.default.contentsOfDirectory(at: results, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path),
               try files.contains(where: {
                   guard $0.pathExtension == "jsonl" else { return false }
                   return try ($0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
               }) {
                throw CorrectionError.message("Generation records exist but their manifest is missing. Restore it before resuming.")
            }
        } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            throw CorrectionError.message("This legacy run has no experiment snapshot. Keep its results and choose a new --run.")
        }
    }

    func save(in directory: URL, cases: [EvalCase], config: URL) throws {
        let url = directory.appendingPathComponent("experiment.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Corpus.write(cases, to: directory.appendingPathComponent("cases.jsonl"))
        try Data(contentsOf: config).write(to: directory.appendingPathComponent("config.json"), options: .atomic)
        if let prices = try LanesConfig.read(config).prices {
            try Data(contentsOf: config.deletingLastPathComponent().appendingPathComponent(prices)).write(to: directory.appendingPathComponent("prices.json"), options: .atomic)
        }
        try verifySnapshots(in: directory)
        try Manifest.encoder.encode(self).write(to: url, options: .atomic)
    }

    private func verifySnapshots(in directory: URL) throws {
        guard schemaVersion == 2, kind == "generation", snapshots["cases.jsonl"] != nil, snapshots["config.json"] != nil else {
            throw CorrectionError.message("This run has no verified generation snapshots. Use a new --run.")
        }
        for (name, hash) in snapshots {
            guard ["cases.jsonl", "config.json", "prices.json"].contains(name),
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)), Self.digest(data) == hash else {
                throw CorrectionError.message("Missing or changed experiment snapshot: \(name). Restore the snapshot before resuming.")
            }
        }
    }
}

/// Providers already run in parallel inside one process. Two writers must not send the same jobs.
final class RunLock {
    private let descriptor: Int32
    init(_ directory: URL) throws {
        descriptor = open(directory.appendingPathComponent(".generation.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CorrectionError.message("Can't open the run lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CorrectionError.message("This run is already generating. Wait for it to finish before resuming.")
        }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
