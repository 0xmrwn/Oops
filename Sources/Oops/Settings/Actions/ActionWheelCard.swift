import AppKit
import OopsCore
import SwiftUI

extension ActionPlace {
    /// The arrow pointing at this place.
    var arrow: String {
        switch self {
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .upRight: "arrow.up.right"
        case .downRight: "arrow.down.right"
        case .downLeft: "arrow.down.left"
        case .upLeft: "arrow.up.left"
        }
    }

    var name: String {
        switch self {
        case .up: "Up"
        case .right: "Right"
        case .down: "Down"
        case .left: "Left"
        case .upRight: "Up-right"
        case .downRight: "Down-right"
        case .downLeft: "Down-left"
        case .upLeft: "Up-left"
        }
    }

    /// -1, 0 or 1 across and down (y grows downwards).
    var step: (x: CGFloat, y: CGFloat) {
        switch self {
        case .up: (0, -1)
        case .right: (1, 0)
        case .down: (0, 1)
        case .left: (-1, 0)
        case .upRight: (1, -1)
        case .downRight: (1, 1)
        case .downLeft: (-1, 1)
        case .upLeft: (-1, -1)
        }
    }
}

/// The wheel as the place actions are arranged: the drop, its eight arrows and a slot at each. A filled slot opens its
/// action or is dragged onto another (they swap); a free one starts an action there. The centre opens Runs with for
/// an instruction typed in the wheel.
struct ActionWheelCard: View {
    let library: ActionLibraryModel
    let navigation: ActionsNavigation
    /// The pointer, for the drop's eyes.
    let spare: SpareSpaceModel
    let store: ProviderStore
    @State private var dragging: UUID?
    @State private var translation = CGSize.zero
    @State private var target: ActionPlace?
    /// A drag just ended on this action: the click that ends it opens nothing.
    @State private var dragged = false
    /// Where the press that started the drag was, in screen points.
    @State private var pressedAt: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 340
    /// Where a slot's icon sits, from the drop's centre.
    static func anchor(_ place: ActionPlace) -> CGSize {
        let step = place.step
        if place.isDiagonal { return CGSize(width: step.x * 108, height: step.y * 78) }
        return CGSize(width: step.x * 128, height: step.y * 138)
    }

    private var actions: [Action] { library.library.actions }
    /// How a typed instruction runs, as the centre's tooltip and VoiceOver value say it.
    private var typedSummary: String { store.runsWithSummary(library.library.typed) }

    var body: some View {
        ZStack {
            ForEach(ActionPlace.allCases, id: \.self) { place in
                let reach = Self.anchor(place), length = hypot(reach.width, reach.height)
                Image(systemName: place.arrow).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.primary.opacity(actions.contains { $0.place == place } ? 0.7 : 0.28))
                    .offset(x: reach.width / length * 44, y: reach.height / length * 44)
                    .accessibilityHidden(true)
            }
            TypedCentre(spare: spare, summary: typedSummary) { navigation.openRunsWith(.typed) }
            let held = actions.first { $0.id == dragging }
            ForEach(ActionPlace.allCases.filter { place in !actions.contains { $0.place == place } }, id: \.self) { place in
                EmptySlot(place: place, targeted: target == place && dragging != nil, held: held) { navigation.add(at: place) }
                    .offset(Self.anchor(place))
            }
            ForEach(actions) { action in
                pill(action)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wheel")
        #if DEBUG
            .onAppear(perform: previewHeld)
        #endif
    }

    /// A pill sits on its slot by its icon's centre, its name on the outer side.
    static func alignment(_ side: CGFloat) -> Alignment { side > 0 ? .leading : side < 0 ? .trailing : .center }
    static func iconOffset(_ side: CGFloat) -> CGFloat { side > 0 ? -20 : side < 0 ? 20 : 0 }

    /// A pill's content; a free slot lays it out hidden to outline the held pill at its own size.
    static func label(_ action: Action, side: CGFloat) -> some View {
        HStack(spacing: 6) {
            if side < 0 { name(action) }
            Image(systemName: action.symbol).font(.system(size: 15, weight: .medium)).frame(width: 24)
            if side >= 0 { name(action) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }

    private func pill(_ action: Action) -> some View {
        let side = action.place.step.x
        let held = dragging == action.id
        let swapping = target == action.place && dragging != nil && !held
        return Color.clear.frame(width: 0, height: 0)
            .overlay(alignment: Self.alignment(side)) {
                Button {
                    if dragged { dragged = false } else { navigation.edit(action.id) }
                } label: {
                    Self.label(action, side: side).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEdge(Capsule(), outside: true)
                .overlay { if swapping { Capsule().inset(by: -3).strokeBorder(.primary.opacity(0.45), lineWidth: 1.5) } }
                .fixedSize()
                // The icon's centre, not the pill's edge, sits on the slot.
                .offset(x: Self.iconOffset(side))
                .help("\(action.title) · \(action.place.name)")
                .accessibilityLabel(action.title)
                .accessibilityValue(action.place.name)
                // Dragging is the pointer's way to move a pill; these are everyone else's.
                .accessibilityActions {
                    ForEach(ActionPlace.allCases.filter { $0 != action.place }, id: \.self) { place in
                        Button("Move to \(place.name)") { library.move(action.id, to: place) }
                    }
                }
                .simultaneousGesture(drag(action))
            }
            .offset(Self.anchor(action.place))
            .offset(held ? translation : .zero)
            .zIndex(held ? 2 : 1)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.22), value: action.place)
    }

    private static func name(_ action: Action) -> some View {
        Text(action.title).font(.system(size: 13, weight: .medium)).lineLimit(1).frame(maxWidth: 112)
            .fixedSize().foregroundStyle(.primary.opacity(action.name.isEmpty ? 0.6 : 1))
    }

    private func drag(_ action: Action) -> some Gesture {
        // Measured in the window: the pill's own space moves with the offset this drag sets, so each change would come
        // back short by the last one and the pill would jump back and forth.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragging == nil {
                    pressedAt = CGPoint(x: NSEvent.mouseLocation.x - value.translation.width, y: NSEvent.mouseLocation.y + value.translation.height)
                }
                dragging = action.id
                translation = value.translation
                let anchor = Self.anchor(action.place)
                let point = CGSize(width: anchor.width + value.translation.width, height: anchor.height + value.translation.height)
                target = ActionPlace.allCases.min { distance($0, point) < distance($1, point) }
            }
            .onEnded { value in
                dragged = true
                // Where the pointer let go, not where the gesture's last change left it: a quick drag's release came
                // with half its travel.
                let anchor = Self.anchor(action.place), mouse = NSEvent.mouseLocation
                let moved = pressedAt.map { CGSize(width: mouse.x - $0.x, height: $0.y - mouse.y) } ?? value.translation
                let point = CGSize(width: anchor.width + moved.width, height: anchor.height + moved.height)
                let destination = ActionPlace.allCases.min { distance($0, point) < distance($1, point) }
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.22)) {
                    if let destination { library.move(action.id, to: destination) }
                    dragging = nil; translation = .zero; target = nil
                }
                // The click that a drag's release can deliver arrives at once or not at all.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dragged = false }
            }
    }

    private func distance(_ place: ActionPlace, _ point: CGSize) -> CGFloat {
        let anchor = Self.anchor(place)
        return hypot(anchor.width - point.width, anchor.height - point.height)
    }

    #if DEBUG
    /// `-SettingsPreviewActionPage held`: the first action held as a drag holds it, under the longest name, over the
    /// first free slot, for captures without a pointer. Only the in-memory preview library is renamed.
    private func previewHeld() {
        guard DebugFlags.settingsActionPage == "held", DebugFlags.actionsPreview, let action = actions.first else { return }
        library.update(action.id) { $0.name = "Rewrite as a friendly reply to the whole team" }
        dragging = action.id
        target = ActionPlace.allCases.first { place in !actions.contains { $0.place == place } }
        // Most of the way there, as a drag would have it when that slot is the nearest.
        if let target {
            let from = Self.anchor(action.place), to = Self.anchor(target)
            translation = CGSize(width: (to.width - from.width) * 0.8, height: (to.height - from.height) * 0.8)
        }
    }
    #endif
}

/// The wheel's centre, where an instruction is typed when the wheel is open: opens how such an instruction runs.
private struct TypedCentre: View {
    let spare: SpareSpaceModel
    let summary: String
    let open: () -> Void

    var body: some View {
        ZStack {
            // The eyes blink on a tap of their own, which would swallow the click: the button's shape takes it.
            Button(action: open) {
                WatchingEyes(model: spare, height: 52, visible: true).allowsHitTesting(false)
                    .overlay(Color.clear.contentShape(Circle()))
            }
                .buttonStyle(.plain).frame(width: 52, height: 52)
                // Clear glass, as on the real wheel, shows nothing over Settings' plain light page: the edge gives it its shape.
                .glassEdge(Circle(), outside: true)
            Button(action: open) {
                Label("Typed instruction", systemImage: "character.cursor.ibeam").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.settingsGlass).controlSize(.small)
            .offset(y: 80)
        }
        .help("How an instruction typed in the wheel runs · \(summary)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Typed instruction")
        .accessibilityValue(summary)
        .accessibilityHint("Opens Runs with")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}

/// A free place on the wheel. While an action is held it outlines that pill where it would land here.
private struct EmptySlot: View {
    let place: ActionPlace
    let targeted: Bool
    let held: Action?
    let add: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = place.step.x, outlined = held != nil
        // A 36 pt capsule is the resting circle, so the slot grows into the outline instead of swapping shapes.
        Color.clear.frame(width: 0, height: 0)
            .overlay(alignment: outlined ? ActionWheelCard.alignment(side) : .center) {
                Button(action: add) {
                    ZStack {
                        if let held { ActionWheelCard.label(held, side: side).hidden() }
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary.opacity(hovering || targeted ? 0.85 : 0.45))
                            .opacity(outlined ? 0 : 1)
                    }
                    .frame(width: outlined ? nil : 36, height: outlined ? nil : 36)
                    .background(Capsule().fill(.primary.opacity(hovering || targeted ? 0.08 : 0)))
                    .overlay(Capsule().strokeBorder(.primary.opacity(targeted ? 0.5 : hovering ? 0.3 : 0.18), style: StrokeStyle(lineWidth: 1, dash: targeted ? [] : [3, 3])))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .offset(x: outlined ? ActionWheelCard.iconOffset(side) : 0)
                // Reduce Motion fades the circle into the outline rather than growing it.
                .id(reduceMotion && outlined)
                .transition(.opacity)
                // A drag's pointer passes over free slots: they neither highlight nor start an action until it ends.
                .allowsHitTesting(!outlined)
                .onHover { hovering = $0 }
                .help("Add an action · \(place.name)")
                .accessibilityLabel("Add action")
                .accessibilityValue(place.name)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.22), value: outlined)
    }
}
