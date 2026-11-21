import AppKit
import OopsCore
import SwiftUI

/// The one-time word about a feature that arrived with an update: a small glass card under the menu-bar eyes, on the
/// first launch after it. It takes no focus. Turn on opens a short run of first run's own steps for that feature;
/// Later puts it away for good, and General's Turn on row stays. One pattern for every feature to come.
@MainActor enum NewFeatures {
    static let key = "announcedFeatures"
    /// The features this build offers at first run.
    static var offered: [OnboardingFeature] { [.fix, .dictate] }
    static var announced: Set<OnboardingFeature> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(OnboardingFeature.init(rawValue:)))
    }
    private static var card: NewFeatureCard?

    /// First run offered them, or their card was shown: neither is said again.
    static func markAnnounced(_ features: some Sequence<OnboardingFeature>) {
        UserDefaults.standard.set(announced.union(features).map(\.rawValue).sorted(), forKey: key)
    }

    /// At launch, past first run: the card for a feature that is new to this person. `saves` is false in a run that
    /// keeps nothing, which shows `feature` whatever was announced.
    static func announce(under menuBar: MenuBar?, feature forced: OnboardingFeature? = nil, saves: Bool = true) {
        let on = Set(OnboardingFeature.allCases.filter { ShortcutSettings.shared.shortcut($0.action) != nil })
        guard card == nil, let feature = forced ?? FeatureAnnouncement.pending(offered: offered, on: on, announced: announced) else { return }
        // Shown is announced: quitting with the card up doesn't bring it back.
        if saves { markAnnounced([feature]) }
        menuBar?.greet()
        card = NewFeatureCard(feature: feature, under: menuBar?.eyesFrame) { turnOn in
            card = nil
            if turnOn { OnboardingWindow.shared.show(turningOn: feature) }
        }
    }
}

@MainActor final class NewFeatureCard {
    private static let size = CGSize(width: 300, height: 136)
    private let panel: NSPanel

    init(feature: OnboardingFeature, under eyes: CGRect?, done: @escaping (_ turnOn: Bool) -> Void) {
        let panel = CardPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.panel = panel
        panel.contentView = NSHostingView(rootView: NewFeatureCardView(feature: feature) { [weak panel] turnOn in
            panel?.orderOut(nil)
            done(turnOn)
        })
        // Under the eyes, its trailing edge near theirs; with the eyes hidden, the screen's top trailing corner.
        let screen = (eyes.flatMap { eyes in NSScreen.screens.first { $0.frame.intersects(eyes) } } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max((eyes?.midX ?? screen.maxX) - Self.size.width + 44, screen.minX + 8), screen.maxX - Self.size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: (eyes?.minY ?? screen.maxY) - Self.size.height - 2))
        panel.orderFrontRegardless()
    }
}

private final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Regular glass with the system's own ink, like the dictation drop: it sits over whatever the desktop holds.
struct NewFeatureCardView: View {
    let feature: OnboardingFeature
    let done: (_ turnOn: Bool) -> Void
    @State private var shown = false
    @State private var voice = FeaturePreviews()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                VoicePreview(model: voice.voice, dark: scheme == .dark, scale: 0.7).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New in Oops").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(feature.title).font(.system(size: 17, weight: .semibold))
                }
            }
            HStack(spacing: 8) {
                Button("Turn on") { done(true) }.buttonStyle(.glassProminent)
                Button("Later") { done(false) }.buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 268, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .scaleEffect(shown || reduceMotion ? 1 : 0.6, anchor: .topTrailing)
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8).padding(.trailing, 16)
        .task { if !reduceMotion { await voice.listen() } }
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.3).delay(0.3)) { shown = true } }
        // The panel never becomes key, and its buttons must not look switched off for it.
        .environment(\.controlActiveState, .key)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New in Oops: \(feature.title)")
    }
}
