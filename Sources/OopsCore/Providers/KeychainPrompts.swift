import Darwin
import Security

/// Oops never shows the Keychain's own password prompt. An item another app (or another build of Oops) made
/// can't be read without one; then the read fails at once and Oops shows the provider as signed out, so the
/// person signs in again from Settings. A prompt raised by a menu-bar app in the background could leave the
/// keyboard reaching nothing, the prompt included, until it was dismissed.
public enum KeychainPrompts {
    /// Turns the prompts off for this process: call before anything reads the Keychain.
    public static func disallow() {
        // On macOS 27 only this switch stops a Keychain item's access prompt: `kSecUseAuthenticationUIFail`
        // and `LAContext.interactionNotAllowed` both still prompt. It's deprecated, so it is looked up at run
        // time rather than failing a build that treats warnings as errors.
        typealias SetInteractionAllowed = @convention(c) (DarwinBoolean) -> OSStatus
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "SecKeychainSetUserInteractionAllowed") else { return }
        _ = unsafeBitCast(symbol, to: SetInteractionAllowed.self)(false)
    }
}
