import AppKit
import SwiftUI

/// Runs Hello: the drop wakes alone and becomes a chat window, a draft
/// is typed and fixed, the camera pulls back to a desktop of waiting drafts, a wave of drops fixes
/// them, and one large drop remains above Set up. Every correction replays a real pipeline answer.
@MainActor @Observable final class HelloDirector {
    enum Stage { case entrance, desktop, finale }
    let typed = HelloWindowState(HelloDraft.typed)
    let waiting = HelloDraft.waiting.map { HelloWindowState($0) }
    var all: [HelloWindowState] { [typed] + waiting }
    var stage = Stage.entrance
    private(set) var desktopDismissed = false
    /// Close on the first window, which the pull-back leaves for the whole desktop.
    var zoomed = true
    /// The entrance: a lone drop that wakes, looks at the viewer, then stretches into the first window.
    var seedShown = false
    var seedLook = CGSize(width: 0, height: 0.2)
    var seedLid = 1.0
    var seedMorphed = false
    var windowShown = false
    /// The finale's drop: its eyes follow the pointer.
    var finaleLook = DashEyes.restingLook
    var finaleLid = DashEyes.restingLid
    private(set) var finaleReady = false
    @ObservationIgnored private var finaleFadeID = 0
    private var task: Task<Void, Never>?
    @ObservationIgnored private var sounds: HelloSounds?
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || DebugFlags.brandReduceMotion }

    func play() {
        task?.cancel()
        prepareSounds()
        task = Task { [weak self] in
            do { try await self?.run() } catch {}
        }
    }

    func stop() { task?.cancel(); sounds?.stop() }

    @discardableResult private func prepareSounds() -> HelloSounds? {
        guard Sounds.enabled else { return nil }
        if sounds == nil { sounds = HelloSounds() }
        return sounds
    }

    /// Escape: straight to Set up.
    func skip() {
        guard stage != .finale else { return }
        task?.cancel()
        sounds?.finish()
        ([typed] + waiting).forEach { $0.drop.presented = false; $0.corrected = true; $0.typed = nil; $0.shown = true }
        seedShown = false; windowShown = true; zoomed = false
        showFinale(fade: 0.5)
        finaleReady = true
    }

    /// The finale's eyes look toward `point`, a vector from the drop's centre in points.
    func look(at point: CGSize?) {
        guard stage == .finale else { return }
        guard let point else { finaleLook = CGSize(width: -0.9, height: 0.35); finaleLid = 0.55; return }
        let distance = max(1, hypot(point.width, point.height)), reach = min(1, distance / 220)
        finaleLook = CGSize(width: point.width / distance * reach, height: point.height / distance * reach)
        finaleLid = 0
    }

    private func run() async throws {
        reset()
        try await entrance()
        try await typeDraft()
        try await pause(0.28)
        try await correct(typed)
        try await pause(0.8)
        try await pullBack()
        try await wave()
        try await pause(1.7)
        waiting.forEach { $0.drop.presented = false }
        showFinale(fade: 0.8)
        try await pause(0.45)
        Sounds.play(.start, after: 0.075)
        try await pause(0.9)
        // The wave's tail has played. The finale's cue uses the app's separate engine.
        sounds?.finish()
        finaleLid = 0; finaleLook = .zero
        finaleReady = true
    }

    private func showFinale(fade: Double) {
        // The desktop and its drop anchors are only needed through the outgoing animation.
        finaleFadeID &+= 1
        let id = finaleFadeID
        withAnimation(.easeInOut(duration: fade), completionCriteria: .removed) {
            stage = .finale
        } completion: { [weak self] in
            guard let self, stage == .finale, finaleFadeID == id else { return }
            desktopDismissed = true
        }
    }

    private func reset() {
        finaleReady = false
        desktopDismissed = false
        stage = .entrance; zoomed = true; seedShown = false; seedMorphed = false; windowShown = false
        seedLook = CGSize(width: 0, height: 0.2); seedLid = 1
        finaleLook = CGSize(width: -0.9, height: 0.35); finaleLid = 0.55
        typed.typed = 0; typed.corrected = false; typed.shown = true
        for state in waiting { state.typed = nil; state.corrected = false; state.shown = false }
        ([typed] + waiting).forEach { $0.drop.presented = false; $0.flash = 0 }
    }

    /// The drop pops in alone, eyes shut; opens them, looks at the viewer, glances at where the draft
    /// will be, and stretches into the window.
    private func entrance() async throws {
        try await pause(0.4)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3)) { seedShown = true }
        Sounds.play(.start, after: 0.075)
        try await pause(0.55)
        withAnimation(.spring(duration: 0.35, bounce: 0)) { seedLid = 0.1 }
        try await pause(0.45)
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) { seedLook = .zero; seedLid = 0 }
        try await pause(0.75)
        withAnimation(.spring(duration: 0.45, bounce: 0.1)) { seedLook = CGSize(width: -0.7, height: 0.55); seedLid = 0.35 }
        try await pause(0.4)
        // The glass stretches into the window's outline, and the window resolves inside it while it's
        // still moving: one gesture, not a stretch followed by a fade.
        withAnimation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.16)) { seedMorphed = true; seedLid = 0 }
        try await pause(0.3)
        withAnimation(.easeInOut(duration: 0.7)) { windowShown = true }
        try await pause(0.75)
    }

    /// Human typing: uneven gaps, longer at spaces, a key sound per keystroke.
    private func typeDraft() async throws {
        typed.typed = 0
        let caret = Task { [typed] in
            while !Task.isCancelled { typed.caret.toggle(); try? await Task.sleep(for: .seconds(0.53)) }
        }
        defer { caret.cancel(); typed.caret = false }
        for character in typed.draft.before {
            typed.typed = (typed.typed ?? 0) + 1
            if reduceMotion { continue }
            prepareSounds()?.play(character == " " ? .space : .key, gain: Float.random(in: 0.8...1.2))
            try await pause(character == " " ? Double.random(in: 0.07...0.16) : Double.random(in: 0.048...0.094))
        }
        typed.typed = nil
    }

    private func pullBack() async throws {
        // The drop leaves first: it is drawn at the camera's zoom, which the pull-back changes.
        typed.drop.presented = false
        try await pause(0.4)
        withAnimation(reduceMotion ? nil : .timingCurve(0.65, 0, 0.2, 1, duration: 1.25)) { zoomed = false }
        prepareSounds()?.play(.swell)
        withAnimation(.easeInOut(duration: 0.3)) { stage = .desktop }
        for state in waiting {
            try await pause(reduceMotion ? 0 : 0.08)
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.8, bounce: 0.15)) { state.shown = true }
        }
        try await pause(0.8)
    }

    /// Drops pop in clockwise, read together, and fix in turn; each note a step higher.
    private func wave() async throws {
        for (step, state) in waiting.enumerated() {
            invoke(state)
            prepareSounds()?.play(.waveStart(step), gain: 0.85)
            try await pause(0.13)
        }
        try await pause(0.1)
        waiting.forEach { $0.drop.phase = .working }
        try await pause(1.0)
        for (step, state) in waiting.enumerated() {
            fix(state)
            prepareSounds()?.play(.waveSuccess(step), gain: 0.6)
            try await pause(0.14)
        }
    }

    /// One correction as the app shows it: the drop appears, reads, and the words change and flash.
    private func correct(_ state: HelloWindowState) async throws {
        invoke(state)
        Sounds.play(.start, after: 0.075)
        try await pause(0.2)
        state.drop.phase = .working
        try await pause(0.95)
        fix(state)
        Sounds.play(.success, after: 0.13)
    }

    private func invoke(_ state: HelloWindowState) {
        state.drop.label = ""; state.drop.phase = .invoked
        state.drop.presented = true
    }

    private func fix(_ state: HelloWindowState) {
        withAnimation(.easeInOut(duration: 0.12)) { state.corrected = true }
        withAnimation(.easeOut(duration: 0.12)) { state.flash = 1 }
        withAnimation(.easeIn(duration: ResultTiming.flash * 0.6).delay(ResultTiming.flash * 0.4)) { state.flash = 0 }
        state.drop.label = state.draft.label
        state.drop.phase = .fixed
    }

    /// The visible finale owns this task, so setup and Reduce Motion leave no sleeping loop behind.
    func blink() async throws {
        while true {
            try await Task.sleep(for: .seconds(4.2))
            let open = finaleLid
            withAnimation(.easeIn(duration: 0.07)) { finaleLid = 1 }
            do { try await Task.sleep(for: .seconds(0.12)) }
            catch { finaleLid = open; throw error }
            withAnimation(.easeOut(duration: 0.1)) { finaleLid = open }
        }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(reduceMotion ? min(seconds, 0.3) : seconds))
    }
}
