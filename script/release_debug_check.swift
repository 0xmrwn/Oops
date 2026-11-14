import Foundation

#if DEBUG
    #error("Release debug-switch verification must compile without DEBUG")
#endif

/// Runs outside the app. Registered defaults are in memory, never written to the user's preferences.
/// Compiled with -D OOPS_PREVIEW for a preview build, where dictation, its model path, its audio file and the live
/// words' layout are the only switches on.
@main enum ReleaseDebugCheck {
    static func main() {
        UserDefaults.standard.register(defaults: [
            "DiagnosticsRemoteTrigger": true, "StubProvider": "/tmp/should-not-load", "ProbeState": "/tmp/should-not-write",
            "DebugLogDirectory": "/tmp/should-not-write", "PerfHarness": "settings", "PerfSeconds": 30,
            "SettingsPreviewProviders": true, "SettingsPreviewUpdate": "available", "SettingsPreviewStats": true,
            "DebugDictation": true, "DebugActions": true, "DebugDictationModel": "/tmp/model.gguf",
            "DebugDictationAudioFile": "/tmp/should-not-play.wav", "DebugLiveWordsLayout": "inline",
        ])
        #if OOPS_PREVIEW
            precondition(DebugFlags.dictation && DebugFlags.dictationModel == "/tmp/model.gguf" && !DebugFlags.actions)
            precondition(DebugFlags.dictationAudioFile == "/tmp/should-not-play.wav" && DebugFlags.liveWordsLayout == "inline")
        #else
            precondition(!DebugFlags.dictation && DebugFlags.dictationModel == nil && !DebugFlags.actions)
            precondition(DebugFlags.dictationAudioFile == nil && DebugFlags.liveWordsLayout == nil)
        #endif
        precondition(!DebugFlags.labTriggers && DebugFlags.stubProvider == nil && DebugFlags.probeState == nil)
        precondition(DebugFlags.debugLogDirectory == nil && DebugFlags.perfHarness == nil && DebugFlags.perfSeconds == 0)
        precondition(!DebugFlags.providers && DebugFlags.update == nil && !DebugFlags.sampleStats)
        precondition(!DebugFlags.brandReview && !DebugFlags.helloOnly && !DebugFlags.openSettings)
    }
}
