#if DEBUG
import AppKit
import OopsCore
import SwiftUI

/// Debug builds only: `-SetupSnapshots <dir>` renders the setup steps' moments to PNGs offscreen over
/// Hello's wallpaper and exits, like `HelloSnapshots`, so the steps can be checked without taking the
/// screen. Each moment is drawn at the largest window and at a 1280×800 MacBook Air's, in a folder per
/// width. Glass renders flat here; motion and glass are for a real run.
@MainActor enum SetupSnapshots {
    private static let sizes = [CGSize(width: 1080, height: 675), CGSize(width: 992, height: 620)]

    static func render(to directory: URL) {
        // The first dozen or so renders after launch come out without glass or glass buttons, however
        // long the wait: the second pass overwrites them.
        writeHelper(to: directory)
        for _ in 0..<2 {
            for size in sizes {
                let folder = directory.appendingPathComponent("\(Int(size.width))")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                render(to: folder, size: size)
            }
        }
    }

    private static func render(to directory: URL, size: CGSize) {
        guard let wallpaper = GradientSnapshots.frame(time: 2.5)?.cgImage,
              let fixText = ShortcutSettings.shared.defaultShortcut(.correct) else { return print("No wallpaper or default") }
        let hyper = Shortcut(keyCode: fixText.keyCode, modifiers: Shortcut.hyper)
        let moments: [(String, (ShortcutStep) -> Void)] = [
            ("1-waiting", { $0.seed(fixText, phase: .waiting) }),
            ("2-holding", { $0.seed(fixText, phase: .waiting, held: [.control]) }),
            ("3-pressed", { $0.seed(fixText, phase: .accepted, held: [.control, .command], key: UInt16(fixText.keyCode), glow: 1) }),
            ("4-accepted", { $0.seed(fixText, phase: .accepted, glow: 0.3) }),
            ("5-recording", { $0.seed(fixText, phase: .recording) }),
            ("6-recording-held", { $0.seed(fixText, phase: .recording, held: [.option]) }),
            ("7-hyper", { $0.seed(hyper, phase: .accepted, glow: 0.3) }),
            ("8-taken", { $0.seed(fixText, phase: .recording, error: "That shortcut is already used by Restore original.") }),
            ("9-hyper-waiting", { $0.seed(hyper, phase: .waiting) }),
            ("10-hyper-half", { $0.seed(hyper, phase: .waiting, held: [.control, .shift]) }),
            ("11-hyper-pressed", { $0.seed(hyper, phase: .waiting, held: [.control, .option, .shift, .command], key: UInt16(hyper.keyCode)) }),
            ("12-recording-hyper", { $0.seed(fixText, phase: .recording, held: [.control, .option, .shift, .command]) }),
        ]
        for (name, set) in moments {
            let step = ShortcutStep(saves: false)
            set(step)
            write(ShortcutStepView(step: step) {}, dot: 1, eyes: (step.look, step.lid, step.check), wallpaper: wallpaper, size: size,
                  to: directory.appendingPathComponent("shortcut-\(name).png"))
        }
        for (name, phase) in [("1-waiting", AccessibilityStep.Phase.waiting), ("2-in-settings", .inSettings), ("3-granted", .granted)] {
            let step = AccessibilityStep()
            step.seed(phase)
            write(AccessibilityStepView(step: step) {}, dot: 2, eyes: (step.look, step.lid, step.check), wallpaper: wallpaper, size: size,
                  to: directory.appendingPathComponent("accessibility-\(name).png"))
        }
        // Design pass: the fixed reply is illustrative here; the step shows the provider's own answer.
        let fixed = "that ramen place near your work? i can be there around 8, might be a few minutes late, my last meeting tends to run over"
        for (name, set) in [("1-ready", { (step: TryItStep) in step.seed(.ready) }),
                            ("2-fixed", { (step: TryItStep) in step.seed(.fixed(changes: 4, seconds: 1.4), text: fixed,
                                                                         flashed: ["your", "around", "minutes", "over"]) }),
                            ("3-replayed", { (step: TryItStep) in step.seed(.fixed(changes: 3, seconds: nil), live: false, text: HelloDraft.typed.after,
                                                                            flashed: ["running", "sorry", "seat"]) }),
                            ("4-partial", { (step: TryItStep) in step.seed(.ready); step.shortcuts.seed(fixText, phase: .accepted, held: [.control]) }),
                            ("5-hyper-half", { (step: TryItStep) in step.seed(.ready); step.shortcuts.seed(hyper, phase: .accepted, held: [.option, .command]) }),
                            ("6-hyper-pressed", { (step: TryItStep) in step.seed(.ready)
                                step.shortcuts.seed(hyper, phase: .accepted, held: [.control, .option, .shift, .command], key: UInt16(hyper.keyCode)) })] {
            let step = TryItStep(preferences: nil, shortcuts: ShortcutStep(saves: false))
            set(step)
            write(TryItStepView(step: step) {}, dot: 3, eyes: nil, wallpaper: wallpaper, size: size, to: directory.appendingPathComponent("try-\(name).png"))
        }
        for (name, eyes) in [("1-menu-bar", true), ("2-eyes-hidden", false)] {
            let step = HomeStep(saves: false)
            step.previewEyes = eyes
            write(HomeStepView(step: step), dot: 4, eyes: (step.look, 0, 0), wallpaper: wallpaper, size: size, to: directory.appendingPathComponent("home-\(name).png"))
        }
        writeProvider(to: directory, size: size, wallpaper: wallpaper)
    }

    private static func writeProvider(to directory: URL, size: CGSize, wallpaper: CGImage) {
        let two = ProviderFindings(claude: .signedOut, chatGPTSignedIn: true)
        let many = ProviderFindings(claude: .notInstalled, chatGPTSignedIn: true, local: ["lmstudio": .running([]), "ollama": .needsKey])
        let moments: [(String, ProviderFindings?, ProviderStep.Proof, String?)] = [
            ("1-proving", two, .running, nil),
            ("2-passed", two, .passed(ProviderStep.sampleFixed, seconds: 0.8), nil),
            ("3-many-passed", many, .passed(ProviderStep.sampleFixed, seconds: 0.8), nil),
            ("4-nothing", ProviderFindings(), .idle, nil),
            ("5-failed", two, .failed("ChatGPT didn't answer in time. Try again, or choose another provider."), nil),
            ("6-api-connect", two, .idle, "local"),
            ("7-api-models", two, .idle, "models"),
            ("8-api-passed", two, .idle, "passed"),
            ("9-api-failure", two, .idle, "failure"),
        ]
        for (name, found, proof, api) in moments {
            let step = ProviderStep(preferences: nil)
            if let found { step.seed(found, proof: proof) }
            if let api { step.showingAPI = true; step.api.seed(api) }
            write(ProviderStepView(step: step) {}, dot: 0, eyes: (step.look, step.lid, step.check), wallpaper: wallpaper, size: size,
                  to: directory.appendingPathComponent("provider-\(name).png"))
        }
    }

    /// The helper docked under a stand-in for System Settings' window, in both appearances. Glass
    /// draws nothing offscreen, so flat fills stand in for the accent capsule and the drop's bead.
    private static func writeHelper(to directory: URL) {
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let glass = ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.8)).frame(width: 350, height: 74)
                Circle().fill(.white.opacity(0.12)).frame(width: 54, height: 54).padding(.leading, 10)
            }
            let view = VStack(spacing: -6) {
                RoundedRectangle(cornerRadius: 16).fill(Color(white: scheme == .dark ? 0.2 : 0.96)).frame(width: 540, height: 150)
                AccessibilityHelperView(onBegin: {}, onEnd: {}, onClick: {}, arrived: true).frame(width: 400, height: 112)
                    .background { glass }
            }
            .frame(width: 600, height: 300)
            .background(Color(white: scheme == .dark ? 0.12 : 0.78))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("accessibility-helper-\(name).png"))
        }
    }

    private static func write(_ content: some View, dot: Int, eyes: (CGSize, Double, Double)?, wallpaper: CGImage, size: CGSize, to url: URL) {
        do {
            let view = ZStack {
                Image(decorative: wallpaper, scale: 1).resizable()
                content
                OnboardingProgress(steps: 5, current: dot).onboardingFooterRow(.center)
            }
            .overlayPreferenceValue(OnboardingDropKey.self) { anchors in
                GeometryReader { proxy in
                    if let eyes, let anchor = anchors["step"] {
                        let rect = proxy[anchor]
                        Circle().fill(.white.opacity(0.12)).frame(width: rect.width, height: rect.height)
                            .overlay { DashEyes(look: eyes.0, lid: eyes.1, check: eyes.2, ink: .white, halo: .black.opacity(0.35)) }
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { return }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        } catch { print("Couldn't write \(url.lastPathComponent): \(error)") }
    }
}
#endif
