import OopsCore
import SwiftUI

/// Dotted step slider: one dot per supported effort, a white knob and a monochrome filled track up
/// to it, thicker than the empty part so the level reads at a glance.
/// Click or drag to choose; the parent handles arrow keys while it is focused.
struct EffortSlider: View {
    let efforts: [CatalogModel.Effort]
    let selection: String
    let focused: Bool
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private let knob: CGFloat = 18
    /// How far track and fill extend past the end stops.
    private static let overhang: CGFloat = 6

    var body: some View {
        let index = efforts.firstIndex { $0.id == selection } ?? 0
        GeometryReader { geometry in
            let width = geometry.size.width - knob
            let x = { (i: Int) -> CGFloat in
                knob / 2 + (efforts.count > 1 ? width * CGFloat(i) / CGFloat(efforts.count - 1) : width / 2)
            }
            let mid = geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                // Track and fill run a little past the first and last stops, so the end dots sit
                // inside the rounded caps; both start at the same point, the fill thicker.
                let start = x(0) - Self.overhang, end = x(efforts.count - 1) + Self.overhang
                Capsule().fill(.primary.opacity(0.14))
                    .frame(width: end - start, height: 5)
                    .position(x: (start + end) / 2, y: mid)
                Capsule().fill(.primary.opacity(0.7))
                    .frame(width: x(index) - start, height: 7)
                    .position(x: start + (x(index) - start) / 2, y: mid)
                ForEach(efforts.indices, id: \.self) { i in
                    // On the filled part the dots take the opposite tone, so they stay visible.
                    Circle()
                        .fill(i <= index ? (colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.9))
                                         : Color.primary.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .position(x: x(i), y: mid)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    // A firmer edge: in dark mode the knob sits on a near-white fill.
                    .overlay(Circle().strokeBorder(.black.opacity(0.2)))
                    .frame(width: knob, height: knob)
                    .overlay {
                        if focused {
                            Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 3).padding(-4)
                        }
                    }
                    .position(x: x(index), y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard efforts.count > 1 else { return }
                let raw = (value.location.x - knob / 2) / max(width, 1) * CGFloat(efforts.count - 1)
                let nearest = min(max(Int(raw.rounded()), 0), efforts.count - 1)
                if efforts[nearest].id != selection { select(efforts[nearest].id) }
            })
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15), value: index)
        }
        .frame(height: 26)
        .help(efforts.indices.contains(index) ? efforts[index].description : "")
        .accessibilityElement()
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(ModelSelection.effortName(selection))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if efforts.indices.contains(next) { select(efforts[next].id) }
        }
    }
}
