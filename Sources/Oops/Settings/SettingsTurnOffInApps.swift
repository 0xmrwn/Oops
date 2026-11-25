import AppKit
import SwiftUI

/// General's way into Turn off in apps, with how many apps Oops is off in.
struct TurnOffInAppsRow: View {
    static let symbol = "square.grid.2x2"
    let open: () -> Void
    private let scope = AppScope.shared

    var body: some View {
        let summary = Self.summary(scope.turnedOff.count)
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                    .secondaryText().accessibilityHidden(true)
                Text("Turn off in apps").fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(summary).secondaryText().monospacedDigit()
                Chevron()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Turn off in apps")
        .accessibilityValue(summary)
        .padding(.vertical, -6)
        .settingsSurface()
    }

    /// The row's state: how many apps Oops is turned off in.
    nonisolated static func summary(_ count: Int) -> String {
        switch count {
        case 0: "None"
        case 1: "1 app"
        default: "\(count) apps"
        }
    }
}

/// General → Turn off in apps: every app Oops has been used in, most recent first, each with its switch. Off turns
/// all of Oops off there, as the menu bar menu's switch does.
struct TurnOffInAppsPage: View {
    private let scope = AppScope.shared

    var body: some View {
        if scope.apps.isEmpty {
            Text("Apps you use Oops in appear here.").secondaryText().frame(maxWidth: .infinity, alignment: .leading).settingsSurface()
        } else {
            VStack(spacing: 0) {
                ForEach(scope.apps, id: \.self) { app in
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
