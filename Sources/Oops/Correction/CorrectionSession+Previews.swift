import AppKit
import OopsCore

extension CorrectionSession {
    // MARK: Previews

    /// Debug tools → Placement → Preview: the capsule where the placement engine puts it for the focused editor.
    func previewPlacement() async -> String {
        do {
            let geometry = try await editor.focusedGeometry()
            preview(geometry: geometry)
            if let placement = capsule.placement { PlacementProbe.recordPreview(geometry, placement) }
            return "Placed by \(capsule.placement?.strategy.rawValue ?? "unknown") strategy."
        } catch { return error.localizedDescription }
    }

    /// Debug tools → Capsule → Play: the busy and done animation, without sending any text.
    func preview(geometry: CapsulePlacement.Geometry? = nil) {
        guard holdDrop() else { return }
        Sounds.warm()
        capsule.show(.invoked, label: "", geometry: geometry)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.capsule.show(.working, label: "Fixing…")
            try? await Task.sleep(for: .seconds(DebugFlags.previewWorkingSeconds > 0 ? DebugFlags.previewWorkingSeconds : 1.7))
            let outcome = DebugFlags.previewOutcome
            switch outcome {
            case "failed":
                // Retry replays the preview, reading the outcome again.
                self?.capsule.model.retry = { [weak self] in self?.preview(geometry: geometry) }
                self?.capsule.show(.failed, label: "No connection", detail: "Preview of the failure state.", remedy: .retry)
            case "clear": self?.capsule.show(.fixed, label: "Already clear · 0.6s")
            case "pending":
                self?.pendingCorrection = "Preview correction"
                self?.capsule.show(.pending, label: "Couldn’t paste", detail: "Preview of the copy fallback.")
                return
            case "reverted":
                self?.capsule.show(.fixed, label: "3 fixes · 0.8s")
                try? await Task.sleep(for: .seconds(1.4))
                self?.capsule.show(.reverted, label: "Reverted")
            default: self?.capsule.show(.fixed, label: "3 fixes · 0.8s")
            }
            self?.capsule.hide(after: outcome == "failed" ? 8 : 1.5)
        }
    }

    #if DEBUG
    /// Launch-argument stills for captures: a failure or the copy fallback, without a correction.
    func previewFailure() {
        capsule.show(.failed, label: "No connection", detail: "Preview error. Your draft was left unchanged.", remedy: .retry)
        capsule.hide(after: 8)
    }

    func previewPending() {
        pendingCorrection = "Preview correction"
        capsule.show(.pending, label: "Couldn’t paste")
    }
    #endif
}
