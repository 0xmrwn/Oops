import SwiftUI

/// Both companion homes stay mounted. Only the visible, active one can own a blink, including taps.
@MainActor @Observable final class SettingsBlink {
    private(set) var lid: CGFloat = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private let pause: (Duration) async throws -> Void

    init(pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pause = pause
    }

    func setActive(_ active: Bool) {
        self.active = active
        guard !active else { return }
        task?.cancel(); task = nil; generation = nil
        withAnimation(nil) { lid = 0 }
    }

    func play(times: Int) async {
        guard active, task == nil, !Task.isCancelled else { return }
        let id = UUID()
        generation = id
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { self.task = nil; generation = nil } }
            do {
                for blink in 0..<times {
                    try Task.checkCancellation()
                    guard active, generation == id else { return }
                    withAnimation(.timingCurve(0.55, 0, 0.9, 0.5, duration: 0.07)) { lid = 1 }
                    try await pause(.milliseconds(100))
                    try Task.checkCancellation()
                    guard active, generation == id else { return }
                    withAnimation(.timingCurve(0.15, 0.6, 0.35, 1, duration: 0.18)) { lid = 0 }
                    if blink < times - 1 { try await pause(.milliseconds(260)) }
                }
            } catch {
                if generation == id { withAnimation(nil) { lid = 0 } }
            }
        }
        self.task = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
