#if DEBUG
import AppKit
import SwiftUI

/// The production capsule view in a controllable window, without an editor or provider session.
@MainActor final class BrandCapsuleReview: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        let view = CapsuleReviewBoard { [weak self] dark in
            self?.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        let window = FocusRingsWindow(contentViewController: NSHostingController(rootView: view.focusRingsFromKeyboard()))
        window.title = "Oops · capsule consistency"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

private struct CapsuleReviewBoard: View {
    let appearance: (Bool) -> Void
    @StateObject private var model = CapsuleModel()
    @State private var dark = false
    @State private var reduceMotion = false
    @State private var opaque = false
    @State private var contrast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Correction capsule").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Dark", isOn: $dark).toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                ForEach(["Working", "Fixed", "Clear", "Failed", "Pending", "Copied", "Reverted"], id: \.self) { state in
                    Button(state) { show(state) }
                }
            }
            EyesDropView(model: model, previewAccessibility: Set([
                reduceMotion ? "reduce-motion" : nil,
                opaque ? "reduce-transparency" : nil,
                contrast ? "increase-contrast" : nil,
            ].compactMap(\.self)))
                .frame(width: 440, height: 130, alignment: .center)
                .frame(maxWidth: .infinity)
            HStack(spacing: 24) {
                Toggle("Reduce Motion", isOn: $reduceMotion)
                Toggle("Opaque backing", isOn: $opaque)
                Toggle("Increase Contrast", isOn: $contrast)
            }
            Text("Native capsule at its shipping size. These controls simulate the app's accessibility branches.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: dark) { _, dark in appearance(dark) }
        .onAppear {
            appearance(dark)
            model.cancel = { model.presented = false }
            model.revert = { show("Reverted") }
            model.retry = { show("Working") }
            model.copy = { show("Copied") }
            model.dismiss = { model.presented = false }
            show("Working")
        }
    }

    private func show(_ state: String) {
        model.canRevert = state == "Fixed"
        model.remedy = state == "Failed" ? .retry : nil
        model.copied = state == "Copied"
        model.label = switch state {
        case "Fixed": "3 fixes · 0.8s"
        case "Clear": "Already clear · 0.8s"
        case "Failed": "No connection"
        case "Pending": "Couldn’t paste"
        case "Copied": "Copied"
        case "Reverted": "Reverted"
        default: "Fixing…"
        }
        model.phase = switch state {
        case "Fixed", "Clear": .fixed
        case "Failed": .failed
        case "Pending": .pending
        case "Copied": .copied
        case "Reverted": .reverted
        default: .working
        }
        model.presented = true
    }
}
#endif
