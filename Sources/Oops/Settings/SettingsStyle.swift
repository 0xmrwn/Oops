import AppKit
import SwiftUI

// MARK: - Material variants

/// How much of the desktop shows through Settings. `lens`, the shipped look, is the regular glass
/// lens with a faint tint: it defocuses text behind the window into colour and light instead of
/// covering it. `clear` lets that text read through; the others remain for comparison (DebugFlags).
enum SettingsGlassVariant: String, CaseIterable {
    case standard, lens, clear, clearest
    static var current: Self {
        DebugFlags.glassVariant.flatMap(Self.init(rawValue:)) ?? .lens
    }
}

/// Everything the settings window needs to render its material consistently.
struct SettingsStyle {
    var variant: SettingsGlassVariant = .lens
    /// Reduce Transparency (system setting or the `SettingsPreviewReduceTransparency` debug default).
    var opaque = false

    /// Secondary text gains contrast as the window becomes clearer.
    var secondaryOpacity: Double {
        if opaque { return 0.75 }
        switch variant {
        case .standard: return 0.78
        case .lens, .clear: return 0.84
        case .clearest: return 0.88
        }
    }

    /// Debug-only: forces the Reduce Transparency path without touching the system setting.
    static var forcesOpaque: Bool { DebugFlags.opaqueSettings }
}

extension EnvironmentValues {
    @Entry var settingsStyle = SettingsStyle()
}

extension View {
    func settingsSurface() -> some View { modifier(SettingsSurface()) }
    func secondaryText() -> some View { modifier(SecondaryText()) }
    /// Settings' switches: monochrome rather than the accent blue, so they sit quietly on the glass.
    func settingsSwitch() -> some View { toggleStyle(.switch).tint(.primary.opacity(0.62)) }
}

private struct SecondaryText: ViewModifier {
    @Environment(\.settingsStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        // Increase Contrast: secondary text stays a step down from primary, but only just.
        let opacity = contrast == .increased ? 0.95 : reduceTransparency ? 0.75 : style.secondaryOpacity
        content.foregroundStyle(.primary.opacity(opacity))
    }
}

/// Content panes: clear glass on the standard enclosure; tinted or frosted glass as the
/// window gets clearer, so text keeps its contrast; opaque under Reduce Transparency.
private struct SettingsSurface: ViewModifier {
    @Environment(\.settingsStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: 16)

    func body(content: Content) -> some View {
        let padded = content.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        if style.opaque || reduceTransparency {
            padded
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            padded.glassEffect(glass, in: shape)
        }
    }
}

extension SettingsSurface {
    private var glass: Glass {
        switch style.variant {
        case .standard: .clear
        case .lens, .clear: .clear.tint(colorScheme == .dark ? .black.opacity(0.16) : .white.opacity(0.16))
        case .clearest: .regular
        }
    }
}

/// Keep native optical highlights while giving clear interior panes a readable backdrop.
/// Dynamic tint follows the window appearance, including local light/dark previews.
final class SettingsGlassEnclosure: NSGlassEffectView {
    var variant: SettingsGlassVariant = .lens { didSet { updateTint() } }
    var forcesOpaque = false { didSet { updateTint() } }
    /// Opacity of the backdrop blur beneath the glass; only the clear variant uses it.
    var frostAlpha: CGFloat { !forcesOpaque && variant == .clear ? 0.35 : 0 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTint()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }
    private func updateTint() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if forcesOpaque {
            style = .regular
            tintColor = .windowBackgroundColor
            return
        }
        switch variant {
        case .standard:
            style = .regular
            tintColor = dark ? NSColor(calibratedWhite: 0.06, alpha: 0.65) : NSColor(calibratedWhite: 1, alpha: 0.25)
        case .lens:
            // The regular lens blurs what is behind into colour, so text behind cannot compete
            // with ours; a faint tint keeps that colour vivid rather than milky or murky.
            style = .regular
            tintColor = dark ? NSColor(calibratedWhite: 0.05, alpha: 0.18) : NSColor(calibratedWhite: 1, alpha: 0.06)
        case .clear:
            // Clear glass, but a tint that still carries the content; lighter than before
            // because the backdrop frost (`frostAlpha`) now contributes some of that body.
            style = .clear
            tintColor = dark ? NSColor(calibratedWhite: 0.05, alpha: 0.38) : NSColor(calibratedWhite: 1, alpha: 0.12)
        case .clearest:
            style = .clear
            tintColor = dark ? NSColor(calibratedWhite: 0.04, alpha: 0.22) : NSColor(calibratedWhite: 1, alpha: 0.04)
        }
    }
}

/// NSGlassEffectView has no blur control: under the clear enclosure, a faint behind-window
/// blur softens the backdrop that the glass refracts, between `.clear` and `.regular`.
final class SettingsWindowBackdrop: NSView {
    /// The Settings window, whether or not it is key (a popover closing may leave another window key).
    @MainActor static var window: NSWindow? { NSApp.windows.first { $0.contentView is SettingsWindowBackdrop } }
    private let frost = NSVisualEffectView()
    private let enclosure: SettingsGlassEnclosure

    init(enclosure: SettingsGlassEnclosure) {
        self.enclosure = enclosure
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        frost.blendingMode = .behindWindow; frost.material = .underWindowBackground; frost.state = .active
        frost.maskImage = Self.mask(radius: enclosure.cornerRadius)
        for view in [frost, enclosure] { view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view) }
        frost.alphaValue = enclosure.frostAlpha
    }
    required init?(coder: NSCoder) { nil }

    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill(); return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Motion

enum SettingsMotion {
    /// Top-level tabs.
    static func page(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.08)
    }
    /// Provider and connection-state swaps.
    static func swap(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0)
    }
    /// Popover drill-in and out.
    static func drill(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: 0.3, bounce: 0.05)
    }
}

/// Departing views stop taking layout space at once, so the measured size (and the
/// window height that follows it) is always the destination's, never the overlap.
private struct CollapseOnRemoval: ViewModifier {
    let removed: Bool
    func body(content: Content) -> some View {
        content.frame(height: removed ? 0 : nil, alignment: .top)
    }
}

/// Pages kept alive: the shown page sits in place; the others wait faded, blurred and a short way
/// off on their own side (left of the shown page or right of it), so whichever is chosen slides
/// in from where it lies, like the tab bar's order, while the one leaving is gone at once.
/// Hidden pages take no height (the window fits the shown one), no clicks and no VoiceOver at
/// once; keyboard focus follows `enabled`, which the caller times so that no control dims or
/// re-styles where it can be seen. Only the look animates.
struct PageSwap: ViewModifier {
    let position: Int
    var enabled = true
    let reduceMotion: Bool
    var distance: CGFloat = 28

    func body(content: Content) -> some View {
        let shown = position == 0
        content
            .disabled(!enabled)
            .frame(height: shown ? nil : 0, alignment: .top)
            .animation(nil, value: shown)
            // Not zero: SwiftUI drops a fully transparent view's layers, and rebuilding a page's
            // layers, glass and text on each switch stalled the click by tens of milliseconds.
            .opacity(shown ? 1 : 0.001)
            .blur(radius: shown || reduceMotion ? 0 : 6)
            .offset(x: reduceMotion ? 0 : CGFloat(position) * distance)
            // The arriving page takes the page spring; the leaving one is gone within a few
            // frames, so two pages of glass never overlap and the new one resolves alone.
            .animation(shown ? SettingsMotion.page(reduceMotion) : .easeOut(duration: 0.08), value: shown)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

/// State swaps in place: cross-fade with a subtle blur and scale.
struct SettleTransition: Transition {
    let reduceMotion: Bool
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity || reduceMotion ? 0 : 4)
            .scaleEffect(phase.isIdentity || reduceMotion ? 1 : 0.98, anchor: .top)
            .modifier(CollapseOnRemoval(removed: phase == .didDisappear))
    }
}

/// Popover panes: the root pane lives to the left (`edge` −1), drill-down panes to the right (+1).
struct PaneSlideTransition: Transition {
    let edge: CGFloat
    let reduceMotion: Bool
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(x: phase.isIdentity || reduceMotion ? 0 : edge * 44)
            .modifier(CollapseOnRemoval(removed: phase == .didDisappear))
    }
}

// MARK: - Screenshot backdrop (debug only)

/// A vivid wallpaper-like field with a few hard edges, so blur and tint differences are visible.
/// `SettingsPreviewBackdrop=text` lays documents and code over it: the case where text behind
/// the window competes with its own.
struct SettingsPreviewBackdrop: View {
    var body: some View {
        ZStack {
            wallpaper
            if DebugFlags.backdropText { PreviewDocuments() }
        }
        .ignoresSafeArea()
    }

    private var wallpaper: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.62, 0.42], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                .orange, .pink, .purple,
                .yellow, .red, .indigo,
                .mint, .teal, .blue
            ])
            GeometryReader { geometry in
                ForEach(0..<9) { index in
                    Rectangle()
                        .fill(.white.opacity(index.isMultiple(of: 2) ? 0.55 : 0.2))
                        .frame(width: 14, height: geometry.size.height * 2)
                        .rotationEffect(.degrees(28))
                        .position(x: geometry.size.width * (0.08 + Double(index) * 0.11), y: geometry.size.height / 2)
                }
                Circle().fill(.white).frame(width: 120, height: 120)
                    .position(x: geometry.size.width * 0.78, y: geometry.size.height * 0.28)
                Circle().fill(.black.opacity(0.75)).frame(width: 90, height: 90)
                    .position(x: geometry.size.width * 0.22, y: geometry.size.height * 0.7)
            }
        }
    }
}

/// A light document, a run of bold wallpaper text and a dark code editor, stacked.
private struct PreviewDocuments: View {
    private static let prose = "Quick update on the quarterly planning. We have finalised the roadmap for the next two sprints and the priorities are now clear. The design review moved to Thursday; please make sure your slides are ready by Wednesday evening. "
    private static let code = (0..<40).map { "let value\($0) = try await provider.correct(draft, effort: .low) // retry \($0 % 3)" }.joined(separator: "\n")
    var body: some View {
        VStack(spacing: 0) {
            Text(String(repeating: Self.prose, count: 14)).font(.system(size: 15)).foregroundStyle(.black)
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(.white).clipped()
            Text(String(repeating: "oops · liquid glass · ", count: 30)).font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            Text(Self.code).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1))
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(red: 0.1, green: 0.1, blue: 0.13)).clipped()
        }
    }
}

extension Int {
    /// -1, 0 or 1: where this index lies relative to another.
    func signum(relativeTo other: Int) -> Int { (self - other).signum() }
}
