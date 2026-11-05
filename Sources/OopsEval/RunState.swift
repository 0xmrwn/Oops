import Foundation
import OopsCore

/// One model's pending jobs, and what became of them.
actor Queue {
    private var jobs: [Harness.Job]
    private(set) var deferredUntil: Date?
    private var written = 0, skipped = 0, surface: String?, effort: String?
    private(set) var failure: String?

    init(_ jobs: [Harness.Job]) { self.jobs = jobs.reversed() }
    func next() -> Harness.Job? { failure == nil ? jobs.popLast() : nil }
    func stop(_ reason: String) { failure = failure ?? reason }
    func `defer`(until: Date) { deferredUntil = max(deferredUntil ?? until, until) }
    func skip() { skipped += 1 }
    func wrote(_ record: CallRecord) { written += 1; surface = record.surface; effort = record.effort }
    var summary: (written: Int, skipped: Int, until: Date?, surface: String?, effort: String?) { (written, skipped, deferredUntil, surface, effort) }
}

/// A line on stderr every 30 s: each lane's calls done out of its total.
actor Progress {
    private var lanes: [(name: String, total: Int, done: Int, deferred: Int)]
    init(_ lanes: [(String, Int)]) { self.lanes = lanes.filter { $0.1 > 0 }.map { ($0.0, $0.1, 0, 0) } }
    func step(_ name: String, deferred: Bool) {
        guard let index = lanes.firstIndex(where: { $0.name == name }) else { return }
        if deferred { lanes[index].deferred += 1 } else { lanes[index].done += 1 }
    }

    func print() {
        let parts = lanes.filter { $0.done + $0.deferred < $0.total }.map { "\($0.name.replacingOccurrences(of: ".jsonl", with: "")) \($0.done)/\($0.total)" + ($0.deferred > 0 ? " (\($0.deferred) deferred)" : "") }
        guard !parts.isEmpty else { return }
        FileHandle.standardError.write(Data((CallRecord.timestamp(Date()) + " " + parts.joined(separator: " · ") + "\n").utf8))
    }
}

extension Manifest {
    /// Another `lanes` run may share the folder (one per provider, say): under a lock, the manifest on
    /// disk is read again and only this run's lanes, providers and session replace what it holds.
    func save(files: Set<String>, providers: Set<String>, session: String, to url: URL) throws {
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path + ".lock"]) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }
        var latest = Manifest.read(url) ?? self
        latest.lanes = latest.lanes.filter { !files.contains($0.file) } + lanes.filter { files.contains($0.file) }
        for name in providers { latest.providers[name] = self.providers[name] }
        latest.sessions = latest.sessions.filter { $0.id != session } + sessions.filter { $0.id == session }
        latest.datasets = Array(Set(latest.datasets + datasets)).sorted()
        latest.prompt = prompt; latest.attempts = attempts; latest.cases = cases; latest.updated = updated
        try latest.write(to: url)
    }
}
