import Foundation

/// Every debug switch Oops reads, in one place. Debug builds take them from UserDefaults, usually as
/// launch arguments (`-Name value`), which are never saved. Release builds compile each one to off,
/// so a stray default can't change a shipped app.
enum DebugFlags {
    #if DEBUG
    private static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    private static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }
    private static func number(_ key: String) -> Double { UserDefaults.standard.double(forKey: key) }
    private static func argument(_ name: String) -> Bool { ProcessInfo.processInfo.arguments.contains(name) }
    #else
    private static func string(_ key: String) -> String? { nil }
    private static func bool(_ key: String) -> Bool { false }
    private static func number(_ key: String) -> Double { 0 }
    private static func argument(_ name: String) -> Bool { false }
    #endif

    // MARK: Labs, end-to-end runs and profiling

    /// Lab triggers over distributed notifications (`fixtures/composer-lab/tools/trigger.swift`), and
    /// capture in the lab apps the editor policy doesn't cover.
    static var labTriggers: Bool { bool("DiagnosticsRemoteTrigger") }
    /// A control file for the stub provider (`fixtures/e2e`); no model is called.
    static var stubProvider: URL? { string("StubProvider").map { URL(fileURLWithPath: $0) } }
    /// Where `AppProbe` reports the focused field after each step (`fixtures/compat`).
    static var probeState: URL? { string("ProbeState").map { URL(fileURLWithPath: $0) } }
    /// Keeps an end-to-end run's debug log apart from the real one.
    static var debugLogDirectory: URL? { string("DebugLogDirectory").map { URL(fileURLWithPath: $0) } }
    /// `settings`, `capsule` or `editor`: drives one surface on a loop for `fixtures/perf/run.sh`.
    static var perfHarness: String? { string("PerfHarness") }
    /// Where the perf harness writes its frame-pacing summary, and how long it measures.
    static var perfReport: URL? { string("PerfReport").map { URL(fileURLWithPath: $0) } }
    static var perfSeconds: Double { number("PerfSeconds") }
    /// Logs each cue's scheduled and played times to this file.
    static var soundProbe: URL? { string("SoundProbe").map { URL(fileURLWithPath: $0) } }

    // MARK: Capsule and highlights

    /// Comma-separated accessibility appearances the capsule renders as if they were on.
    static var capsuleAccessibility: Set<String> { Set((string("CapsuleAccessibility") ?? "").split(separator: ",").map(String.init)) }
    /// `light` or `dark` for the capsule and highlights, whatever the system uses.
    static var capsuleAppearance: String? { string("CapsuleAppearance") }
    /// The highlight overlay over the Try page too, to test its measurement against the page's own flash.
    static var highlightOverlayEverywhere: Bool { bool("HighlightOverlayEverywhere") }
    /// `off`, `manual` or `enhanced`: forces the Chromium accessibility switch.
    static var highlightAccessibility: String? { string("HighlightAccessibility") }
    /// The capsule preview's working time, and its ending: failed, clear, pending or reverted.
    static var previewWorkingSeconds: Double { number("PreviewWorkingSeconds") }
    static var previewOutcome: String? { string("PreviewOutcome") }
    /// Launch arguments that show the capsule in one state at launch.
    static var previewCapsule: Bool { argument("--preview") }
    static var previewWorking: Bool { argument("--preview-still") }
    static var previewFailure: Bool { argument("--preview-error") }
    static var previewPending: Bool { argument("--preview-pending") }

    // MARK: Settings previews

    /// Open Settings, or its Try page, at launch.
    static var openSettings: Bool { argument("--settings") }
    /// `--welcome`: opens onboarding, as on a first launch.
    static var openWelcome: Bool { argument("--welcome") }
    /// `-HelloSnapshots <dir>`: renders Hello's key moments to PNGs and exits (HelloSnapshots).
    static var helloSnapshots: URL? { string("HelloSnapshots").map { URL(fileURLWithPath: $0) } }
    /// Native brand components, rendered offscreen before app services start.
    static var brandSnapshots: URL? { string("BrandSnapshots").map { URL(fileURLWithPath: $0) } }
    /// `-GradientSnapshots <dir>`: renders Hello's ShaderGradient to PNGs and exits (GradientSnapshots).
    static var gradientSnapshots: URL? { string("GradientSnapshots").map { URL(fileURLWithPath: $0) } }
    /// `-SetupSnapshots <dir>`: renders the Shortcut and Accessibility steps' moments to PNGs and exits (SetupSnapshots).
    static var setupSnapshots: URL? { string("SetupSnapshots").map { URL(fileURLWithPath: $0) } }
    /// `--hello-only`: onboarding's window alone, without the rest of the app; quits when it closes.
    static var helloOnly: Bool { argument("--hello-only") }
    /// Isolated, deterministic live brand review, starting at the welcome wordmark.
    static var brandReview: Bool { argument("--brand-review") }
    static var iconReview: Bool { argument("--icon-review") }
    static var capsuleReview: Bool { argument("--capsule-review") }
    static var brandReduceMotion: Bool { brandReview && bool("BrandReduceMotion") }
    static var systemSurfaceProofs: URL? { string("SystemSurfaceProofs").map { URL(fileURLWithPath: $0) } }
    static var brandTransitionScale: Double { max(1, min(6, number("BrandTransitionScale"))) }
    /// `--setup-first`: onboarding skips Hello to its finale and goes straight on to the setup steps.
    static var setupFirst: Bool { argument("--setup-first") }
    static var onboardingAllProviders: Bool { brandReview && bool("OnboardingAllProviders") }
    static var onboardingAPI: String? { brandReview ? string("OnboardingAPI") : nil }
    /// `-OnboardingStep provider|shortcut|accessibility|tryIt|home`: onboarding opens on that setup step, past Hello.
    static var onboardingStep: String? { string("OnboardingStep") }
    /// `-OnboardingFindings fresh|claude-signed-out|chatgpt-in|claude-in|both-in|local-server`: the Provider
    /// step sees that Mac whatever this one has: nothing set up, Claude Code installed but signed out, either or
    /// both signed in, or LM Studio running and Ollama wanting a key beside a signed-out Claude Code.
    static var onboardingFindings: String? { string("OnboardingFindings") }
    /// `-OnboardingSetUp ollama`: once the rows land, the Provider step opens that local server's Set up, as its button does.
    static var onboardingSetUp: String? { string("OnboardingSetUp") }
    /// `-OnboardingWindowWidth 992`: onboarding's window that wide (16:10), as a smaller screen sizes it.
    static var onboardingWindowWidth: Double { number("OnboardingWindowWidth") }
    /// `-OnboardingProviderSections YES`: the Provider step's list under section labels, a prototype that ships off.
    static var onboardingProviderSections: Bool { bool("OnboardingProviderSections") }
    /// `-SimulateAccessibilityGrant 4`: with `--preview-missing-accessibility`, the Accessibility step
    /// sees the permission granted that many seconds after System Settings opens. Nothing changes in
    /// the real setting.
    static var simulatedAccessibilityGrant: Double { number("SimulateAccessibilityGrant") }
    static var openTry: Bool { argument("--fixture") }
    /// The tab or page Settings opens on.
    static var settingsTab: String? { string("SettingsPreviewTab") }
    /// Opens a popover at launch (`models` for the model list).
    static var settingsPopover: String? { string("SettingsPreviewPopover") }
    /// A changelog file shown instead of the bundled one.
    static var changelog: URL? { string("SettingsPreviewChangelog").map(URL.init(fileURLWithPath:)) }
    /// `available`, `downloading`, `ready` or `failed`: walks About's update card without a real update.
    static var update: String? { string("SettingsPreviewUpdate") }
    /// Fake provider states: ChatGPT `signedIn`, `signedOut` or `reauth`; a provider page to open.
    static var providers: Bool { bool("SettingsPreviewProviders") || brandReview }
    static var chatGPT: String? { string("SettingsPreviewChatGPT") }
    static var provider: String? { string("SettingsPreviewProvider") }
    /// A pointer position (`x,y`) for hover states in captures.
    static var pointer: String? { string("SettingsPreviewPointer") }
    /// Cycles the tabs, for recordings.
    static var cycleTabs: Bool { bool("SettingsPreviewCycle") }
    /// A generated month of stats; nothing is written.
    static var sampleStats: Bool { bool("SettingsPreviewStats") }
    /// `light` or `dark` for the Settings window.
    static var settingsAppearance: String? { string("SettingsPreviewAppearance") }
    /// A colourful window behind Settings for captures; `text` puts text in it.
    static var backdrop: Bool { bool("SettingsPreviewBackdrop") || backdropText }
    static var backdropText: Bool { string("SettingsPreviewBackdrop") == "text" }
    /// The opaque enclosure Reduce Transparency gets, without turning it on.
    static var opaqueSettings: Bool { bool("SettingsPreviewReduceTransparency") }
    /// `standard`, `clear` or `lens`: the Settings glass.
    static var glassVariant: String? { string("SettingsGlassVariant") }
    /// Settings as if Accessibility were missing.
    static var missingAccessibility: Bool { argument("--preview-missing-accessibility") }

    // MARK: Onboarding steps' states, with -OnboardingStep

    /// `-OnboardingRecording YES`: the Shortcut or Try it step opens recording a new shortcut.
    static var onboardingRecording: Bool { bool("OnboardingRecording") }
    /// `-OnboardingDefaultShortcut YES`: the steps show the default ⌃⌘W, not this Mac's saved shortcut.
    /// Nothing is saved.
    static var onboardingDefaultShortcut: Bool { bool("OnboardingDefaultShortcut") }
    /// `-OnboardingMenuBarEyes YES|NO`: the Home step as if Oops's eyes were (or weren't) in the menu bar.
    static var onboardingMenuBarEyes: Bool? { string("OnboardingMenuBarEyes").map { NSString(string: $0).boolValue } }
    /// `-OnboardingOlderPane YES`: the Accessibility pane as macOS 26 names and draws it.
    static var onboardingOlderPane: Bool { bool("OnboardingOlderPane") }
}
