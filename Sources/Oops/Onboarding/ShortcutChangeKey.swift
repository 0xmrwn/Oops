import SwiftUI

/// Change shortcut, made as one more key beside the shortcut's own: the keycaps' clear glass, white
/// hairline, corners and rounded type, so it reads as part of the keys rather than a stray button.
/// While recording the same key cancels; it keeps its width, so nothing beside it shifts.
struct ShortcutChangeKey: View {
    let recording: Bool
    let height: CGFloat
    let radius: CGFloat
    let font: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                label("Change shortcut", symbol: "keyboard", shown: !recording)
                label("Cancel", symbol: "xmark", shown: recording)
            }
            .font(.system(size: font, weight: .medium, design: .rounded))
            .padding(.horizontal, height * 0.4)
            .frame(height: height)
        }
        .buttonStyle(KeyButtonStyle(radius: radius))
        // A custom style draws no system ring.
        .modifier(FocusVisibleRing(radius: radius))
        .foregroundStyle(.white)
    }

    private func label(_ title: LocalizedStringKey, symbol: String, shown: Bool) -> some View {
        HStack(spacing: font * 0.5) {
            Image(systemName: symbol).font(.system(size: font * 0.95, weight: .medium))
            Text(title)
        }
        .opacity(shown ? 1 : 0)
        .accessibilityHidden(!shown)
    }
}

/// A key's look and its press: clear glass with a hairline that brightens under the pointer, and a
/// sink when pressed, as the keycaps sink when their keys go down.
private struct KeyButtonStyle: ButtonStyle {
    let radius: CGFloat
    func makeBody(configuration: Configuration) -> some View { Key(configuration: configuration, radius: radius) }

    private struct Key: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .shadow(color: .black.opacity(0.35), radius: 3)
                .background { Color.clear.glassEffect(.clear.tint(.white.opacity(configuration.isPressed ? 0.2 : 0.04)), in: .rect(cornerRadius: radius)) }
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(.white.opacity(configuration.isPressed ? 0.7 : hovering ? 0.5 : 0.28), lineWidth: 1.25)
                }
                .contentShape(.rect(cornerRadius: radius))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .offset(y: configuration.isPressed ? 2 : 0)
                .animation(.spring(duration: 0.18, bounce: 0.35), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
