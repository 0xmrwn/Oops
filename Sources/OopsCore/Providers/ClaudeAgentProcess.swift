import Foundation
import Synchronization

final class ClaudeAgentProcess: @unchecked Sendable {
    private let folder: URL
    private let marker = UUID().uuidString
    private let sampler = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let tail = Mutex(Data())
    private let drained = Mutex(false)
    private let remembered = Mutex<Set<ProcessTree.Member>>([])
    private static let running = Mutex<[String: ClaudeAgentProcess]>([:])

    init(executable: URL, arguments: [String], folder: URL, environment: [String: String]) throws {
        self.folder = folder
        process.executableURL = executable
        process.currentDirectoryURL = folder
        process.arguments = arguments
        let allowed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM"]
        var child = environment.filter { key, _ in
            allowed.contains(key) || key.hasPrefix("LC_") || key.hasPrefix("CLAUDE_") || key.hasPrefix("ANTHROPIC_")
        }
        child["OOPS_AGENT_RUN"] = marker
        process.environment = child
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        sampler.setEventHandler { [weak self] in self?.record() }
        sampler.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        sampler.activate()
        do {
            try Self.running.withLock { registry in
                try process.run()
                registry[marker] = self
            }
        } catch { throw ClaudeAgentError.notInstalled }
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { drained.withLock { $0 = true } }
            while let chunk = try? errors.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                tail.withLock {
                    $0.append(chunk)
                    $0 = Data($0.suffix(4096))
                }
            }
        }
    }

    func send(_ text: String) {
        let handle = input.fileHandleForWriting
        let on: Int32 = 1
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, on)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? handle.close() }
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    var lines: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var total = 0
                    // Count even an unterminated line against the output limit.
                    var line = Data()
                    for try await byte in output.fileHandleForReading.bytes {
                        total += 1
                        guard total <= 8_000_000 else { throw ClaudeAgentError.stopped }
                        if byte == 10 {
                            continuation.yield(line)
                            line = Data()
                        } else { line.append(byte) }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var errorTail: String { tail.withLock { String(decoding: $0, as: UTF8.self) } }

    func exitError() async throws -> ClaudeAgentError {
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        guard process.terminationStatus != 0 else { return .stopped }
        while !drained.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        return errorTail.localizedCaseInsensitiveContains("sandbox") ? .sandboxUnavailable : .stopped
    }

    private func record() {
        guard process.isRunning else { return }
        let descendants = ProcessTree.descendants(of: process.processIdentifier)
        remembered.withLock { $0.formUnion(descendants) }
    }

    private var runMembers: Set<ProcessTree.Member> {
        ProcessTree.runMembers(marker: marker, group: process.processIdentifier, folder: folder.path)
    }

    private func recordRunMembers() {
        let members = runMembers
        remembered.withLock { $0.formUnion(members) }
    }

    private func terminate() {
        record()
        recordRunMembers()
        if process.isRunning { process.terminate() }
        for member in remembered.withLock({ $0 }) where ProcessTree.isAlive(member) { kill(member.pid, SIGTERM) }
    }

    private var hasSurvivors: Bool {
        process.isRunning || remembered.withLock { $0 }.contains(where: ProcessTree.isAlive)
    }

    private func killRemaining() {
        sampler.cancel()
        record()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // A command may have forked while handling SIGTERM or while its parent was being killed.
        repeat {
            recordRunMembers()
            let members = remembered.withLock { $0 }
            for member in members where member.pid == member.group && member.group > 1 && member.group != getpgrp() {
                if ProcessTree.isAlive(member), getpgid(member.pid) == member.group { killpg(member.group, SIGKILL) }
            }
            for member in members where ProcessTree.isAlive(member) { kill(member.pid, SIGKILL) }
            if hasSurvivors { usleep(10000) }
            else if runMembers.isEmpty { break }
        } while true
        _ = Self.running.withLock { $0.removeValue(forKey: marker) }
    }

    func end(grace: Duration) async {
        terminate()
        // Cleanup still gets its grace period when the consumer has cancelled.
        await Task.detached { [self] in
            let deadline = ContinuousClock.now + grace
            while hasSurvivors, ContinuousClock.now < deadline {
                try? await Task.sleep(until: min(deadline, .now + .milliseconds(50)), clock: .continuous)
            }
            killRemaining()
        }.value
    }

    static func endAll() {
        let processes = running.withLock { Array($0.values) }
        guard !processes.isEmpty else { return }
        for process in processes { process.terminate() }
        usleep(200_000)
        for process in processes { process.killRemaining() }
    }
}
