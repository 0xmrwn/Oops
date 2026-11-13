import Carbon
import Foundation
import OopsCore

// A port of Hex's macOS input-source observer at v3.4.0 (MIT, github.com/anomalyco/hex): the Text Input Sources
// reads and the distributed notification of `src/keyboard_input_sources/macos.rs`. See THIRD_PARTY_NOTICES.md.

/// The keyboard input sources the user has enabled and which one is selected, from Text Input Sources. Main actor
/// only, like the system calls it wraps. The debounce before a change acts belongs to `KeyboardModelSwitcher`.
@MainActor
final class KeyboardInputSources: NSObject {
    static let shared = KeyboardInputSources()

    private var observing = false
    private var listeners: [UUID: AsyncStream<String?>.Continuation] = [:]

    /// The id of the selected keyboard input source (`com.apple.keylayout.ABC`).
    func current() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.string(source, kTISPropertyInputSourceID)
    }

    /// Enabled, selectable keyboard sources, not every installed source or the palettes, sorted by name.
    func enabled() -> [KeyboardInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        var sources: [KeyboardInputSource] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(pointer).takeUnretainedValue()
            guard Self.string(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  Self.flag(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = Self.string(source, kTISPropertyInputSourceID),
                  let name = Self.string(source, kTISPropertyLocalizedName) else { continue }
            sources.append(KeyboardInputSource(id: id, name: name, languages: Self.strings(source, kTISPropertyInputSourceLanguages)))
        }
        sources.sort { ($0.name, $0.id) < ($1.name, $1.id) }
        return sources.reduce(into: []) { result, source in
            if result.last?.id != source.id { result.append(source) }
        }
    }

    /// The selected source's id now, then again after each change, nil when the system names none. Hex reports the
    /// current source once when its consumer starts listening, so the consumer learns it without a stale value.
    func changes() -> AsyncStream<String?> {
        startObserving()
        let (stream, continuation) = AsyncStream<String?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        listeners[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[token] = nil }
        }
        continuation.yield(current())
        return stream
    }

    /// One observer for the app's life, delivering immediately as Hex's does: Oops is never the active app,
    /// and a held-back notification would arrive only once it was.
    private func startObserving() {
        guard !observing else { return }
        observing = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func sourceChanged() {
        let id = current()
        for continuation in listeners.values { continuation.yield(id) }
    }

    private nonisolated static func property(_ source: TISInputSource, _ key: CFString) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(source, key)
    }

    private nonisolated static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private nonisolated static func strings(_ source: TISInputSource, _ key: CFString) -> [String] {
        guard let pointer = property(source, key) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]) ?? []
    }

    private nonisolated static func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
        property(source, key).map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
    }
}
