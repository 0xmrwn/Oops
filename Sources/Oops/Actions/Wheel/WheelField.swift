import AppKit
import Observation
import OopsCore
import SwiftUI

/// What the centre's field holds while the person types.
@MainActor @Observable final class WheelFieldModel {
    var text = ""
    var placeholder = ""
    var ink = WheelInk(page: nil, systemDark: false, increaseContrast: false, reduceTransparency: false)
    /// Bumped each time the field opens, so it takes the focus again.
    var opening = 0
    @ObservationIgnored var submit: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var cancel: @MainActor () -> Void = {}
}

private final class FieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The centre's field, in a window of its own that takes the keys while the person types. Non-activating: it becomes
/// key without Oops becoming the active app, so the app in front stays in front and gets its keys back after. Input
/// methods, dead keys, paste and editing shortcuts are the system's own.
@MainActor final class WheelFieldPanel {
    let window: NSPanel
    let model: WheelFieldModel

    init(model: WheelFieldModel) {
        self.model = model
        window = FieldPanel(contentRect: CGRect(x: 0, y: 0, width: WheelLayout.field - WheelLayout.drop, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.title = "Oops Actions field"
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: WheelFieldView(model: model))
        host.sizingOptions = []
        window.contentView = host
    }

    /// Over the centre's text area, right of the drop's eyes, for a hub in screen points with a top-left origin.
    func place(hub: CGPoint) {
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        let frame = Self.frame(hub: hub)
        window.setFrame(NSRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height), display: false)
    }

    static func frame(hub: CGPoint) -> CGRect {
        CGRect(x: hub.x - WheelLayout.field / 2 + WheelLayout.drop + 2, y: hub.y - 17, width: WheelLayout.field - WheelLayout.drop - 14, height: 34)
    }

    func show() {
        model.opening += 1
        window.orderFrontRegardless()
        window.makeKey()
    }

    func hide() {
        window.orderOut(nil)
        model.text = ""
    }

    /// Key, with the text field taking the keys: what arrives now is typed into it.
    var isReady: Bool { window.isVisible && window.isKeyWindow && window.firstResponder is NSTextView }
}

struct WheelFieldView: View {
    @Bindable var model: WheelFieldModel
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $model.text, prompt: Text(model.placeholder).foregroundStyle(placeholder))
            .textFieldStyle(.plain)
            .font(.system(size: WheelLayout.labelSize, weight: .medium))
            .modifier(WheelInkStyle(ink: model.ink))
            .lineLimit(1)
            // The caret in the wheel's ink rather than the accent colour: one ink for everything in the wheel.
            .tint(model.ink.plain ? Color.primary : (model.ink.dark ? WheelView.darkInk : .white))
            .focused($focused)
            .onSubmit { model.submit(model.text) }
            .onExitCommand { model.cancel() }
            .onKeyPress(.escape) {
                model.cancel()
                return .handled
            }
            .onAppear { focused = true }
            .onChange(of: model.opening) { focused = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.colorScheme, model.ink.dark ? .light : .dark)
    }

    /// Quiet, in the wheel's ink.
    private var placeholder: Color {
        model.ink.plain ? .secondary : (model.ink.dark ? WheelView.darkInk : .white).opacity(0.6)
    }
}
