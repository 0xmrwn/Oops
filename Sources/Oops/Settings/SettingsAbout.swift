import AppKit
import OopsCore
import SwiftUI

/// About's pages one level down.
enum AboutDetail: Hashable {
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

/// Stats, version and updates, then what's new, the source and the debug tools. The maker's
/// credit is the window's footer on this page (`Credit`).
struct AboutPage: View {
    @Binding var detail: AboutDetail?
    let hasAccessibility: Bool
    let preferences: Preferences
    let preview: () -> Void
    let previewPlacement: @MainActor () async -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Placeholder until the repository is public.
    private static let source = URL(string: "https://github.com/0xmrwn/oops")!

    var body: some View {
        ZStack(alignment: .top) {
            switch detail {
            case .stats:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Stats", parent: "About", back: { detail = nil }) {
                        Image(systemName: "chart.bar.xaxis").font(.system(size: 18, weight: .medium))
                    }
                    StatsPage(stats: Stats.shared)
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .changelog:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Changelog", parent: "About", back: { detail = nil }) {
                        Image(systemName: "sparkles.rectangle.stack").font(.system(size: 18, weight: .medium))
                    }
                    ChangelogPage()
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case .debug:
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Debug tools", parent: "About", back: { detail = nil }) {
                        Image(systemName: "ladybug").font(.system(size: 18, weight: .medium))
                    }
                    DebugToolsPage(preferences: preferences, preview: preview, previewPlacement: previewPlacement)
                }
                .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            case nil:
                overview.transition(PaneSlideTransition(edge: -1, reduceMotion: reduceMotion))
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: detail)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A waiting update comes first; its notes are the Changelog's top entry.
            if let release = Updates.shared.pending {
                UpdateCard(release: release, state: Updates.shared.state) { detail = .changelog }
            }
            StatsCard(stats: Stats.shared) { detail = .stats }
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Text("Version").fontWeight(.semibold)
                    Text(version).secondaryText().monospacedDigit().textSelection(.enabled)
                    Spacer(minLength: 8)
                    updateStatus
                }
                // General shows the permission only while it is missing.
                if hasAccessibility {
                    Divider()
                    HStack {
                        Text("Accessibility").fontWeight(.semibold)
                        Spacer()
                        StatusBadge("Enabled", ok: true)
                    }
                }
            }
            .settingsSurface()
            VStack(spacing: 0) {
                AboutRow(title: "Changelog") { detail = .changelog } icon: {
                    Image(systemName: "sparkles.rectangle.stack").font(.system(size: 17, weight: .medium))
                }
                Divider()
                AboutRow(title: "Show welcome", trailing: "arrow.up.right") { OnboardingWindow.shared.show() } icon: {
                    Image(systemName: "hand.wave").font(.system(size: 16, weight: .medium))
                }
                Divider()
                AboutRow(title: "Debug tools") { detail = .debug } icon: {
                    Image(systemName: "ladybug").font(.system(size: 17, weight: .medium))
                }
                Divider()
                AboutRow(title: "Source code", trailing: "arrow.up.right") { NSWorkspace.shared.open(Self.source) } icon: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 15, weight: .semibold))
                }
            }
            .padding(.vertical, -6)
            .settingsSurface()
        }
    }

    /// Beside the version: Check, then checking, then up to date or what went wrong. A found update has its own card.
    @ViewBuilder private var updateStatus: some View {
        switch Updates.shared.state {
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").secondaryText() }
        case .upToDate:
            StatusBadge("Up to date", ok: true)
        case .available, .downloading, .ready:
            EmptyView()
        case .failed(let message):
            HStack(spacing: 10) {
                StatusBadge("Couldn’t update", ok: false).help(message).accessibilityHint(message)
                Button { Updates.shared.check() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.settingsGlass)
            }
        case .idle:
            // Development builds carry no feed, so they never check.
            Button { Updates.shared.check() } label: { Label("Check for Updates", systemImage: "arrow.down.circle") }
                .buttonStyle(.settingsGlass).disabled(!Updates.shared.canCheck)
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version + (build.map { " (" + $0 + ")" } ?? "")
    }
}

/// A release waiting to install: what it is, a way to its notes, and the one action it needs now.
private struct UpdateCard: View {
    let release: Updates.Release
    let state: Updates.State
    let showNotes: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            if let icon = AppIcon.image(dark: colorScheme == .dark) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Oops \(release.version)").font(.headline)
                Button(action: showNotes) {
                    HStack(spacing: 3) {
                        Text("What’s new")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.callout).secondaryText().contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerStyle(.link)
            }
            Spacer(minLength: 8)
            switch state {
            case .downloading(_, let progress):
                ProgressView(value: progress).frame(width: 140).tint(.primary)
                    .accessibilityLabel("Downloading \(Int(progress * 100)) percent")
            case .ready:
                Button { Updates.shared.relaunch() } label: { Label("Relaunch", systemImage: "arrow.clockwise") }
                    .buttonStyle(.glassProminent).tint(.accentColor)
            default:
                Button { Updates.shared.install() } label: { Label("Update", systemImage: "arrow.down.circle") }
                    .buttonStyle(.glassProminent).tint(.accentColor)
            }
        }
        .settingsSurface()
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

/// A list row like Providers': icon, title and where it leads (a page by default, or a link).
private struct AboutRow<Icon: View>: View {
    let title: String
    var trailing = "chevron.right"
    let action: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon.frame(width: 24).accessibilityHidden(true)
                Text(title).fontWeight(.semibold)
                Spacer(minLength: 8)
                Image(systemName: trailing).font(.system(size: 11, weight: .semibold)).secondaryText()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The maker's credit: the GitHub mark and handle, linking to the profile.
struct Credit: View {
    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: "https://github.com/0xmrwn")!) } label: {
            HStack(spacing: 6) {
                Image("GitHubMark", bundle: .main).renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14)
                Text("0xmrwn").fontWeight(.medium)
            }
            .font(.callout)
            .secondaryText()
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("github.com/0xmrwn")
        .accessibilityLabel("0xmrwn on GitHub")
    }
}
