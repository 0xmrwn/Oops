import Foundation

#if DEBUG
    #error("Release debug-switch verification must compile without DEBUG")
#endif

/// Runs outside the app. Registered defaults are in memory, never written to the user's preferences.
@main enum ReleaseDebugCheck {
    static func main() {
        UserDefaults.standard.register(defaults: [
            "DiagnosticsRemoteTrigger": true, "StubProvider": "/tmp/should-not-load", "ProbeState": "/tmp/should-not-write",
            "DebugLogDirectory": "/tmp/should-not-write", "PerfHarness": "settings", "PerfSeconds": 30,
            "SettingsPreviewProviders": true, "SettingsPreviewUpdate": "available", "SettingsPreviewStats": true,
        ])
        precondition(!DebugFlags.labTriggers && DebugFlags.stubProvider == nil && DebugFlags.probeState == nil)
        precondition(DebugFlags.debugLogDirectory == nil && DebugFlags.perfHarness == nil && DebugFlags.perfSeconds == 0)
        precondition(!DebugFlags.providers && DebugFlags.update == nil && !DebugFlags.sampleStats)
        precondition(!DebugFlags.brandReview && !DebugFlags.helloOnly && !DebugFlags.openSettings)
    }
}
