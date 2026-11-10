import SwiftUI

/// An item of the Provider step's list. Branded buttons and glass rows share one size in every state, and each
/// mark sits in one column with its label after it: 20 pt in, a 21 pt mark, a 12 pt gap, radius 12, the same
/// mark, gap and radius as the standalone `ContinueWithChatGPTButton`, whose centred content also starts about
/// 20 pt in, so a listed button keeps that geometry and only gains room after its label. 300 holds the longest
/// label ("Finish in your browser…") with room to spare; 48 is the standalone 45 pt height on the 8 pt grid.
enum ProviderListItem {
    static let width: CGFloat = 300, height: CGFloat = 48
    static let inset: CGFloat = 20, gap: CGFloat = 12, mark: CGFloat = 21, radius: CGFloat = 12
}

/// Claude Code's way in, a `ProviderListItem` cut like `ContinueWithChatGPTButton` so the two read as a pair:
/// the Claude mark on Anthropic's orange (#d97757, the brand-guidelines accent in github.com/anthropics/skills).
/// Ink is Anthropic's dark (#141413): white on that orange is 2.6:1, too faint for 15 pt text.
struct ClaudeCodeButton: View {
    enum Need { case install, signIn }
    let need: Need
    var loading = false
    let action: () -> Void

    static let orange = Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let ink = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255)

    var body: some View {
        Button(action: action) {
            HStack(spacing: ProviderListItem.gap) {
                ClaudeSpark()
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1).fixedSize()
                    // Install leaves the app for the setup page.
                    if need == .install, !loading { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)) }
                }
            }
            .foregroundStyle(Self.ink)
            .padding(.horizontal, ProviderListItem.inset)
            .frame(width: ProviderListItem.width, height: ProviderListItem.height, alignment: .leading)
            .background(Self.orange, in: .rect(cornerRadius: ProviderListItem.radius))
            .contentShape(.rect(cornerRadius: ProviderListItem.radius))
        }
        .buttonStyle(BrandButtonStyle())
        .disabled(loading)
        // Only ever listed, inside a scroll view that would clip a ring drawn outside.
        .modifier(FocusVisibleRing(inside: true))
        .accessibilityLabel(accessibilityTitle)
    }

    private var title: String {
        if loading { return "Finish in your browser…" }
        return need == .install ? "Install Claude Code" : "Sign in to Claude Code"
    }

    private var accessibilityTitle: String {
        if loading { return "Signing in to Claude Code, finish in your browser" }
        return need == .install ? "Install Claude Code (opens in browser)" : "Sign in to Claude Code"
    }
}

/// Claude's mark in a list's mark slot. The spark fills its box where OpenAI's mark doesn't: a size smaller reads as the same size.
struct ClaudeSpark: View {
    var body: some View {
        Image("ClaudeMark", bundle: .main).renderingMode(.template).resizable().interpolation(.high)
            .frame(width: 19, height: 19).frame(width: ProviderListItem.mark, height: ProviderListItem.mark).accessibilityHidden(true)
    }
}

/// Pointer and press feedback for the branded buttons, which draw their own fill: the label and fill fade
/// together on hover (0.85) and press (0.72), and a disabled button sits at half strength.
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Faded(configuration: configuration) }

    private struct Faded: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(enabled ? (configuration.isPressed ? 0.72 : hovering ? 0.85 : 1) : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = enabled && $0 }
        }
    }
}

/// A focus ring for buttons that draw their own shape, where the system ring would trace the wrong outline:
/// 3 pt in the system's keyboard-focus colour, 3 pt outside the button, or along its inner edge where a
/// scroll view would clip it. Shown only once the keyboard is in use (`FocusRings`), the same rule as the
/// system's own rings, so a click never leaves one behind.
struct FocusVisibleRing: ViewModifier {
    var inside = false
    var radius = ProviderListItem.radius
    /// Turning true moves focus here: where the keyboard goes after the view it was on is swapped out.
    var claim = false
    @FocusState private var focused: Bool
    @Environment(\.isFocusEffectEnabled) private var keyboardInUse
    @Environment(\.focusReport) private var report
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .onChange(of: focused) { report?.changed($1) }
            .onChange(of: claim, initial: true) { if $1 { focused = true } }
            .overlay {
                if focused, keyboardInUse {
                    RoundedRectangle(cornerRadius: radius + (inside ? 0 : 6))
                        .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                        .padding(inside ? 0 : -6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Tells `focusReport` when this control gains or loses focus, keeping the system's ring.
struct FocusReporting: ViewModifier {
    @FocusState private var focused: Bool
    @Environment(\.focusReport) private var report
    func body(content: Content) -> some View {
        content.focused($focused).onChange(of: focused) { report?.changed($1) }
    }
}

/// Called as a control below gains or loses focus, so a scrolling list can bring it into view. Equal
/// to any other: set once per item, it never needs to update the views reading it.
struct FocusReport: Equatable {
    let changed: (Bool) -> Void
    static func == (_: Self, _: Self) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var focusReport: FocusReport?
}
