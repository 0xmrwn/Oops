import Carbon
import Foundation

public enum KeyboardLayout {
    /// `command`: the key that types `character` while Command is held, which is what a ⌘ shortcut
    /// matches (it differs from the plain key in layouts like "Dvorak – QWERTY ⌘").
    public static func keyCode(for character: String, command: Bool = false) -> UInt32? {
        let wanted = character.lowercased()
        return (UInt32(0)..<128).first { self.character(for: $0, command: command)?.lowercased() == wanted }
    }

    public static func character(for keyCode: UInt32, command: Bool = false) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKey: UInt32 = 0
            var count = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), command ? UInt32(cmdKey >> 8) : 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKey, characters.count, &count, &characters)
            guard status == noErr, count > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: count)
        }
    }
}
