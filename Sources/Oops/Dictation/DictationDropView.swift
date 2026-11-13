import AppKit
import SwiftUI

/// The dictation drop: Fix's clear glass capsule at its height, holding one symbol and a word or two in the
/// drop's type, with the same halo instead of a backing shape. It enters and leaves as Fix's drop does, on
/// the panel's `presented`, and has nothing to press.
struct DictationDropView: View {
    let model: DictationDropModel
    /// The panel's model, read only for the entrance, the corner and the drop's width.
    @ObservedObject var capsule: CapsuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private static let symbolWidth: CGFloat = 18, spacing: CGFloat = 7, padding: CGFloat = 16

    private var increasedContrast: Bool { contrast == .increased }
    private var ink: Color { scheme == .dark ? .white : Color(red: 0.06, green: 0.06, blue: 0.09) }
    private var halo: Color { increasedContrast ? .clear : (scheme == .dark ? Color.black : .white).opacity(0.85) }

    /// Computed rather than measured, so the glass and the pointer's hold area agree.
    private var width: CGFloat {
        let text = (model.state.text as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up)
        return Self.padding * 2 + Self.symbolWidth + Self.spacing + text
    }

    var body: some View {
        let height = EyesDropView.drop, width = width
        ZStack {
            if reduceTransparency { Capsule().fill(.background) }
            GlassEffectContainer {
                Color.clear.glassEffect(.clear, in: .capsule)
            }
            HStack(spacing: Self.spacing) {
                Image(systemName: model.state.symbol).font(.system(size: 13, weight: .semibold))
                    .frame(width: Self.symbolWidth).contentTransition(.symbolEffect(.replace))
                Text(model.state.text).font(Font(Self.font)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(ink)
            .modifier(Halo(color: halo))
        }
        .frame(width: width, height: height)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.12), value: model.state)
        .scaleEffect(capsule.presented ? 1 : 0.35)
        .opacity(capsule.presented ? 1 : 0)
        .padding(14)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : capsule.presented ? .spring(duration: 0.45, bounce: 0.3) : .easeIn(duration: 0.22),
                   value: capsule.presented)
        .onAppear { capsule.width = width }
        .onChange(of: model.state) { capsule.width = self.width }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state.text)
        .accessibilityHidden(!capsule.presented)
    }
}
