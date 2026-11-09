import AppKit
import SwiftUI
import OopsCore

/// Settings → General → Try: sample drafts, the draft and its status, then Restore and Fix.
struct TryView: View {
    @ObservedObject var model: TestEditorModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            samples
            editorPane
            actions
        }
        // The draft takes focus on arrival, so the shortcut works without a click.
        .onAppear { DispatchQueue.main.async { model.editor?.focus() } }
    }

    private var samples: some View {
        HStack(spacing: 8) {
            ForEach(SampleDraft.allCases) { sample in
                let active = model.activeSample == sample
                Button { model.load(sample) } label: {
                    Label(sample.rawValue, systemImage: sample.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                // Monochrome like Settings' switches: the chosen sample is the brighter one.
                .foregroundStyle(.primary.opacity(active ? 1 : 0.7))
                .glassEffect(active ? .regular.tint(.primary.opacity(0.14)).interactive() : .regular.interactive(),
                             in: .capsule)
                .glassEdge(Capsule(), outside: true)
                .disabled(model.busy)
                .help("Replace the draft with a \(sample.rawValue.lowercased()) sample")
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample drafts")
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
            DraftEditor(model: model)
                .frame(height: 290)
            StatusStrip(model: model)
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .padding(.top, 4)
        }
        .background {
            // A faint writing surface under the clear glass; opaque with Reduce Transparency.
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .textBackgroundColor).opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.16 : 0.42)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                // The draft takes focus on arrival; its edge marks it only as other focus rings do.
                .strokeBorder(model.editorFocused && FocusRings.shared.shown ? Color.primary.opacity(0.35)
                              : (reduceTransparency ? Color(nsColor: .separatorColor) : .clear),
                              lineWidth: 1)
                .animation(.easeOut(duration: 0.18), value: model.editorFocused && FocusRings.shared.shown)
        }
        .modifier(PaneGlass(enabled: !reduceTransparency))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            // No keys of its own: pressing Fix text again restores too (D10).
            Button(action: model.onRestore) { Label("Restore original", systemImage: "arrow.uturn.backward") }
            .buttonStyle(.settingsGlass).controlSize(.large)
            .disabled(!model.canRestore || model.busy)
            .help("Restore the draft from before the last correction")

            // Both stay alive and trade places: swapping two glass buttons in and out on every
            // status change rebuilt their glass and cost a frame each time.
            // Each in its own container: a shared one (Settings' page) draws its children's glass
            // itself and ignores their opacity, so the idle button would still show.
            ZStack {
                GlassEffectContainer { Button(action: model.onCorrect) {
                    HStack(spacing: 10) {
                        Label("Stop", systemImage: "stop.circle")
                        HyperKeycaps(action: .correct)
                    }
                }
                .buttonStyle(.settingsGlass).controlSize(.large)
                .disabled(!model.canCancel)
                .help("Stop this correction")
                .accessibilityHint(ShortcutSettings.shared.shortcut(.correct)?.spoken ?? "")
                }
                .modifier(Standby(active: model.isWorking))
                GlassEffectContainer { Button(action: model.onCorrect) {
                    HStack(spacing: 10) {
                        Label("Fix", systemImage: ShortcutSettings.Action.correct.symbol)
                        HyperKeycaps(action: .correct, prominent: true)
                    }
                }
                .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
                .disabled(model.busy)
                .help("Fix the draft, or only the selected text")
                .accessibilityHint(ShortcutSettings.shared.shortcut(.correct)?.spoken ?? "")
                }
                .modifier(Standby(active: !model.isWorking))
            }
        }
    }
}

/// A control kept alive but out of play: invisible (not fully transparent, so its layers stay
/// built), unclickable, unfocusable and hidden from VoiceOver.
private struct Standby: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0.001)
            .allowsHitTesting(active)
            .focusable(active)
            .accessibilityHidden(!active)
    }
}

private struct PaneGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.glassEffect(.clear, in: .rect(cornerRadius: 18)).glassEdge(RoundedRectangle(cornerRadius: 18), outside: true) } else { content }
    }
}

/// Quiet, factual feedback under the draft: real counts and measured time only.
private struct StatusStrip: View {
    @ObservedObject var model: TestEditorModel

    var body: some View {
        HStack(spacing: 10) {
            OopsEyes(working: model.isWorking, look: face.look, lid: face.lid, check: face.check,
                     ink: Color.primary.opacity(model.isWorking ? 0.9 : 0.72))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            message
                .font(.system(size: 12))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: model.status)
            Spacer(minLength: 8)
            if case let .failed(_, remedy?) = model.status {
                Button(remedy.title) { model.openRemedy(remedy) }
                    .buttonStyle(.settingsGlass).controlSize(.small)
            }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    private var face: (look: CGSize, lid: Double, check: Double) {
        switch model.status {
        case .corrected, .alreadyClear: (DashEyes.restingLook, DashEyes.restingLid, 1)
        case .failed: (DashEyes.failedPose.look, DashEyes.failedPose.lid, 0)
        case .restored: (DashEyes.revertedPose.look, DashEyes.revertedPose.lid, 0)
        default: (DashEyes.restingLook, DashEyes.restingLid, 0)
        }
    }

    /// One text whose content cross-fades, rather than a different view per state.
    private var message: some View {
        let (text, emphasis): (String, Double) = switch model.status {
        case .ready: ("Select text to fix just that part.", 0.65)
        case .working: ("Fixing…", 0.78)
        case let .corrected(changes, seconds):
            (TestEditorModel.fixesLabel(changes) + (seconds.map { " · " + TestEditorModel.seconds($0) } ?? ""), 0.85)
        case let .alreadyClear(seconds): ("Already clear · \(TestEditorModel.seconds(seconds))", 0.85)
        case .restored: ("Original restored", 0.85)
        case let .failed(message, _): (message, 0.9)
        }
        return Text(text).foregroundStyle(.primary.opacity(emphasis)).monospacedDigit().textSelection(.enabled)
    }
}

/// Small Raycast-style keycaps for an action's shortcut inside an action button.
struct HyperKeycaps: View {
    let action: ShortcutSettings.Action
    var prominent = false
    private var shortcut: Shortcut? { ShortcutSettings.shared.shortcut(action) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shortcut?.keys ?? [], id: \.self) { key in
                // Too small for Hyper's modifiers beneath it: its mark and name only.
                Text(key)
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(minWidth: 16, minHeight: 18).padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background(prominent ? Color.white.opacity(0.2) : Color.primary.opacity(0.08),
                                in: .rect(cornerRadius: 4.5))
            }
        }
        .opacity(0.9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut?.spoken ?? "")
    }
}

/// Hyper's key in Settings, as onboarding draws it but without the light: its mark and name over the
/// four modifiers it stands for.
struct HyperKeyLegend: View {
    let size: CGFloat
    let partSize: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Text(Shortcut.hyperKey).font(.system(size: size, weight: .medium))
            Text(Shortcut(keyCode: 0, modifiers: Shortcut.hyper).glyphs.dropLast().joined())
                .font(.system(size: partSize, weight: .semibold)).tracking(partSize * 0.35).secondaryText()
        }
        .fixedSize()
    }
}

/// The correction drop's eyes, including its quiet reading motion.
struct OopsEyes: View {
    var working: Bool
    var look = DashEyes.restingLook
    var lid = DashEyes.restingLid
    var check = 0.0
    var ink: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.appearsActive) private var active
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: !working || reduceMotion || !enabled || !active)) { context in
            let t = context.date.timeIntervalSince(start)
            let pose = working ? (reduceMotion ? (look: CGSize.zero, lid: 0.4) : DashEyes.readingPose(t, toward: .zero))
                : (look: look, lid: lid)
            DashEyes(look: pose.look, lid: pose.lid, check: check, ink: ink, halo: .clear)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.2), value: check)
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: working)
        }
        .onChange(of: working) { _, now in if now { start = Date() } }
    }
}
