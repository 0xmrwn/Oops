import AppKit
import SwiftUI

/// Two or three choices in a row, in the tab bar's language: a faint capsule track with one glass pill that
/// slides to the chosen one.
struct GlassChoice<Value: Hashable>: View {
    let title: String
    let choices: [(value: Value, label: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.value) { choice in
                let selected = choice.value == selection
                Button { selection = choice.value } label: {
                    Text(choice.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(selected ? 1 : 0.68))
                        .padding(.horizontal, 12).frame(minHeight: 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: ChoiceBounds<Value>.self, value: .bounds) { [choice.value: $0] }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // One pill that follows the chosen label, animated on the value itself: a selection kept in UserDefaults
        // reaches the view outside any `withAnimation`, and a pill per label would only cross-fade. It is placed
        // from the labels' own bounds, which are known in its first frame: matched to a label's geometry it was
        // a frame late, and shrank from the whole track to its label when its page slid in.
        .backgroundPreferenceValue(ChoiceBounds<Value>.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[selection] {
                    let frame = proxy[anchor]
                    Capsule().fill(.clear)
                        .glassEffect(.regular.interactive(enabled), in: .capsule)
                        .glassEdge(Capsule(), outside: true)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.15), value: selection)
        .padding(3)
        .background {
            Capsule().fill(.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                .overlay { if colorScheme == .dark { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) } }
                .glassEdge(Capsule())
        }
        .opacity(enabled ? 1 : 0.6)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Where each of a `GlassChoice`'s labels lies, for its pill.
private struct ChoiceBounds<Value: Hashable>: PreferenceKey {
    static var defaultValue: [Value: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [Value: Anchor<CGRect>], nextValue: () -> [Value: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A choice from a list, as a glass capsule showing the current value, like the model picker. It is a glass
/// button that opens a native menu below itself: SwiftUI's `Menu` drops the glass style on macOS and puts
/// the label's chevron first.
struct GlassMenu<Value: Hashable>: View {
    let title: String
    let choices: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Shown while the selection is none of the choices.
    var placeholder = ""
    /// The header a choice sits under, as the model picker groups models by provider; nil for none.
    var section: (Value) -> String? = { _ in nil }
    @State private var anchor = MenuAnchor()

    var body: some View {
        let current = choices.firstIndex { $0.value == selection }
        Button {
            anchor.popUp(choices.map(\.label), sections: choices.map { section($0.value) }, checked: current) {
                selection = choices[$0].value
            }
        } label: {
            HStack(spacing: 6) {
                Text(current.map { choices[$0].label } ?? placeholder).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.settingsGlass)
        .controlSize(.large)
        .fixedSize()
        .background { MenuAnchorView(anchor: anchor) }
        .accessibilityLabel(title)
        .accessibilityValue(current.map { choices[$0].label } ?? placeholder)
    }
}

/// Where a `GlassMenu` opens its menu, and what a pick does.
@MainActor final class MenuAnchor: NSObject {
    fileprivate weak var view: NSView?
    private var pick: ((Int) -> Void)?

    func popUp(_ titles: [String], sections: [String?], checked: Int?, pick: @escaping (Int) -> Void) {
        guard let view else { return }
        self.pick = pick
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            if let section = sections[index], index == 0 || sections[index - 1] != section {
                if index > 0 { menu.addItem(.separator()) }
                menu.addItem(.sectionHeader(title: section))
            }
            let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == checked ? .on : .off
            menu.addItem(item)
        }
        // Just below the capsule's leading edge (the anchor view is not flipped).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        // Tracking is synchronous and a pick has run by now. Kept, the callback would hold the control (and
        // through it this anchor) after Settings closes.
        self.pick = nil
    }

    @objc private func chosen(_ item: NSMenuItem) { pick?(item.tag) }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
