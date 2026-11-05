import AppKit
import Combine
import SwiftUI

/// The app's state behind a SwiftUI editor: what its text() reports.
@MainActor final class DraftModel: ObservableObject {
    @Published var text: String
    @Published var rich: AttributedString
    @Published var generation = 0
    init(text: String, rich: AttributedString) { self.text = text; self.rich = rich }
}

struct SwiftUIRoot: View {
    @ObservedObject var model: DraftModel
    let toolkit: String, fontSize: CGFloat, rtl: Bool

    var body: some View {
        Group {
            switch toolkit {
            case "swiftui-field": TextField("Message", text: $model.text, axis: .vertical).textFieldStyle(.plain)
            case "swiftui-rich": TextEditor(text: $model.rich)
            default: TextEditor(text: $model.text)
            }
        }
        .font(.system(size: fontSize))
        .scrollContentBackground(.hidden)
        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        .accessibilityLabel("Message")
        .id(model.generation)
    }
}

/// SwiftUI's TextEditor (NSTextView underneath), TextField with a vertical axis (a chat composer that
/// grows) and TextEditor on an AttributedString (macOS 26), where mentions are tinted runs.
@MainActor final class SwiftUIEditor: Editor {
    let view: NSView
    let model: DraftModel
    let rich: Bool
    var onChange: (() -> Void)?
    private var sinks: Set<AnyCancellable> = []

    init(_ spec: Case) {
        var attributed = AttributedString()
        for (index, paragraph) in spec.paragraphs.enumerated() {
            if index > 0 { attributed += AttributedString("\n") }
            for segment in paragraph {
                var piece = AttributedString(segment.label)
                if segment.mention != nil { piece.foregroundColor = Color.blue }
                attributed += piece
            }
        }
        model = DraftModel(text: spec.text, rich: attributed)
        rich = spec.toolkit == "swiftui-rich"
        view = NSHostingView(rootView: SwiftUIRoot(model: model, toolkit: spec.toolkit, fontSize: spec.fontSize, rtl: spec.rtl))
        // Only edits count: TextEditor also writes the binding back when the selection moves.
        var last = rich ? String(attributed.characters) : spec.text
        let changed = { [weak self] (text: String) in
            guard text != last else { return }
            last = text
            DispatchQueue.main.async { self?.onChange?() }
        }
        model.$text.dropFirst().sink { changed($0) }.store(in: &sinks)
        model.$rich.dropFirst().sink { changed(String($0.characters)) }.store(in: &sinks)
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    /// The NSTextView that edits: the TextEditor's own, or the window's field editor for a TextField.
    private var textView: NSTextView? {
        if let field = find(NSTextField.self, in: view) { return field.currentEditor() as? NSTextView }
        return find(NSTextView.self, in: view)
    }

    func text() -> String { rich ? String(model.rich.characters) : model.text }
    func counts() -> [String: Int] { ["chips": 0, "images": 0] }

    func focus() {
        if let field = find(NSTextField.self, in: view) { view.window?.makeFirstResponder(field) }
        else if let text = find(NSTextView.self, in: view) { view.window?.makeFirstResponder(text) }
    }

    func select(_ start: Int, _ end: Int) { textView?.setSelectedRange(NSRange(location: start, length: end - start)) }

    func caret() -> Int? {
        guard let range = textView?.selectedRange(), range.length == 0 else { return nil }
        return range.location
    }

    func insert(_ string: String) {
        guard let textView else { return }
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    /// A new identity for the view: SwiftUI builds a new text view, as a re-keyed view does.
    func rerender() {
        let range = textView?.selectedRange()
        model.generation += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            focus()
            if let range { textView?.setSelectedRange(range) }
        }
    }
}
