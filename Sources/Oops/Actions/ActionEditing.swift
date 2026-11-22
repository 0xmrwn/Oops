import ApplicationServices
import Foundation
import OopsCore

/// What a run asks of the editor while it writes, takes back and settles: the session's seam to the guarded swap and
/// to the Chromium accessibility switch, so each step can be stood in for.
struct ActionEditing {
    /// Replaces the span `snapshot` read with the answer; returns the snapshot the swap ended on.
    var write: @MainActor (_ answer: String, _ snapshot: EditorSnapshot, _ id: UUID) async throws -> EditorSnapshot = { _, snapshot, _ in snapshot }
    /// Puts the draft read at capture back, from what the action left in its place.
    var restore: @MainActor (_ snapshot: EditorSnapshot, _ applied: String, _ id: UUID) async throws -> EditorSnapshot = { snapshot, _, _ in snapshot }
    /// Where the draft sits now.
    var geometry: @MainActor (_ element: AXUIElement) async -> CapsulePlacement.Geometry? = { _ in nil }
    /// Wakes a dormant Chromium editor so it can be read or written; whether it was woken.
    var enableAccessibility: @MainActor (_ snapshot: EditorSnapshot) async -> Bool = { _ in false }
    /// Puts a Chromium editor's accessibility back.
    var disableAccessibility: @MainActor (_ snapshot: EditorSnapshot) async -> Void = { _ in }
}
