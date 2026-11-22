/// Escape cancels whatever armed it: Dictate while it records, an agent run while its working drop is in front. They
/// share one registration set, so each feature's chords are kept apart and the hotkeys carry their union.
struct EscapeChords: Equatable {
    private(set) var armed: [DropFeature: [UInt32]] = [:]

    /// Arms `chords` (Carbon modifier sets) for `feature`, none disarming it; the union to register, Dictate's first.
    mutating func arm(_ feature: DropFeature, _ chords: [UInt32]) -> [UInt32] {
        armed[feature] = chords.isEmpty ? nil : chords
        var union: [UInt32] = []
        for chord in (armed[.dictate] ?? []) + (armed[.agent] ?? []) where !union.contains(chord) { union.append(chord) }
        return union
    }

    /// Who an Escape press is for: the agent run only while Dictate hasn't armed it.
    var target: DropFeature { armed[.dictate] == nil && armed[.agent] != nil ? .agent : .dictate }
}
