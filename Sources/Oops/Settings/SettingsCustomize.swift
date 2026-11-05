import OopsCore
import SwiftUI

/// What gets fixed and how: the rules half of the system prompt. The output instruction is shown
/// under them, locked, so a custom prompt changes what gets fixed, never whether Oops can read
/// the answer; showing it also keeps people from adding it again themselves.
struct CustomizePage: View {
    @State private var draft = CorrectionPolicy.rules
    @State private var saved = CorrectionPolicy.rules

    private var custom: Bool { saved != CorrectionPolicy.defaultRules }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Correction rules").font(.headline)
                InfoTip("The system prompt Oops sends to the model with every fix.")
                Spacer()
                if custom {
                    Text("Custom").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.primary.opacity(0.1), in: .capsule)
                }
            }
            // The editable rules, then the fixed instruction in the same box: one prompt, read top
            // to bottom.
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 220)
                    .accessibilityLabel("Correction rules")
                Divider()
                Label(CorrectionPolicy.contract, systemImage: "lock.fill")
                    .font(.system(size: 11.5, design: .monospaced)).secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .help("Always added after your rules: Oops reads the answer in this shape")
            }
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
            // Read last, right before Save.
            Label("These rules apply to every fix. Rules that ask for more than fixing mistakes can rewrite your drafts.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .secondaryText()
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { draft = CorrectionPolicy.defaultRules; save() } label: {
                    Label("Restore default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .disabled(!custom && trimmed == CorrectionPolicy.defaultRules)
                Spacer()
                Button("Revert") { draft = saved }.buttonStyle(.glass).disabled(draft == saved)
                Button("Save", action: save)
                    .buttonStyle(.glassProminent).tint(.accentColor)
                    .disabled(draft == saved || trimmed.isEmpty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .settingsSurface()
    }

    private func save() {
        let rules = trimmed
        if rules == CorrectionPolicy.defaultRules || rules.isEmpty {
            UserDefaults.standard.removeObject(forKey: CorrectionPolicy.customRulesKey)
        } else {
            UserDefaults.standard.set(rules, forKey: CorrectionPolicy.customRulesKey)
        }
        saved = CorrectionPolicy.rules; draft = saved
    }
}
