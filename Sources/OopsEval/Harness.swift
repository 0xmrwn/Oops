import Foundation
import OopsCore

/// Runs every lane of the config over a case file into `runs/<run>/`: providers in parallel, the
/// models of one provider through its shared pacer, each call's record written as it finishes. A
/// rerun sends only the cases and attempts with no record yet; a lane whose daily quota ran out
/// picks up after the reset.
struct Harness {
    struct Options {
        var run: String
        var runs: URL
        var cases: URL
        var config: URL
        var attempts: Int?
        var only: Set<String>?
        var limit: Int?
        var retryErrors = false
        /// Sends deferred lanes before their reset: the limit was raised, or a deferral came from a cap since changed.
        var retryDeferred = false
        var dryRun = false
    }

    struct Job: Sendable { var item: EvalCase; var attempt: Int }

    enum Outcome: Sendable { case done(CallRecord), deferred(until: Date) }

    static let defaultRuns = "~/Library/Application Support/oops-eval/runs"

    let options: Options

    func run() async throws -> Manifest {
        guard !options.run.isEmpty, options.run != ".", options.run != "..", !options.run.contains("/"), !options.run.contains("\\") else {
            throw CorrectionError.message("--run must be a folder name, not a path.")
        }
        guard options.limit == nil || options.limit! > 0 else { throw CorrectionError.message("--limit must be positive.") }
        var cases = try Corpus.read(options.cases)
        if let limit = options.limit { cases = Array(cases.prefix(limit)) }
        let config = try LanesConfig.read(options.config)
        let prices = config.prices.flatMap { PriceTable.read(options.config.deletingLastPathComponent().appendingPathComponent($0)) }
        let attempts = options.attempts ?? config.attempts ?? 2
        guard attempts > 0, options.limit == nil || options.limit! > 0,
              !cases.isEmpty, Set(cases.map(\.id)).count == cases.count else {
            throw CorrectionError.message("Cases must be nonempty with unique ids; attempts and limit must be positive.")
        }
        let directory = options.runs.appendingPathComponent(options.run, isDirectory: true)
        let results = directory.appendingPathComponent("results", isDirectory: true)
        let experiment = try Experiment.make(cases: options.cases, selected: cases, config: options.config, attempts: attempts, limit: options.limit)
        try experiment.validate(in: directory)
        if !options.dryRun { try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true) }
        let lock = try options.dryRun ? nil : RunLock(directory)
        defer { withExtendedLifetime(lock) {} }
        try experiment.validate(in: directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let now = Date(), session = UUID().uuidString
        if FileManager.default.fileExists(atPath: manifestURL.path), Manifest.read(manifestURL) == nil {
            throw CorrectionError.message("The run manifest is unreadable. Restore it before resuming; it cannot be replaced silently.")
        }
        var manifest = Manifest.read(manifestURL) ?? Manifest(run: options.run, cases: options.cases.path,
                                                               datasets: [], prompt: CorrectionPolicy.promptVersion,
                                                               attempts: attempts, created: now, updated: now)
        manifest.datasets = Array(Set(cases.compactMap(\.version))).sorted()
        manifest.prompt = CorrectionPolicy.promptVersion; manifest.attempts = attempts; manifest.cases = options.cases.path

        let lanes = await Resolve.lanes(config, only: options.only)
        guard !lanes.isEmpty else { throw CorrectionError.message("No lanes match --only. Check provider names and model IDs in --config.") }
        for resolved in lanes where resolved.skipped == nil {
            if let old = manifest.lanes.first(where: { $0.provider == resolved.provider.name && $0.model == resolved.configured }),
               old.state != "skipped", old.resolved != resolved.model || resolved.provider.lane != .api && old.effort != resolved.effort {
                throw CorrectionError.message("\(resolved.configured) resolved to a different model or effort. Use a new --run.")
            }
        }
        // The contract names files `<lane>--<model>`: two providers serving one model ID can't share a run.
        if let clash = Dictionary(grouping: lanes, by: \.file).first(where: { $0.value.count > 1 }) {
            throw CorrectionError.message("\(clash.value.map(\.provider.name).joined(separator: " and ")) would both write \(clash.key); run them apart")
        }
        // Today's requests per provider, from every record in the run: lanes left out by --only and
        // errors about to be resent were sent all the same.
        var usedToday: [String: Int] = [:]
        let zones = Dictionary(config.providers.map { ($0.name, $0.pace.dailyReset) }, uniquingKeysWith: { first, _ in first })
        for url in (try? FileManager.default.contentsOfDirectory(at: results, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "jsonl" {
            for record in try ResultsFile.existing(url) {
                let zone = zones[record.provider] ?? nil
                guard let date = try? Date(record.started, strategy: .iso8601), Pacer.day(date, zone: zone) == Pacer.day(now, zone: zone) else { continue }
                usedToday[record.provider, default: 0] += 1 + record.retries
            }
        }
        var plans: [(ResolvedLane, [Job], Manifest.Lane)] = []
        for resolved in lanes {
            let url = results.appendingPathComponent(resolved.file)
            let existing = try ResultsFile.existing(url, dropping: { options.retryErrors && $0.verdict == "error" }, rewrite: !options.dryRun)
            let done = Set(existing.map { "\($0.case)#\($0.attempt)" })
            let jobs = (1...max(attempts, 1)).flatMap { attempt in cases.filter { !done.contains("\($0.id)#\(attempt)") }.map { Job(item: $0, attempt: attempt) } }
            var entry = manifest.lanes.first { $0.file == "results/" + resolved.file }
                ?? Manifest.Lane(lane: resolved.provider.lane.rawValue, provider: resolved.provider.name, model: resolved.configured,
                                 resolved: resolved.model, effort: resolved.effort, file: "results/" + resolved.file, state: "pending")
            entry.model = resolved.configured; entry.resolved = resolved.model; entry.effort = existing.last?.effort ?? resolved.effort; entry.records = existing.count
            // A resumed lane starts where it settled, rather than being refused again.
            if let last = existing.last, let api = resolved.lane as? APILane { await api.resume(from: last) }
            if let reason = resolved.skipped { entry.state = "skipped"; entry.notes = [reason] }
            else if let until = entry.deferredUntil, until > now, !options.retryDeferred { entry.state = "deferred" }
            else { entry.state = jobs.isEmpty ? "done" : "pending"; entry.deferredUntil = nil; entry.deferred = 0 }
            plans.append((resolved, entry.state == "pending" ? jobs : [], entry))
        }
        manifest.lanes = manifest.lanes.filter { old in !plans.contains { "results/" + $0.0.file == old.file } } + plans.map(\.2)
        for provider in config.providers where plans.contains(where: { $0.0.provider.name == provider.name }) {
            manifest.providers[provider.name] = Manifest.Provider(lane: provider.lane.rawValue, documented: provider.documented,
                                                                  pace: provider.pace, achieved: manifest.providers[provider.name]?.achieved)
        }
        let plan = plans.map { plan in
            let (resolved, jobs, entry) = plan
            let what = entry.state == "deferred" ? "deferred until \(entry.deferredUntil.map(CallRecord.timestamp) ?? "?")" : "\(jobs.count) to send"
            return "\(entry.state == "skipped" ? "–" : "·") \(entry.lane)/\(entry.provider) \(resolved.model): \(what)" + (entry.state == "skipped" ? entry.notes.first.map { " (\($0))" } ?? "" : "")
        }
        FileHandle.standardError.write(Data((plan.joined(separator: "\n") + "\n").utf8))
        if options.dryRun { return manifest }
        try experiment.save(in: directory, cases: cases, config: options.config)

        manifest.sessions.append(.init(id: session, started: now))
        manifest.updated = now
        let files = Set(plans.map { "results/" + $0.0.file }), providers = Set(plans.map(\.0.provider.name))
        try manifest.save(files: files, providers: providers, session: session, to: manifestURL)

        let progress = Progress(plans.map { ($0.0.file, $0.1.count) })
        let ticker = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); await progress.print() } }
        let groups = Dictionary(grouping: plans.filter { !$0.1.isEmpty }, by: { $0.0.provider.name })
        let finished = await withTaskGroup(of: (String, Manifest.Achieved, [(String, Manifest.Lane)]).self) { group in
            for (name, members) in groups {
                let monitor = directory.appendingPathComponent("progress/\(fileName(name)).json")
                let pacer = Pacer(members[0].0.provider.pace, usedToday: usedToday[name] ?? 0, monitor: monitor)
                group.addTask {
                    let lanes = await withTaskGroup(of: (String, Manifest.Lane).self) { inner in
                        for (resolved, jobs, entry) in members {
                            inner.addTask { (resolved.file, await self.drive(resolved, jobs: jobs, entry: entry, pacer: pacer, prices: prices,
                                                                             url: results.appendingPathComponent(resolved.file), progress: progress)) }
                        }
                        return await inner.reduce(into: []) { $0.append($1) }
                    }
                    return (name, await pacer.achieved, lanes)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        ticker.cancel()
        for (name, achieved, lanes) in finished {
            manifest.providers[name]?.achieved = achieved
            for (file, entry) in lanes { if let index = manifest.lanes.firstIndex(where: { $0.file == "results/" + file }) { manifest.lanes[index] = entry } }
        }
        manifest.updated = Date()
        manifest.sessions[manifest.sessions.count - 1].finished = manifest.updated
        manifest.sessions[manifest.sessions.count - 1].sent = finished.reduce(0) { $0 + $1.1.requests }
        try manifest.save(files: files, providers: providers, session: session, to: manifestURL)
        let failures = finished.flatMap { $0.2.compactMap(\.1.failure) }
        if !failures.isEmpty { throw CorrectionError.message(failures.joined(separator: "; ")) }
        return manifest
    }

    /// One model's jobs, `concurrency` at a time; the pacer holds the provider-wide limits.
    private func drive(_ resolved: ResolvedLane, jobs: [Job], entry: Manifest.Lane, pacer: Pacer, prices: PriceTable?,
                       url: URL, progress: Progress) async -> Manifest.Lane {
        guard let lane = resolved.lane else { return entry }
        let file = ResultsFile(url), queue = Queue(jobs), name = resolved.file
        let workers = max(resolved.provider.pace.concurrency ?? 1, 1)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    while let job = await queue.next() {
                        if await queue.deferredUntil != nil { await queue.skip(); await progress.step(name, deferred: true); continue }
                        switch await call(job, lane: lane, resolved: resolved, pacer: pacer, prices: prices) {
                        case .done(let record):
                            // A record that can't be written stops the lane: its call would be lost on resume.
                            do { try await file.append(record) } catch { await queue.stop("can't write \(name): \(error.localizedDescription)"); continue }
                            await queue.wrote(record)
                            await progress.step(name, deferred: false)
                        case .deferred(let until):
                            await queue.defer(until: until); await queue.skip(); await progress.step(name, deferred: true)
                        }
                    }
                }
            }
        }
        await file.close()
        var entry = entry
        let (written, skipped, until, surface, effort) = await queue.summary
        entry.records += written; entry.deferred = skipped; entry.deferredUntil = until
        if written > 0 { entry.effort = effort }
        entry.surface = surface ?? entry.surface; entry.streaming = entry.surface.map { $0.contains("stream") }
        entry.failure = await queue.failure
        entry.state = entry.failure != nil ? "failed" : until == nil ? "done" : "deferred"
        let notes = await lane.notes()
        entry.notes = Array(NSOrderedSet(array: entry.notes + notes)) as? [String] ?? entry.notes + notes
        return entry
    }

    /// One case and attempt, retried on a rate limit (up to four times, waiting what the provider asks
    /// or 5, 10, 20, 40 s) and on a transient failure (twice). A spent daily quota defers it.
    private func call(_ job: Job, lane: any Lane, resolved: ResolvedLane, pacer: Pacer, prices: PriceTable?) async -> Outcome {
        let input = job.item.input
        let estimate = (CorrectionPolicy.instructions.utf8.count + 2 * input.utf8.count) / 4 + 64
        var retries = 0, limited = 0, queued: Duration = .zero
        let began = ContinuousClock.now
        let reset = { Pacer.nextReset(after: Date(), zone: resolved.provider.pace.dailyReset) }
        while true {
            guard let waited = await pacer.enter(tokens: estimate) else { return .deferred(until: reset()) }
            queued += waited
            let started = Date()
            let answer = await lane.send(input)
            await pacer.leave()
            if let pause = answer.pause, pause > 0 { await pacer.pause(min(pause, 120), limited: false) }
            // A refused setting the lane stepped down from: resent through the pacer like any retry.
            if answer.resend, retries < 8 { retries += 1; continue }
            let backoff = 5 * pow(2, Double(retries))
            if let limit = answer.limit {
                limited += 1
                let wait = limit.wait ?? backoff
                if limit.daily || wait > 900 {
                    await pacer.pause(0, limited: true)
                    return .deferred(until: limit.daily ? max(reset(), Date().addingTimeInterval(limit.wait ?? 0)) : Date().addingTimeInterval(wait))
                }
                if retries < 4 { retries += 1; await pacer.pause(wait, limited: true); continue }
            } else if answer.transient, retries < 2 {
                retries += 1; await pacer.pause(backoff, limited: false); continue
            }
            var result = record(job, answer: answer, resolved: resolved, started: started, queued: queued, retries: retries, limited: limited, prices: prices)
            result.elapsedMs = Int((began.duration(to: .now) / .milliseconds(1)).rounded())
            return .done(result)
        }
    }

    private func record(_ job: Job, answer: Answer, resolved: ResolvedLane, started: Date, queued: Duration, retries: Int,
                        limited: Int, prices: PriceTable?) -> CallRecord {
        let item = job.item
        var verdict = answer.malformed ? "invalid" : "error", output: String?, restored: String?, failure = answer.error, dropped = 0
        if let raw = answer.raw {
            restored = try? CorrectionPolicy.restoredAnswer(raw, original: item.input)
            do {
                let correction = try CorrectionPolicy.reconcile(raw, original: item.input)
                let text = correction.text; dropped = correction.dropped.count
                output = text; verdict = Checks.verdict(text, for: item); failure = nil
            } catch { verdict = "invalid"; failure = error.localizedDescription }
        }
        var result = CallRecord(run: options.run, dataset: item.version, prompt: CorrectionPolicy.promptVersion, lane: resolved.provider.lane.rawValue,
                          provider: resolved.provider.name, model: resolved.model, modelReported: answer.modelReported, effort: answer.effort,
                          surface: answer.surface, case: item.id, attempt: job.attempt, started: CallRecord.timestamp(started),
                          queuedMs: Int((queued / .milliseconds(1)).rounded()), ttftMs: answer.ttft, ttfcMs: answer.ttfc,
                          totalMs: answer.total, harnessMs: answer.harness, status: answer.status, rateLimited: limited, retries: retries,
                          finish: answer.finish, requestId: answer.requestID, tokens: answer.tokens,
                          costUsd: answer.cost ?? prices?.cost(provider: resolved.provider.name, model: resolved.model, tokens: answer.tokens),
                          raw: answer.raw, output: output, verdict: verdict,
                          checks: Checks.make(item, answer: restored, output: output), error: failure)
        result.droppedEdits = dropped
        return result
    }
}
