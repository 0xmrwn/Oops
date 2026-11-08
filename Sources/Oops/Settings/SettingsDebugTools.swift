import AppKit
import OopsCore
import SwiftUI

/// Debug tools: the debug log, the capsule and where it lands. The test editor is General's Try.
struct DebugToolsPage: View {
    @ObservedObject var preferences: Preferences
    let preview: () -> Void
    let previewPlacement: @MainActor () async -> String
    @StateObject private var probe = PlacementProbe()
    @AppStorage(DebugLog.key) private var logging = false
    @State private var logSize = 0
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            debugLog
            Divider()
            HStack(spacing: 16) {
                title("Capsule", tip: "Plays the capsule’s busy and done animation here, without sending any text.")
                Spacer()
                Button(action: preview) { Label("Play", systemImage: "play") }.buttonStyle(.settingsGlass)
            }
            Divider()
            placementProbe
            if !preferences.status.isEmpty {
                Divider()
                Text(preferences.status).font(.callout).textSelection(.enabled)
            }
        }
        .settingsSurface()
    }

    private var debugLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                title("Debug log", tip: "Keeps every correction on this Mac: the app, the text read, the model’s answer and what was applied, to build evals. Nothing leaves this Mac.")
                Spacer()
                if logSize > 0 {
                    Text(Int64(logSize).formatted(.byteCount(style: .file))).secondaryText().monospacedDigit()
                    Button { NSWorkspace.shared.activateFileViewerSelecting(DebugLog.store.files()) } label: {
                        Label("Log", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.settingsGlass).help("Show the debug log in Finder")
                    Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }.buttonStyle(.settingsGlass)
                }
                Toggle("Debug log", isOn: $logging).settingsSwitch().labelsHidden()
            }
            if let deleteError {
                Label(deleteError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: measureLog)
        .onChange(of: logging) { measureLog() }
        .confirmationDialog("Delete the debug log?", isPresented: $confirmingDelete) {
            Button("Delete Log", role: .destructive) {
                do { try DebugLog.store.deleteAll(); deleteError = nil } catch { deleteError = "Couldn’t delete the log. \(error.localizedDescription)" }
                measureLog()
            }
        } message: {
            Text("Every recorded correction is removed. This can’t be undone.")
        }
    }

    private func measureLog() { logSize = DebugLog.store.size }

    /// A tool's name with its explanation on hover.
    private func title(_ name: String, tip: String) -> some View {
        HStack(spacing: 6) {
            Text(name).fontWeight(.medium)
            InfoTip(tip)
        }
    }

    private var placementProbe: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                title("Placement", tip: "Where the capsule lands in other apps. Press Preview or Probe, then click into a text box within 5 s: Preview shows the capsule there; Probe records the box and caret positions to the log. Geometry only, never text.")
                if let countdown = probe.countdown {
                    Text("Click into a composer… \(countdown)").font(.callout).secondaryText().monospacedDigit()
                }
                Spacer()
                Button { probe.revealLog() } label: { Label("Log", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.settingsGlass).help("Show the probe log in Finder")
                if probe.countdown == nil {
                    Button { probe.start(previewPlacement) } label: { Label("Preview", systemImage: "capsule") }
                        .buttonStyle(.settingsGlass).help("Show the capsule where it would appear, 5 s after you press")
                    Button { probe.start() } label: { Label("Probe", systemImage: "scope") }.buttonStyle(.settingsGlass)
                        .help("Record where the text box and caret are, 5 s after you press. Geometry only, never text.")
                } else {
                    Button { probe.cancel() } label: { Label("Cancel", systemImage: "xmark") }.buttonStyle(.settingsGlass)
                }
            }
            Picker("Full accessibility in Chromium apps", selection: $probe.mode) {
                ForEach(PlacementProbe.Mode.allCases) { Text($0.title).tag($0) }
            }
            .font(.callout).fixedSize()
            .help("Sets the chosen switch on the app for about 3 s, samples, then restores it. Electron answers AXManualAccessibility; Chrome and WebView2 answer AXEnhancedUserInterface.")
            if !probe.summary.isEmpty {
                Text(probe.summary).font(.callout).secondaryText().textSelection(.enabled)
            }
        }
    }
}
