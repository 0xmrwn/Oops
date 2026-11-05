#if DEBUG
import AppKit
import SwiftUI

/// A real status item beside a native size board, without the correction app's services.
@MainActor final class BrandIconReview: NSObject, NSWindowDelegate, NSMenuDelegate, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

    func show() {
        NSApp.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button { MenuBarEyes.configure(button) }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Oops · icon review", action: nil, keyEquivalent: "")
        let show = menu.addItem(withTitle: "Show review", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        let close = menu.addItem(withTitle: "Close review", action: #selector(quit), keyEquivalent: "")
        close.target = self; item.menu = menu
        statusItem = item
        let root = BrandIconBoard(openMenu: { item.button?.performClick(nil) },
                                  hide: { [weak self] in self?.hideWindow() },
                                  close: { [weak self] in self?.quit() })
        let window = FocusRingsWindow(contentViewController: NSHostingController(rootView: root.focusRingsFromKeyboard()))
        window.title = "Oops · system surfaces"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.writeProof("window-open") }
    }

    func windowWillClose(_ notification: Notification) { quit() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    @objc private func showWindow() {
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        writeProof("window-restored")
    }

    private func hideWindow() {
        guard let window else { return }
        window.orderOut(nil)
        NSApp.leaveDockUnlessOtherWindows(than: window)
        writeProof("menu-bar-only")
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The next turn samples the system button after AppKit enters menu tracking.
        DispatchQueue.main.async { [weak self] in self?.writeProof("menu-selected") }
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.writeProof("menu-closed") }
    }

    private func writeProof(_ name: String) {
        guard let directory = DebugFlags.systemSurfaceProofs, let button = statusItem?.button else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let facts: [String: Any] = [
                "event": name, "activationPolicy": NSApp.activationPolicy().rawValue,
                "windowVisible": window?.isVisible == true, "statusItemVisible": statusItem?.isVisible == true,
                "buttonHighlighted": button.isHighlighted, "template": button.image?.isTemplate == true,
                "buttonLabel": button.accessibilityLabel() ?? "", "appearance": button.effectiveAppearance.name.rawValue,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            ]
            try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".json"))
            if let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
        } catch { assertionFailure("System surface proof failed: \(error)") }
    }

    @objc private func quit() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        NSApp.terminate(nil)
    }
}

private struct BrandIconBoard: View {
    let openMenu: () -> Void
    let hide: () -> Void
    let close: () -> Void
    private let sizes: [CGFloat] = [128, 64, 32, 16]
    private let packagedIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                BrandWordmark().frame(width: 140, height: 52.43)
                Spacer()
                Text("System surfaces").foregroundStyle(.secondary)
            }
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 22) {
                    Text(dark ? "Dark background" : "Light background").font(.headline)
                    HStack(alignment: .bottom, spacing: 46) {
                        ForEach(sizes, id: \.self) { size in
                            VStack(spacing: 12) {
                                // Resolve the bundle as Finder does; this is not the in-window PNG.
                                Image(nsImage: packagedIcon).resizable().frame(width: size, height: size)
                                    .accessibilityLabel("Packaged Oops icon")
                                Text("\(Int(size)) pt").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    HStack(spacing: 28) {
                        ForEach(["Normal", "On", "Disabled"], id: \.self) { state in
                            HStack(spacing: 8) {
                                BrandTemplateButton(selected: state == "On", enabled: state != "Disabled")
                                    .frame(width: 28, height: 24)
                                Text(state).font(.callout)
                            }
                        }
                        Spacer()
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100")
                        Image(nsImage: MenuBarEyes.image).renderingMode(.template)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(dark ? Color(white: 0.1) : Color(white: 0.96))
                .environment(\.colorScheme, dark ? .dark : .light)
            }
            HStack {
                Button("Open menu", action: openMenu)
                Button("Menu bar only", action: hide)
                Button("Reveal app in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button("Close review", action: close)
            }
            Text("Finder-resolved icon in the current system style. Native button samples; Open menu checks the real status item.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 820)
    }
}

/// AppKit owns template tint and pressed treatment; actual status-item selection is reviewed live.
private struct BrandTemplateButton: NSViewRepresentable {
    let selected: Bool
    let enabled: Bool

    func makeNSView(context: Context) -> BrandTemplateSample {
        BrandTemplateSample()
    }

    func updateNSView(_ view: BrandTemplateSample, context: Context) {
        view.button.isEnabled = enabled
        view.button.state = selected ? .on : .off
    }
}

private final class BrandTemplateSample: NSView {
    let button = NSButton(image: MenuBarEyes.image, target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .accessoryBarAction
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Oops")
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        button.frame = bounds
    }
}
#endif
