import AppKit
import OopsCore
import SwiftUI

/// The choice's setup: its name (the pill's label), then its values where they will sit on the second ring when the
/// action runs, each edited in place. The next place to fill is the one live "+"; the later ones wait as dots.
struct ChoicePopover: View {
    let library: ActionLibraryModel
    let id: UUID
    /// Just inserted: the name takes the caret, the person having asked for the choice.
    var naming = false
    let close: () -> Void
    @State private var typing: ActionPlace?
    @FocusState private var focus: Field?

    enum Field: Hashable { case name, value(ActionPlace) }

    /// The ring's places sit on one circle; side values grow outwards from theirs, top and bottom ones stay centred.
    static let radius: CGFloat = 108
    static let widest: CGFloat = 132
    static let place: CGFloat = 26
    static let ring = CGSize(width: 2 * (radius - place / 2 + widest + 6), height: 2 * radius + place + 4)
    static let size = CGSize(width: ring.width + 32, height: ring.height + 32 + 32 + 12 + ChoicePanel.arrow)

    private var action: Action { library.action(id) ?? .blank(at: .up) }
    private var choice: ActionChoice { action.choice ?? .empty }

    private var name: Binding<String> {
        Binding(get: { choice.name }, set: { value in library.update(id) { $0.choice = ($0.choice ?? .empty).renamed(value) } })
    }

    private func value(_ place: ActionPlace) -> Binding<String> {
        Binding(get: { choice.values[place] ?? "" }, set: { value in
            library.update(id) { $0.choice = ($0.choice ?? .empty).setting(value, at: place) }
        })
    }

    private func isEmpty(_ place: ActionPlace) -> Bool { (choice.values[place] ?? "").isEmpty }

    /// The next free place, in the order places fill: up, right, down, left, then the diagonals.
    private var next: ActionPlace? { choice.nextEmpty(skipping: typing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ChoiceNameField(text: name, focus: $focus) { advance() }.frame(width: 200)
                InfoTip("Any other value can be typed when the action runs.")
                Spacer(minLength: 8)
                Button {
                    close()
                    library.update(id) {
                        $0.instruction = ActionInstruction.removingChoice(from: $0.instruction)
                        $0.choice = nil
                    }
                } label: { Label("Remove choice", systemImage: "trash") }
                    .buttonStyle(.settingsGlass)
            }
            ring.frame(width: Self.ring.width, height: Self.ring.height)
        }
        .padding(16)
        .frame(width: Self.size.width, alignment: .leading)
        .onAppear {
            guard naming else { return }
            place(.name)
        }
        .onChange(of: focus) { old, new in
            // A place left goes back to a label, or to its "+" when it was left empty.
            if case .value(let place) = old, place == typing, new != old { typing = nil }
        }
        .animation(.easeOut(duration: 0.15), value: choice.values)
        .animation(.easeOut(duration: 0.15), value: typing)
    }

    // MARK: The ring

    private static func point(_ place: ActionPlace) -> CGSize {
        let step = place.step, length = hypot(step.x, step.y)
        return CGSize(width: step.x / length * radius, height: step.y / length * radius)
    }

    private var ring: some View {
        ZStack {
            ForEach(ActionPlace.allCases, id: \.self) { place in
                let to = Self.point(place)
                Image(systemName: place.arrow).font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary.opacity(isEmpty(place) ? 0.28 : 0.7))
                    .offset(x: to.width * 0.34, y: to.height * 0.34)
                    .accessibilityHidden(true)
            }
            Image(systemName: action.symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 40, height: 40)
                .glassEffect(.clear, in: .circle).glassEdge(Circle(), outside: true)
                .accessibilityHidden(true)
            ForEach(ActionPlace.allCases, id: \.self) { place in
                let side = place.step.x
                // The place's own square stays put; a value grows out of it, away from the centre.
                Color.clear.frame(width: Self.place, height: Self.place)
                    .overlay(alignment: side > 0 ? .leading : side < 0 ? .trailing : .center) { cell(place).fixedSize() }
                    .offset(Self.point(place))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Values")
    }

    @ViewBuilder private func cell(_ place: ActionPlace) -> some View {
        if !isEmpty(place) || typing == place {
            ChoiceValueField(place: place, text: value(place), focus: $focus, active: typing == place, submit: advance, edit: { open(place) }) {
                value(place).wrappedValue = ""
                if typing == place { typing = nil }
            }
            .transition(.opacity)
        } else {
            let live = place == next
            Button { open(place) } label: {
                ZStack {
                    if live {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary.opacity(0.6))
                        Circle().strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else {
                        Circle().fill(.primary.opacity(0.32)).frame(width: 5, height: 5)
                    }
                }
                .frame(width: Self.place, height: Self.place)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Add a value · \(place.name)")
            .accessibilityLabel("Add value")
            .accessibilityValue(place.name)
            .transition(.opacity)
        }
    }

    /// Focus the code places, after the person's own click or key: the window lets it through only so.
    private func place(_ field: Field) {
        FocusRingsWindow.placing = true
        DispatchQueue.main.async {
            focus = field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { FocusRingsWindow.placing = false }
        }
    }

    private func open(_ place: ActionPlace) {
        typing = place
        self.place(.value(place))
        // A value clicked to edit gets the caret at its end, not its text selected to be typed over.
        guard !isEmpty(place) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
        }
    }

    /// Return or Tab: on to the next free place, or out of the fields when every place is filled.
    private func advance() {
        if case .value(let place) = focus, (choice.values[place] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            focus = nil
            return
        }
        let current: ActionPlace? = if case .value(let place) = focus { place } else { nil }
        if let next = choice.nextEmpty(skipping: current) { open(next); return }
        // Every place is filled: the last value is done.
        focus = nil
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

private extension ActionChoice {
    func renamed(_ name: String) -> ActionChoice {
        var choice = self
        choice.name = name
        return choice
    }
}

/// The choice's name, as Settings' text well, but with its focus in the panel's hands.
private struct ChoiceNameField: View {
    @Binding var text: String
    var focus: FocusState<ChoicePopover.Field?>.Binding
    let submit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let marked = focus.wrappedValue == .name && FocusRings.shared.shown
        let resting = contrast == .increased ? 0.4 : colorScheme == .dark ? 0.14 : 0.22
        TextField("Name", text: $text, prompt: Text("Name")).textFieldStyle(.plain).focused(focus, equals: .name)
            .onSubmit(submit)
            .onKeyPress(.tab) { submit(); return .handled }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(marked ? 0.75 : resting), lineWidth: marked ? 1.5 : 1))
            .accessibilityLabel("Name")
    }
}

/// One value on the ring: the wheel's glass capsule, its text editable where it sits, and a way to remove it. Past the
/// widest a value scrolls in its field, and its tooltip shows it whole.
private struct ChoiceValueField: View {
    let place: ActionPlace
    @Binding var text: String
    var focus: FocusState<ChoicePopover.Field?>.Binding
    /// Opened for typing: a field even before it has the keyboard.
    let active: Bool
    let submit: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        let marked = focus.wrappedValue == .value(place) && FocusRings.shared.shown
        let editing = active || focus.wrappedValue == .value(place)
        HStack(spacing: 2) {
            Text(text.isEmpty ? "Value" : text).font(.system(size: 13, weight: .medium)).lineLimit(1).hidden()
                .frame(minWidth: 44, maxWidth: ChoicePopover.widest - 34, alignment: .leading)
                .overlay(alignment: .leading) {
                    // Edited as a field, read as a label: the label truncates a long value, and no field is left
                    // drawing a selection it no longer has.
                    if editing || text.isEmpty {
                        TextField("Value", text: $text, prompt: Text("Value")).textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium)).focused(focus, equals: .value(place)).onSubmit(submit)
                            .onKeyPress(.tab) { submit(); return .handled }
                            .accessibilityLabel("Value \(place.name)")
                    } else {
                        Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: edit)
                            .pointerStyle(.horizontalText)
                            .accessibilityLabel("Value \(place.name)")
                            .accessibilityValue(text)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction(.default, edit)
                    }
                }
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).secondaryText()
                    .frame(width: 16, height: 16).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel(text.isEmpty ? "Remove" : "Remove \(text)")
        }
        .padding(.leading, 11).padding(.trailing, 5)
        .frame(height: ChoicePopover.place)
        .glassEffect(.regular, in: .capsule)
        .glassEdge(Capsule(), outside: true)
        .overlay { if marked { Capsule().strokeBorder(.primary.opacity(0.75), lineWidth: 1.5) } }
        .help(text.count > 14 ? text : "")
    }
}
