import OopsCore
import SwiftUI

/// The Try it step over Hello's wallpaper: Hello's chat app again, now with the person's own reply
/// waiting in its composer, and their shortcut's keys beneath it. Pressing them corrects the reply in
/// place; the title then says what really happened, and one line beneath says how to undo it.
struct TryItStepView: View {
    let step: TryItStep
    let next: () -> Void

    var body: some View {
        OnboardingStepLayout(height: 430) { column } primary: {
            if step.isDone { OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity)) }
        } skip: {
            if !step.isDone, step.phase != .working { OnboardingSkipButton(action: next).transition(.opacity) }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: step.phase)
        .onAppear { step.start() }
        .onDisappear { step.stop() }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: failed ? 19 : 26, weight: .semibold)).monospacedDigit()
                .accessibilityAddTraits(.isHeader)
                .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 620, minHeight: 34)
                .contentTransition(.numericText())
                .foregroundStyle(.white)
            TryItChat(step: step).padding(.top, 24)
            keys.padding(.top, 26)
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: step.phase)
        .animation(.spring(duration: 0.35), value: step.recording)
    }

    private var failed: Bool {
        if step.recording { return step.shortcuts.error != nil }
        if case .failed = step.phase { return true } else { return false }
    }

    /// The shortcut as it is saved right now, so a Change here retitles it at once; a chord the
    /// recorder refuses says why here, where the Shortcut step says it under its keys.
    private var title: String {
        if step.recording { return step.shortcuts.error ?? "Press the new shortcut" }
        switch step.phase {
        case .ready, .working: return "Press \(step.shortcuts.shortcut?.label ?? "your shortcut")"
        case let .fixed(changes, seconds):
            let fixes = TestEditorModel.fixesLabel(changes)
            return seconds.map { "\(fixes) in \(TestEditorModel.seconds($0))" } ?? fixes
        case .restored: return "Original restored"
        case .clear: return "Already clear"
        case .failed(let message): return message
        }
    }

    /// After a fix, the one hint D10 asks for: the same shortcut takes it back, and then puts it back.
    private var hint: String? {
        let label = step.shortcuts.shortcut?.label ?? "your shortcut"
        switch step.phase {
        case .fixed: return "Press \(label) again to undo"
        case .restored: return "Press \(label) to fix it again"
        default: return nil
        }
    }

    /// The keys to press until it's done; Continue then takes over in the footer, and the hint sits
    /// where the keys were.
    @ViewBuilder private var keys: some View {
        if let hint {
            Text(hint).font(.system(size: 13, weight: .medium)).lineLimit(1).opacity(0.85).foregroundStyle(.white)
                .contentTransition(.opacity).transition(.opacity)
        } else if !step.isDone {
            let caps = step.shortcuts.keys
            let side = TryItKeys.side(caps)
            // One row at the keys' height; the hairline keeps Change shortcut from reading as a key to press.
            HStack(spacing: 12) {
                TryItKeys(caps: caps, spoken: step.recording ? "Recording" : step.shortcuts.spoken, pulsing: step.phase == .ready && !step.recording)
                Capsule().fill(.white.opacity(0.3)).frame(width: 1, height: side * 0.6).accessibilityHidden(true)
                ShortcutChangeKey(recording: step.recording, height: side, radius: 10, font: 13) {
                    if step.recording { step.cancelChange() } else { step.change() }
                }
                .disabled(step.phase == .working)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .transition(.opacity)
        }
    }
}

/// The shortcut's keys, small, breathing while they wait and lit and sunk the moment each goes down;
/// while recording, the modifiers held so far.
private struct TryItKeys: View {
    let caps: [ShortcutStep.Cap]
    let spoken: String
    let pulsing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    /// The keys' height: Hyper's legend takes two lines, and the other keys grow with it.
    static func side(_ caps: [ShortcutStep.Cap]) -> CGFloat { caps.contains { !$0.parts.isEmpty } ? 46 : 38 }

    var body: some View {
        // A held key stops the breathing: the keys answer the hand instead.
        let breathing = beat && pulsing && caps.allSatisfy { $0.lit == 0 && $0.parts.allSatisfy { $0.lit == 0 } }
        let side = Self.side(caps)
        HStack(spacing: 6) {
            if caps.isEmpty {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                    .frame(width: 38, height: 38)
            }
            ForEach(caps) { cap in
                let wide = cap.label.count > 1
                Group {
                    if cap.parts.isEmpty {
                        Text(cap.label).font(.system(size: wide ? 13 : 17, weight: .medium, design: .rounded))
                    } else {
                        // The Shortcut step's proportions (a smaller modifier row), and a point lower:
                        // the bright name outweighs the faint row, so the block's middle reads high.
                        HyperLegend(cap: cap, size: 13, partSize: 8).offset(y: 1)
                    }
                }
                .padding(.horizontal, wide ? 10 : 0).frame(minWidth: side, minHeight: side)
                .background {
                    Color.clear.glassEffect(.clear.tint(.white.opacity(max(0.4 * cap.lit, breathing ? 0.22 : 0.06))), in: .rect(cornerRadius: 10))
                }
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(max(0.25 + 0.6 * cap.lit, breathing ? 0.55 : 0.25)), lineWidth: 1) }
                .shadow(color: .white.opacity(0.35 * cap.lit), radius: 10)
                .scaleEffect(cap.down ? 0.92 : 1)
                .offset(y: cap.down ? 2 : 0)
                .animation(.spring(duration: 0.18, bounce: 0.35), value: cap.down)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .scaleEffect(breathing ? 1.04 : 1)
        .animation(.spring(duration: 0.25), value: caps.map(\.label))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { beat = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }
}

/// Hello's chat app (the first scene's close-up): Léa's thread, and the reply waiting in its composer.
private struct TryItChat: View {
    let step: TryItStep
    private let blue = Color(red: 0.04, green: 0.52, blue: 1)

    var body: some View {
        let conversation = step.conversation
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                TrafficLights().padding(.init(top: 13, leading: 8, bottom: 10, trailing: 0))
                thread("L", "Léa", conversation.snippet, selected: true)
                thread("S", "Sami", "sent you the slides")
                thread("M", "Mom", "call me when you can")
                Spacer()
            }
            .padding(.horizontal, 7).frame(width: 168).background(Color(white: 0.96))
            Divider()
            VStack(spacing: 0) {
                VStack(spacing: 2) { avatar("L", warm: true); Text(verbatim: "Léa").font(.system(size: 11.5)) }.padding(.vertical, 8)
                Divider()
                VStack(spacing: 5) {
                    Spacer()
                    Text(verbatim: "Today 18:02").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    ForEach(Array(conversation.messages.enumerated()), id: \.offset) { _, message in
                        bubble(message.text, sent: message.sent).frame(maxWidth: .infinity, alignment: message.sent ? .trailing : .leading)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                HStack(alignment: .bottom, spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).background(Circle().fill(.black.opacity(0.08)))
                    composer
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 17).strokeBorder(.black.opacity(0.2)))
                }
                .padding(.init(top: 4, leading: 12, bottom: 14, trailing: 12))
            }
        }
        .frame(width: 620, height: 330)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 26, y: 18)
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat with Léa")
    }

    /// Live, the real text view the pipeline corrects; replaying (and offscreen), the reply as text,
    /// its fixed words flashed as the drop flashes them in other apps.
    @ViewBuilder private var composer: some View {
        if step.isLive, DebugFlags.setupSnapshots == nil {
            TryItEditor(model: step.fixture).frame(height: 78)
        } else {
            Text(flashed).font(.system(size: 14)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .accessibilityLabel("Reply to Léa")
        }
    }

    private var flashed: AttributedString {
        let text = step.replayText as NSString
        var result = AttributedString(), cursor = 0
        for range in step.replayFlash.sorted(by: { $0.location < $1.location }) where range.location >= cursor && NSMaxRange(range) <= text.length {
            result += AttributedString(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var word = AttributedString(text.substring(with: range))
            word.backgroundColor = Color.accentColor.opacity(0.28)
            result += word
            cursor = NSMaxRange(range)
        }
        result += AttributedString(text.substring(from: cursor))
        return result
    }

    private func avatar(_ letter: String, warm: Bool = false) -> some View {
        Text(verbatim: letter).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 28, height: 28)
            .background(Circle().fill(LinearGradient(colors: warm ? [Color(red: 0.42, green: 0.72, blue: 0.96), Color(red: 0.2, green: 0.47, blue: 0.88)]
                                                     : [Color(white: 0.72), Color(white: 0.55)], startPoint: .top, endPoint: .bottom)))
    }

    private func thread(_ letter: String, _ name: String, _ snippet: String, selected: Bool = false) -> some View {
        HStack(spacing: 8) {
            avatar(letter, warm: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.system(size: 12, weight: .semibold))
                Text(verbatim: snippet).font(.system(size: 11)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? blue : .clear))
    }

    private func bubble(_ text: String, sent: Bool) -> some View {
        Text(verbatim: text).font(.system(size: 14)).foregroundStyle(sent ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 17).fill(sent ? blue : Color(white: 0.91)))
    }
}

/// Settings' Try editor (a real NSTextView), dressed as a chat composer: the pipeline captures and
/// replaces it through Accessibility exactly as it does another app's, and flashes the fixed words.
private struct TryItEditor: NSViewRepresentable {
    let model: TestEditorModel

    func makeCoordinator() -> DraftEditor.Coordinator { DraftEditor.Coordinator(model: model) }

    func makeNSView(context: Context) -> DraftEditorView {
        let view = DraftEditorView(initialText: model.keptDraft ?? "")
        view.appearance = NSAppearance(named: .aqua)
        let font = NSFont.systemFont(ofSize: 14)
        view.textView.textContainerInset = NSSize(width: 8, height: 8)
        view.textView.font = font
        view.textView.typingAttributes[.font] = font
        view.textView.textStorage?.addAttribute(.font, value: font, range: NSRange(location: 0, length: (view.text as NSString).length))
        view.textView.setAccessibilityLabel("Reply to Léa")
        view.textView.delegate = context.coordinator
        model.editor = view
        return view
    }

    func updateNSView(_ view: DraftEditorView, context: Context) {}
}
