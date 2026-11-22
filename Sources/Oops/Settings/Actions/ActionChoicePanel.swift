import AppKit
import OopsCore
import SwiftUI

/// The choice panel's layer over the whole window: the panel under its pill, its arrow pointing up at it, kept inside
/// the window; a click anywhere else or Escape closes it. Drawn in the window rather than as a popover, which is a
/// window of its own: a popover centres on its arrow, so near either edge it hung out past the window or had to open
/// sideways over the header.
struct ChoicePanel: View {
    let navigation: ActionsNavigation
    @State private var monitor: Any?
    static let arrow: CGFloat = 9
    private static let margin: CGFloat = 12

    var body: some View {
        if let request = navigation.choice, let id = navigation.editing {
            let size = ChoicePopover.size
            let below = request.anchor.maxY + Self.arrow + size.height + Self.margin <= request.bounds.height
            let x = min(max(request.anchor.midX - size.width / 2, Self.margin), request.bounds.width - Self.margin - size.width)
            let y = below ? request.anchor.maxY + 2 : request.anchor.minY - 2 - Self.arrow - size.height
            let tip = min(max(request.anchor.midX - x, 26), size.width - 26)
            let shape = PanelShape(tip: tip, up: below, arrow: Self.arrow)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                ChoicePopover(library: navigation.library, id: id, naming: request.naming) { close() }
                    .padding(.top, below ? Self.arrow : 0).padding(.bottom, below ? 0 : Self.arrow)
                    .glassEffect(.regular, in: shape)
                    .background { shape.fill(.black.opacity(0.001)).shadow(color: .black.opacity(0.22), radius: 22, y: 8) }
                    .contentShape(shape)
                    .offset(x: x, y: y)
                    .transition(.scale(scale: 0.96, anchor: UnitPoint(x: tip / size.width, y: below ? 0 : 1)).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Choice")
            }
            .onAppear(perform: listen)
            .onDisappear(perform: stopListening)
            .onReceive(NotificationCenter.default.publisher(for: .settingsPageWillChange)) { _ in navigation.choice = nil }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.12)) { navigation.choice = nil }
    }

    /// Escape closes the panel, wherever focus is.
    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, navigation.choice != nil else { return event }
            close()
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A rounded panel with an arrow at `tip`, on its top edge or its bottom one.
private struct PanelShape: InsettableShape {
    var tip: CGFloat
    var up: Bool
    var arrow: CGFloat
    var inset: CGFloat = 0

    /// One outline, the arrow part of the edge, so the glass draws no seam where they meet.
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let top = up ? r.minY + arrow : r.minY, bottom = up ? r.maxY : r.maxY - arrow
        let radius: CGFloat = 20, half: CGFloat = 11
        let x = min(max(tip, r.minX + radius + half), r.maxX - radius - half)
        var path = Path()
        path.move(to: CGPoint(x: r.minX + radius, y: top))
        if up {
            path.addLine(to: CGPoint(x: x - half, y: top))
            path.addCurve(to: CGPoint(x: x, y: r.minY), control1: CGPoint(x: x - half / 2, y: top), control2: CGPoint(x: x - 2.5, y: r.minY))
            path.addCurve(to: CGPoint(x: x + half, y: top), control1: CGPoint(x: x + 2.5, y: r.minY), control2: CGPoint(x: x + half / 2, y: top))
        }
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom), tangent2End: CGPoint(x: r.minX, y: bottom), radius: radius)
        if !up {
            path.addLine(to: CGPoint(x: x + half, y: bottom))
            path.addCurve(to: CGPoint(x: x, y: r.maxY), control1: CGPoint(x: x + half / 2, y: bottom), control2: CGPoint(x: x + 2.5, y: r.maxY))
            path.addCurve(to: CGPoint(x: x - half, y: bottom), control1: CGPoint(x: x - 2.5, y: r.maxY), control2: CGPoint(x: x - half / 2, y: bottom))
        }
        path.addArc(tangent1End: CGPoint(x: r.minX, y: bottom), tangent2End: CGPoint(x: r.minX, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.maxX, y: top), radius: radius)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> PanelShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
