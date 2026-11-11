import AppKit
import SwiftUI

/// Two or three choices in a row, in the tab bar's language: a faint capsule track with one glass pill that
/// slides to the chosen one.
struct GlassChoice<Value: Hashable>: View {
    let title: String
    let choices: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var pill
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.value) { choice in
                let selected = choice.value == selection
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0.15)) { selection = choice.value }
                } label: {
                    Text(choice.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary.opacity(selected ? 1 : 0.68))
                        .padding(.horizontal, 12).frame(minHeight: 26)
                        .background {
                            if selected {
                                Capsule().fill(.clear)
                                    .glassEffect(.regular.interactive(enabled), in: .capsule)
                                    .glassEdge(Capsule(), outside: true)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
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

/// A choice from a list, as a glass capsule showing the current value, like the model picker. It is a glass
/// button that opens a native menu below itself: SwiftUI's `Menu` drops the glass style on macOS and puts
/// the label's chevron first.
struct GlassMenu<Value: Hashable>: View {
    let title: String
    let choices: [(value: Value, label: String)]
    @Binding var selection: Value
    @State private var anchor = MenuAnchor()

    var body: some View {
        let current = choices.firstIndex { $0.value == selection }
        Button {
            anchor.popUp(choices.map(\.label), checked: current) { selection = choices[$0].value }
        } label: {
            HStack(spacing: 6) {
                Text(current.map { choices[$0].label } ?? "").fontWeight(.medium)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.settingsGlass)
        .controlSize(.large)
        .fixedSize()
        .background { MenuAnchorView(anchor: anchor) }
        .accessibilityLabel(title)
        .accessibilityValue(current.map { choices[$0].label } ?? "")
    }
}

/// Where a `GlassMenu` opens its menu, and what a pick does.
@MainActor final class MenuAnchor: NSObject {
    fileprivate weak var view: NSView?
    private var pick: ((Int) -> Void)?

    func popUp(_ titles: [String], checked: Int?, pick: @escaping (Int) -> Void) {
        guard let view else { return }
        self.pick = pick
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
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
