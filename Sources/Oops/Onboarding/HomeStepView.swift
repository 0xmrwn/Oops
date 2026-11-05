import SwiftUI

/// The last step over Hello's wallpaper: the companion drop looking up at the menu bar, a strip of
/// it with Oops's eyes picked out, and a small card with Open at login. Done folds the window into
/// the eyes.
struct HomeStepView: View {
    @Bindable var step: HomeStep

    var body: some View {
        OnboardingStepLayout(height: 380) { column } primary: {
            OnboardingNextButton(title: "Done", symbol: nil, action: step.finish)
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { step.noteDrop($0) }
            Text(step.eyesVisible ? "Oops lives in your menu bar" : "Open Oops again for its Settings")
                .font(.system(size: 26, weight: .semibold)).padding(.top, 20)
            // The header stays where every step has it; the rest sits midway between it and Done, which
            // the column ends just above.
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                if step.eyesVisible { MenuBarStrip() }
                card
            }
            Spacer(minLength: 24)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, OnboardingFooter.reserved)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "power").font(.system(size: 15, weight: .semibold)).frame(width: 22).opacity(0.8)
                    .accessibilityHidden(true)
                Text("Open at login").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Open at login", isOn: $step.openAtLogin).toggleStyle(.switch).labelsHidden().tint(.white.opacity(0.85))
            }
            .padding(.horizontal, 18).frame(height: 52)
        }
        .frame(width: 400)
        .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 22)) }
    }
}

/// A stretch of the menu bar, right end: a few of the system's items and Oops's eyes, picked out
/// and breathing, so the real ones above are easy to find.
private struct MenuBarStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beat = false

    var body: some View {
        HStack(spacing: 18) {
            ForEach(["wifi", "battery.75percent", "magnifyingglass"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).opacity(0.55)
            }
            Image(nsImage: MenuBarEyes.image).renderingMode(.template)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background { Capsule().fill(.white.opacity(beat ? 0.3 : 0.16)) }
                .scaleEffect(beat ? 1.08 : 1)
            Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 13, weight: .medium)).opacity(0.55)
        }
        .padding(.horizontal, 18).frame(height: 34)
        .background { Color.clear.glassEffect(.clear, in: .capsule) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Oops's eyes, in the menu bar")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever()) { beat = true }
        }
    }
}
