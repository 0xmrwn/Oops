import Foundation

/// A code editor's input surface can have a full-size Accessibility frame while its text and
/// selection still belong to the editor's separate model. Treat it like a geometrically hidden proxy.
public enum InputProxy {
    public static func matches(classes: [String], ancestors: [[String]], roleDescription: String? = nil, ancestorSubroles: [String] = []) -> Bool {
        classes.contains("inputarea") && ancestors.contains { $0.contains("monaco-editor") }
            || roleDescription == "editor" && ancestorSubroles.contains("AXCodeStyleGroup")
    }
}
