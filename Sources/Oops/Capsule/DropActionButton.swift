import SwiftUI

/// A drop's one action: centred in the drop's trailing cap as Fix's eyes are in the leading one, on a glass disc
/// concentric with the cap (7 pt of rim all round), so it reads as something to press rather than a status glyph.
/// The disc is the button's own surface, not a plate under text. Fix's drop and the dictation drop share it.
struct DropActionButton: View {
    let symbol: String
    let label: String
    var scale: CGFloat = 1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13 * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32 * scale, height: 32 * scale)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: EyesDropView.drop * scale, height: EyesDropView.drop * scale)
        .accessibilityLabel(label)
    }
}
