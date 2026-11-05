import Foundation

/// Which apps Oops corrects in (D4): any app whose focused field passes the text, selection and
/// secure-field checks, except terminals, password managers and the apps turned off in Settings.
/// Application scope is separate from those field checks.
public enum EditorApplicationPolicy {
    public enum Verdict: Equatable, Sendable {
        /// `bundleID` is the app as Settings names it; `nested` when the field lives in a helper
        /// process inside the frontmost app's bundle (Teams' WebView), which then stands for it.
        case accepted(bundleID: String, nested: Bool)
        case denied
        case turnedOff
        case unknown
    }

    /// Terminals (a shell reads what Oops would paste) and password managers.
    public static let denied: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.raphaelamorim.rio", "org.tabby", "com.termius-dmg.mac",
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
        "in.sinew.Enpass-Desktop", "com.nordsec.nordpass", "me.proton.pass.electron", "com.sentry.Strongbox"
    ]

    public static func verdict(bundleID: String?, bundleURL: URL?, foregroundBundleID: String?, foregroundBundleURL: URL?,
                               turnedOff: Set<String>) -> Verdict {
        let nested = isNested(bundleURL, in: foregroundBundleURL)
        guard let owner = nested ? foregroundBundleID : bundleID else { return .unknown }
        if denied.contains(owner) { return .denied }
        if turnedOff.contains(owner) { return .turnedOff }
        return .accepted(bundleID: owner, nested: nested && bundleID != foregroundBundleID)
    }

    /// Whether `child` is an app bundle inside `parent`'s (Teams' WebView, Electron and Chromium
    /// helpers), compared after resolving symlinks and `..`.
    public static func isNested(_ child: URL?, in parent: URL?) -> Bool {
        guard let child, child.isFileURL, let parent, parent.isFileURL else { return false }
        let root = parent.standardizedFileURL.resolvingSymlinksInPath().path
        let path = child.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/Contents/")
    }
}

/// Text fields that hold secrets without saying so: a web password or code field that isn't
/// exposed as secure, recognised by its labels, placeholder, identifiers and autofill hints.
public enum SensitiveField {
    public static func matches(_ descriptions: [String]) -> Bool {
        descriptions.contains { text in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A field that shows only mask characters is a secret field that didn't say so (Qt's password
    /// echo mode reads as its bullets).
    public static func isMasked(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.unicodeScalars.allSatisfy { "•●∙⦁*".unicodeScalars.contains($0) }
    }

    static let pattern = #"pass ?(word|code|phrase)|passwd|mot de passe|contraseña|passwort|\bpin\b|one[- ]?time|\botp\b|\b2fa\b|verification code|security code|current-password|new-password|cc-(number|csc)|\bcv[cv]\b|card ?number|\biban\b|\bsecret\b|api[ _-]?key"#
}
