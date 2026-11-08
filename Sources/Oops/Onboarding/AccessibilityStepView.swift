import SwiftUI

/// The Accessibility step over Hello's wallpaper. The companion drop (drawn by the window at the
/// "step" anchor) is the thing to drag: grabbing it opens System Settings' Accessibility pane, and
/// a sketch of that list below shows where it goes, a ghost drop falling into Oops's empty row.
struct AccessibilityStepView: View {
    let step: AccessibilityStep
    let next: () -> Void

    var body: some View {
        let ready = step.phase == .granted
        OnboardingStepLayout(height: 380) { column } primary: {
            if ready {
                OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if step.needsRelaunch {
                OnboardingNextButton(title: "Relaunch Oops", icon: "arrow.clockwise", symbol: nil, width: 250, action: Relaunch.now)
                    .help("macOS sometimes needs Oops to restart before it sees the permission")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                OnboardingNextButton(title: "Open System Settings", icon: "gearshape", symbol: nil, width: 250, action: step.openSettings)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        } skip: {
            if !ready { OnboardingSkipButton(action: next).transition(.opacity) }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: ready)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: step.needsRelaunch)
        .onAppear { step.start() }
        .onDisappear { step.stop() }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
                .overlay {
                    // Offscreen snapshots can't draw an AppKit view.
                    if step.phase != .granted, DebugFlags.setupSnapshots == nil {
                        DropDragSource(onBegin: step.dragBegan, onEnd: step.dragEnded, onClick: step.openSettings, onHover: step.hover)
                    }
                }
            Text(step.phase == .granted ? "Oops is allowed" : "Drag Oops into System Settings")
                .font(.system(size: 26, weight: .semibold)).padding(.top, 20)
                .contentTransition(.opacity)
            AccessibilityListSketch(granted: step.phase == .granted, demo: step.phase == .waiting && !step.carried)
                .padding(.top, 26)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: step.phase)
    }
}
