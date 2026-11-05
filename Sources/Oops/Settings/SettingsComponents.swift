import AppKit
import OopsCore
import SwiftUI

/// What a tool does, on hover, instead of a description under every row.
struct InfoTip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 13)).secondaryText()
            .help(text)
            .accessibilityLabel(text)
    }
}

/// A connection or permission state: monochrome, the symbol tells ok from not.
struct StatusBadge: View {
    let title: String, ok: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    init(_ title: String, ok: Bool) { self.title = title; self.ok = ok }
    var body: some View {
        // Monochrome like the rest of Settings; the symbol, not a colour, tells the states apart.
        Label(title, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary.opacity(contrast == .increased ? 1 : ok ? 0.9 : 0.75))
    }
}

/// Menu items show images at their natural size; provider marks are drawn at 16 pt there.
enum MenuIcon {
    /// SwiftUI drops SF Symbol icons from this menu (as `systemImage` or a symbol NSImage), so the
    /// symbol is drawn into a plain 16 pt template image like the marks.
    static func symbol(_ name: String) -> Image {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return Image(systemName: name) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        return Image(nsImage: image)
    }

    static func image(_ name: String, template: Bool = false) -> Image {
        guard let source = NSImage(named: name), let copy = source.copy() as? NSImage else { return Image(systemName: "circle") }
        copy.size = NSSize(width: 16, height: 16)
        copy.isTemplate = template
        return Image(nsImage: copy)
    }
}

/// A drilled-in page's first row: back to its list, then what the page is about. ⌘[ goes back.
struct DrillHeader<Mark: View>: View {
    let title: String
    let parent: String
    let back: () -> Void
    @ViewBuilder var mark: Mark

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .keyboardShortcut("[", modifiers: .command)
            // Reached with ⌘[ rather than Tab, so it never takes the window's first focus ring.
            .focusable(false)
            .help("Back to \(parent) · ⌘[")
            .accessibilityLabel("Back to \(parent)")
            mark.frame(width: 24, height: 24).accessibilityHidden(true)
                .padding(.leading, 4)
            Text(title).font(.system(size: 20, weight: .semibold)).lineLimit(1).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// The signed-in account, as macOS shows one without a picture: initials on a grey disc. The
/// provider's mark is already in the page header, so the card shows who, not which service.
struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let local = name.split(separator: "@").first.map(String.init) ?? name
        let words = local.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.46)], startPoint: .top, endPoint: .bottom),
                        in: .circle)
            .accessibilityHidden(true)
    }
}

/// The provider's own logo. An API without a preset gets a model's sparkle inside a request's braces:
/// any model behind any endpoint, where a brand or a server would say one vendor or self-hosting.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        switch provider.kind {
        case .chatGPT: asset("OpenAIMark")
        case .claudeCode: asset("ClaudeMark")
        case .api(let preset):
            if let preset = preset.flatMap(ProviderPreset.init(id:)) { asset(preset.logoAsset) }
            else {
                ZStack {
                    Image(systemName: "curlybraces").font(.system(size: size * 0.9, weight: .medium))
                    Image(systemName: "sparkle").font(.system(size: size * 0.36, weight: .semibold))
                }
                .frame(width: size, height: size).accessibilityHidden(true)
            }
        }
    }

    private func asset(_ name: String) -> some View {
        // Monochrome template marks follow the text colour in light and dark.
        Image(name, bundle: .main).renderingMode(.template).resizable().interpolation(.high)
            .foregroundStyle(.primary).frame(width: size, height: size).accessibilityHidden(true)
    }
}
