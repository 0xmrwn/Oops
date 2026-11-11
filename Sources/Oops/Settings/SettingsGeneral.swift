import AppKit
import OopsCore
import ServiceManagement
import SwiftUI

/// The landing page: a waiting update, every feature at a glance, the permission while it's missing,
/// app-wide settings, then About.
struct GeneralPage: View {
    let hasAccessibility: Bool
    let tabs: [SettingsTab]
    let store: ProviderStore
    let preferences: Preferences
    @Binding var detail: GeneralDetail?
    /// An overview row's jump to its tab.
    let open: (SettingsTab) -> Void
    let preview: () -> Void
    let previewPlacement: @MainActor () async -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The drop's start, success and failure cues (Sounds).
    @AppStorage("SoundsEnabled") private var sounds = true
    /// How long a finished correction's drop and flash stay (ResultTiming).
    @AppStorage(ResultTiming.key) private var resultSeconds = ResultTiming.fallback
    /// Onboarding's drag helper, brought back to Settings once Accessibility is allowed.
    @State private var accessibility = AccessibilityStep(home: SettingsWindow.identifier)

    var body: some View {
        ZStack(alignment: .top) {
            switch detail {
            case .stats:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Stats", parent: "General", back: { detail = nil }) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 18, weight: .medium))
                    }
                    StatsPage(stats: Stats.shared)
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .changelog:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Changelog", parent: "General", back: { detail = nil }) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 18, weight: .medium))
                    }
                    ChangelogPage()
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .debug:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Debug tools", parent: "General", back: { detail = nil }) {
                        Image(systemName: "ladybug").font(.system(size: 18, weight: .medium))
                    }
                    DebugToolsPage(preferences: preferences, preview: preview, previewPlacement: previewPlacement)
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case nil:
                general.transition(PaneSlideTransition(edge: -1, reduceMotion: reduceMotion))
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: detail)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A waiting update comes first: the header's pill leads here. Its notes are the Changelog's top entry.
            if let release = Updates.shared.pending {
                UpdateCard(release: release, state: Updates.shared.state) { detail = .changelog }
                    // Slides down from above the page on the same spring that moves the page below, so its bottom
                    // edge keeps pace with the next card's top: a card that faded in where it lands would cover
                    // that card until it had moved.
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
            FeatureOverview(tabs: tabs, store: store, open: open)
            // Only while missing: nothing works without it.
            if !hasAccessibility { accessibilityCard }
            VStack(spacing: 0) {
                OpenAtLoginRow().padding(.vertical, 12).disabled(DebugFlags.brandReview)
                Divider()
                HStack(spacing: 14) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 18, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    Text("Play audio cues").fontWeight(.semibold)
                    Spacer()
                    Toggle("Play audio cues", isOn: $sounds).settingsSwitch().labelsHidden()
                        .onChange(of: sounds) { _, on in if on { Sounds.preview() } }
                }
                .padding(.vertical, 12)
                Divider()
                HStack(spacing: 14) {
                    Image(systemName: "timer").font(.system(size: 18, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    Text("Show results for").fontWeight(.semibold)
                    Spacer()
                    Picker("Show results for", selection: $resultSeconds) {
                        ForEach(ResultTiming.choices, id: \.self) { Text($0.formatted() + " s").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                .padding(.vertical, 12)
            }
            .padding(.vertical, -6)
            .settingsSurface()
            AboutSection(detail: $detail)
            // The maker's note closes the page.
            Credit().frame(maxWidth: .infinity)
        }
        // A found update eases in, and the page below makes room for it.
        .animation(SettingsMotion.swap(reduceMotion), value: Updates.shared.pending)
    }

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(AccessibilityPermission.paneName, systemImage: AccessibilityPermission.paneSymbol).font(.headline)
                Spacer()
                StatusBadge("Required", ok: false)
            }
            do {
                Text("Allow Oops to read and replace the draft you’re editing. Corrections won’t work until this permission is enabled.")
                    .secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                // The action on the trailing edge, as in a macOS dialog.
                HStack {
                    Spacer()
                    // As in onboarding: a copy with an earlier grant under another signature can need a relaunch.
                    if accessibility.needsRelaunch {
                        Button(action: Relaunch.now) { Label("Relaunch Oops", systemImage: "arrow.clockwise") }
                            .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
                            .help("macOS sometimes needs Oops to restart before it sees the permission")
                    } else {
                        Button(action: accessibility.openSettings) { Label("Open System Settings", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
                    }
                }
            }
        }
        .settingsSurface()
        .onAppear { accessibility.start() }
        .onDisappear { accessibility.stop() }
    }
}

/// General's pages one level down.
enum GeneralDetail: Hashable {
    case stats, changelog, debug
    static var launchPreview: Self? {
        switch DebugFlags.settingsTab {
        case "stats": .stats
        case "changelog": .changelog
        case "debug", "developer", "diagnostics": .debug
        default: nil
        }
    }
}

/// Opens Oops when you log in, through the system's login items. If macOS wants the user to
/// approve it, the row says so and opens Login Items.
private struct OpenAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "power").font(.system(size: 17, weight: .medium)).frame(width: 24)
                    .secondaryText().accessibilityHidden(true)
                Text("Open at login").fontWeight(.semibold)
                Spacer()
                if status == .requiresApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.settingsGlass)
                }
                Toggle("Open at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: set))
                    .settingsSwitch().labelsHidden()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = "macOS didn’t change the login item. \(error.localizedDescription)" }
        status = SMAppService.mainApp.status
    }
}
