import AppKit
import Carbon
import OopsCore
import ServiceManagement
import SwiftUI

struct GeneralPage: View {
    let hasAccessibility: Bool
    let store: ProviderStore
    let testEditor: TestEditorModel
    @Binding var detail: GeneralDetail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The drop's start, success and failure cues (Sounds).
    @AppStorage("SoundsEnabled") private var sounds = true
    /// How long a finished correction's drop and flash stay (ResultTiming).
    @AppStorage(ResultTiming.key) private var resultSeconds = ResultTiming.fallback
    @State private var shortcutError: String?

    var body: some View {
        ZStack(alignment: .top) {
            switch detail {
            case .tryPage:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Try", parent: "General", back: { detail = nil }) {
                        Image(systemName: "text.cursor").font(.system(size: 18, weight: .medium))
                    }
                    TryView(model: testEditor)
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .customize:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Customize", parent: "General", back: { detail = nil }) {
                        Image(systemName: "wand.and.stars").font(.system(size: 18, weight: .medium))
                    }
                    CustomizePage()
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .apps:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Apps", parent: "General", back: { detail = nil }) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .medium))
                    }
                    AppsList()
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case nil:
                general.transition(PaneSlideTransition(edge: -1, reduceMotion: reduceMotion))
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: detail)
        .animation(.easeOut(duration: 0.15), value: ShortcutSettings.shared.custom)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Only while missing: nothing works without it. Once granted, About shows it.
            if !hasAccessibility { accessibilityCard }
            ModelCard(store: store, tryIt: { detail = .tryPage }, customize: { detail = .customize })
            // No heading: each row's icon, action and keys already say what the card is.
            VStack(alignment: .leading, spacing: 14) {
                shortcut("Fix text", action: .correct)
                if let shortcutError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsSurface()
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
                Divider()
                Button { detail = .apps } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 17, weight: .medium)).frame(width: 24)
                            .secondaryText().accessibilityHidden(true)
                        Text("Apps").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, -6)
            .settingsSurface()
        }
    }

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Accessibility", systemImage: "accessibility").font(.headline)
                Spacer()
                StatusBadge("Required", ok: false)
            }
            do {
                Text("Allow Oops to read and replace the draft you’re editing. Corrections won’t work until this permission is enabled.")
                    .secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                Text("In System Settings → Privacy & Security → Accessibility, enable Oops, then return here.")
                    .font(.callout).secondaryText()
                Button(action: openAccessibility) {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
            }
        }.settingsSurface()
    }

    private func shortcut(_ title: String, action: ShortcutSettings.Action) -> some View {
        HStack(spacing: 14) {
            Image(systemName: action.symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
                .secondaryText()
                .accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 4)
            // Left of the keys, so the keys' right edge never moves; only a changed shortcut has it. Without
            // a default (a layout with no W), going back to it clears the shortcut.
            if ShortcutSettings.shared.custom[action] != nil {
                let fallback = ShortcutSettings.shared.defaultShortcut(action)
                Button {
                    do { try ShortcutSettings.shared.set(action, nil); shortcutError = nil } catch { shortcutError = error.localizedDescription }
                } label: {
                    Image(systemName: fallback == nil ? "xmark" : "arrow.counterclockwise").font(.system(size: 13, weight: .semibold)).secondaryText()
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(fallback.map { "Back to " + $0.label } ?? "Remove shortcut")
                .accessibilityLabel(fallback == nil ? "Remove \(title) shortcut" : "Reset \(title) shortcut")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            ShortcutRecorder(title: title, action: action, error: $shortcutError)
        }
    }

    private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// General's pages one level down.
enum GeneralDetail: Hashable {
    case tryPage, customize, apps
    static var launchPreview: Self? {
        switch DebugFlags.settingsTab {
        case "try": .tryPage
        case "customize", "advanced": .customize
        case "apps": .apps
        default: nil
        }
    }
}

/// General → Apps: every app Oops has corrected in, most recent first, each with its switch.
private struct AppsList: View {
    private let scope = AppScope.shared

    var body: some View {
        if scope.apps.isEmpty {
            Text("Apps you correct in appear here.").secondaryText().frame(maxWidth: .infinity, alignment: .leading).settingsSurface()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(scope.apps.enumerated()), id: \.element) { index, app in
                    if index > 0 { Divider() }
                    HStack(spacing: 14) {
                        Image(nsImage: AppScope.icon(app)).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                        Text(AppScope.name(app)).fontWeight(.semibold)
                        Spacer()
                        Toggle(AppScope.name(app), isOn: Binding(get: { scope.isOn(app) }, set: { scope.set(app, on: $0) }))
                            .settingsSwitch().labelsHidden()
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.vertical, -6)
            .settingsSurface()
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

/// A shortcut in a field: click it, press the new keys (they show as they are held), and it is
/// saved once the system accepts it. Escape, a second click or leaving the page cancels.
private struct ShortcutRecorder: View {
    let title: String
    let action: ShortcutSettings.Action
    @Binding var error: String?
    @State private var recording = false
    /// Modifiers held so far while recording.
    @State private var held: UInt32 = 0
    @State private var monitor: Any?
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var current: Shortcut? { ShortcutSettings.shared.shortcut(action) }
    /// The field's resting outline: a step stronger in light, where a white backdrop thins it.
    private var restingEdge: Double { contrast == .increased ? 0.4 : colorScheme == .dark ? 0.14 : 0.22 }

    var body: some View {
        Button { recording ? stop() : start() } label: {
            HStack(spacing: 4) {
                if recording {
                    // All four held become the one Hyper key the saved shortcut shows.
                    let live = Shortcut(keyCode: 0, modifiers: held).keys.dropLast()
                    if live.isEmpty {
                        Text("Type shortcut").font(.system(size: 13, weight: .medium)).secondaryText()
                            .frame(height: 32).padding(.horizontal, 10)
                    } else {
                        ForEach(Array(live), id: \.self) { keycap($0) }
                    }
                } else if let current {
                    ForEach(current.keys, id: \.self) { keycap($0) }
                } else {
                    Text("Record shortcut").font(.system(size: 13, weight: .medium)).secondaryText()
                        .frame(height: 32).padding(.horizontal, 10)
                }
            }
            .padding(4)
            .frame(minWidth: 120, alignment: .trailing)
            .background(Color.primary.opacity(recording ? 0.12 : hovering ? 0.08 : 0.04),
                        in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(recording ? 0.75 : hovering ? max(0.28, restingEdge) : restingEdge), lineWidth: recording ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.12), value: held)
        .animation(.easeOut(duration: 0.15), value: recording)
        .help(recording ? "Press the new shortcut · Escape cancels" : current == nil ? "Click to set" : "Click to change")
        .accessibilityLabel(title)
        .accessibilityValue(recording ? "Recording" : current?.spoken ?? "Not set")
        .onReceive(NotificationCenter.default.publisher(for: .settingsPageWillChange)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onDisappear { stop() }
    }

    private func keycap(_ key: String) -> some View {
        Group {
            if key == Shortcut.hyperKey { HyperKeyLegend(size: 12.5, partSize: 8.5) } else { Text(key).font(.system(size: 15, weight: .medium)) }
        }
        .frame(minWidth: 29, minHeight: 32).padding(.horizontal, key.count > 1 ? 6 : 0)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func start() {
        error = nil; held = 0
        recording = true
        ShortcutSettings.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let modifiers = Shortcut.modifiers(event.modifierFlags)
            if event.type == .flagsChanged { held = modifiers; return nil }
            if event.keyCode == 53, modifiers == 0 { stop(); return nil }
            // A shortcut needs ⌃, ⌥ or ⌘; Shift alone would take a letter from every text field.
            guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
                if Sounds.enabled { NSSound.beep() }
                return nil
            }
            do { try ShortcutSettings.shared.set(action, Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)) }
            catch { self.error = error.localizedDescription }
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false; held = 0
        ShortcutSettings.shared.resume()
    }
}
