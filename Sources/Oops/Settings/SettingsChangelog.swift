import AppKit
import OopsCore
import SwiftUI

/// CHANGELOG.md from the app bundle: `## version` headings, `- ` entries. The newest release is
/// open; older ones are one row each until clicked. Launch-only aid: `-SettingsPreviewChangelog
/// <path>` reads another file.
struct ChangelogPage: View {
    private struct Release: Identifiable {
        let id: String
        var entries: [String]
        /// The heading's first word: "0.1.0" in "0.1.0 (unreleased)".
        var version: String { String(id.split(separator: " ").first ?? "") }
    }
    @State private var open: Set<String> = []

    private static let releases: [Release] = {
        let url = DebugFlags.changelog ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var releases: [Release] = []
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("## ") { releases.append(Release(id: String(line.dropFirst(3)), entries: [])) }
            else if line.hasPrefix("- "), !releases.isEmpty { releases[releases.count - 1].entries.append(String(line.dropFirst(2))) }
        }
        return releases
    }()
    private static let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// A waiting update's notes lead unless the file already lists that version.
    private var releases: [Release] {
        guard let pending = Updates.shared.pending, !Self.releases.contains(where: { $0.version == pending.version }) else {
            return Self.releases
        }
        return [Release(id: pending.version, entries: pending.notes)] + Self.releases
    }

    var body: some View {
        let releases = releases
        VStack(alignment: .leading, spacing: 0) {
            ForEach(releases) { release in
                if release.id != releases.first?.id { Divider() }
                let expanded = release.id == releases.first?.id || open.contains(release.id)
                VStack(alignment: .leading, spacing: 10) {
                    // The newest release is always open; the older ones toggle.
                    if release.id == releases.first?.id {
                        heading(release, expanded: true, toggles: false)
                    } else {
                        Button {
                            if open.contains(release.id) { open.remove(release.id) } else { open.insert(release.id) }
                        } label: { heading(release, expanded: expanded, toggles: true) }
                        .buttonStyle(.plain)
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    }
                    if expanded {
                        ForEach(release.entries, id: \.self) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").secondaryText().accessibilityHidden(true)
                                Text((try? AttributedString(markdown: entry)) ?? AttributedString(entry))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .animation(.easeOut(duration: 0.18), value: open)
    }

    /// Version, then where it stands: the update waiting, or the version running now, so
    /// everything above "Installed" is what an update brings.
    private func heading(_ release: Release, expanded: Bool, toggles: Bool) -> some View {
        HStack(spacing: 8) {
            Text(release.id).font(.headline)
            if release.version == Updates.shared.pending?.version {
                tag("Available", symbol: "arrow.down.circle")
            } else if release.version == Self.installed {
                tag("Installed", symbol: "checkmark")
            }
            Spacer()
            if toggles {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private func tag(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.primary.opacity(0.1), in: .capsule)
    }
}
