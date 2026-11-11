import AppKit
import OopsCore
import SwiftUI

/// General's About: stats, version and updates, then what's new, the welcome, the debug tools and the
/// source. General closes with the maker's credit (`Credit`).
struct AboutSection: View {
    @Binding var detail: GeneralDetail?

    /// Placeholder until the repository is public.
    private static let source = URL(string: "https://github.com/0xmrwn/oops")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StatsCard(stats: Stats.shared) { detail = .stats }
            HStack(spacing: 12) {
                Text("Version").fontWeight(.semibold)
                Text(version).secondaryText().monospacedDigit().textSelection(.enabled)
                Spacer(minLength: 8)
                updateStatus
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
    /// The states cross-fade at the button's height, so checking never resizes the row.
    private var updateStatus: some View {
        ZStack(alignment: .trailing) {
            Button {} label: { Label("Check for Updates", systemImage: "arrow.down.circle") }
                .buttonStyle(.settingsGlass).disabled(true).hidden().accessibilityHidden(true)
            updateState.transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: Updates.shared.state)
    }

    @ViewBuilder private var updateState: some View {
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

/// A release waiting to install: what it is, a way to its notes, and the one action it needs now.
struct UpdateCard: View {
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
