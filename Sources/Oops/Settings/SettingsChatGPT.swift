import AppKit
import SwiftUI
import OopsCore

// MARK: - Screenshot preview (debug only)

/// `defaults write dev.0xmrwn.oops SettingsPreviewChatGPT signedIn` (or `reauth`, `signedOut`)
/// renders the ChatGPT states with a fake identity and a bundled catalog, without network or Keychain.
struct ChatGPTPreview {
    let status: ChatGPTStatus
    let models: [ChatGPTModel]
    var identity: ChatGPTIdentity { Self.identity }
    private static let identity = ChatGPTIdentity(email: "alex@example.com", name: "Alex", plan: "plus")

    init?(_ value: String?) {
        switch value {
        case "signedIn": status = .signedIn(Self.identity)
        case "reauth": status = .reauthRequired
        case "signedOut": status = .signedOut
        default: return nil
        }
        models = (try? ChatGPTModels.decode(Data(Self.catalog.utf8))) ?? []
    }

    // Public models in the backend catalog's shape, for the Settings preview.
    private static let catalog = #"""
    {"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","description":"Latest workhorse model for coding and everyday work.","visibility":"list","priority":1,"default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},{"effort":"max","description":"Maximum reasoning depth for the hardest problems"},{"effort":"ultra","description":"Maximum reasoning with automatic task delegation"}],"service_tiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}]},{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","description":"Frontier intelligence for the most demanding work.","visibility":"list","priority":2,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},{"effort":"max","description":"Maximum reasoning depth for the hardest problems"},{"effort":"ultra","description":"Maximum reasoning with automatic task delegation"}],"service_tiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}]},{"slug":"gpt-6-luna","display_name":"GPT-6-Luna","description":"Fast and affordable model for easier tasks.","visibility":"list","priority":5,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},{"effort":"max","description":"Maximum reasoning depth for the hardest problems"}],"service_tiers":[{"id":"priority","name":"Fast","description":"1.5x speed"}]},{"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","description":"Older fast and efficient model.","visibility":"list","priority":9,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Fast responses with lighter reasoning"},{"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},{"effort":"high","description":"Greater reasoning depth for complex problems"},{"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},{"effort":"max","description":"Maximum reasoning depth for the hardest problems"}],"service_tiers":[{"id":"priority","name":"Fast","description":"1.5x speed, increased usage"}]}]}
    """#
}

// MARK: - Provider section

struct ChatGPTProviderSection: View {
    @ObservedObject var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Hashable { case checking, signedOut, reauth, signedIn }
    private var phase: Phase {
        switch preferences.chatGPTStatus {
        case .signedIn: .signedIn
        case .reauthRequired: .reauth
        case .signedOut: .signedOut
        case nil: .checking
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch preferences.chatGPTStatus {
            case .signedIn(let identity):
                ChatGPTConnectionCard(preferences: preferences, identity: identity)
                    .transition(SettleTransition(reduceMotion: reduceMotion))
            case .reauthRequired:
                ChatGPTSignInCard(preferences: preferences, reauth: true)
                    .transition(SettleTransition(reduceMotion: reduceMotion))
            case .signedOut:
                ChatGPTSignInCard(preferences: preferences, reauth: false)
                    .transition(SettleTransition(reduceMotion: reduceMotion))
            case nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking ChatGPT sign-in…").secondaryText()
                }
                .settingsSurface()
                .transition(SettleTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(SettingsMotion.swap(reduceMotion), value: phase)
    }
}

/// OpenAI's ChatGPT mark, from the unmodified brand assets: black on light surfaces, white on dark ones.
struct ChatGPTMark: View {
    let size: CGFloat
    /// Picks a variant for a mark on a fill of its own; nil follows the appearance.
    var white: Bool?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(white ?? (scheme == .dark) ? "ChatGPTMarkWhite" : "ChatGPTMarkBlack", bundle: .main)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ChatGPTSignInCard: View {
    @ObservedObject var preferences: Preferences
    let reauth: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ChatGPTMark(size: 34).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reauth ? "Reconnect to ChatGPT" : "ChatGPT").font(.headline)
                    Text(reauth ? "Your ChatGPT sign-in expired. Sign in again to keep using your plan."
                                : "Use your ChatGPT plan for corrections.")
                        .secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ContinueWithChatGPTButton(loading: preferences.signingIn) { preferences.signInWithChatGPT() }
            if preferences.signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish in your browser").font(.callout).secondaryText()
                    Button("Cancel") { preferences.cancelSignIn() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                .transition(.opacity)
            }
            if let message = preferences.chatGPTMessage {
                ChatGPTNotice(message)
            }
        }
        .animation(SettingsMotion.swap(reduceMotion), value: preferences.signingIn)
        .settingsSurface()
    }
}

private struct ChatGPTNotice: View {
    let message: String
    init(_ message: String) { self.message = message }
    var body: some View {
        Label {
            Text(message).font(.callout).secondaryText().fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct ChatGPTConnectionCard: View {
    @ObservedObject var preferences: Preferences
    let identity: ChatGPTIdentity

    /// Both actions sign out; each asks first.
    private enum Confirmation { case disconnect, switchAccount }
    @State private var confirming: Confirmation?

    private var title: String { nonEmpty(identity.name) ?? nonEmpty(identity.email) ?? "Connected with ChatGPT" }
    private var subtitle: String? { nonEmpty(identity.name) == nil ? nil : nonEmpty(identity.email) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AccountAvatar(name: title)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let subtitle { Text(subtitle).font(.callout).secondaryText().lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 8)
                StatusBadge("Connected", ok: true)
            }
            Divider()
            HStack(spacing: 12) {
                Text(planText).secondaryText()
                Spacer()
                Button(action: preferences.openUsage) {
                    HStack(spacing: 4) {
                        Text("Manage usage")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.settingsGlass)
                .accessibilityLabel("Manage ChatGPT usage (opens in browser)")
            }
            Divider()
            HStack(spacing: 12) {
                // A glass button, not a link: blue text loses contrast on the clear glass.
                Button { confirming = .switchAccount } label: { Label("Use a different account…", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.settingsGlass)
                    .help("Disconnect and forget this account, so the next sign-in can choose another one.")
                Spacer()
                Button { confirming = .disconnect } label: { Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.settingsGlass)
            }
            .disabled(preferences.disconnecting)
            if let message = preferences.chatGPTMessage { ChatGPTNotice(message) }
        }
        .settingsSurface()
        .confirmationDialog(confirming == .switchAccount ? "Use a different ChatGPT account?" : "Disconnect ChatGPT?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if confirming == .switchAccount {
                Button("Sign Out and Forget") { preferences.signOut(forgetAccount: true) }
            } else {
                Button("Disconnect", role: .destructive) { preferences.signOut() }
            }
        } message: {
            Text(confirming == .switchAccount ? "Oops signs out of \(title) so the next sign-in can choose another account."
                                              : "Fixes with ChatGPT stop until you sign in again.")
        }
    }

    /// The plan type from the sign-in (`plus`, `pro`, `team`…), as a name: " Plus".
    private var plan: String { nonEmpty(identity.plan).map { " " + $0.capitalized } ?? "" }
    private var planText: String { plan.isEmpty ? "Using your ChatGPT plan" : "Using ChatGPT\(plan) plan" }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Sign-in button

/// "Continue with ChatGPT", the label OpenAI's UI/UX guidelines give the action that starts the sign-in,
/// in one of the approved button formats (developers.openai.com/siwc/website): the ChatGPT logo and the
/// label on black in light appearance and on white in dark, never glass, so it always reads as OpenAI's
/// own button. Alone it is 242 × 45 pt with its content centred; `listed` gives it a `ProviderListItem`'s
/// size with the content leading, so it lines up with the rows around it.
struct ContinueWithChatGPTButton: View {
    var loading = false
    var listed = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Button(action: action) {
            HStack(spacing: ProviderListItem.gap) {
                ChatGPTMark(size: ProviderListItem.mark, white: !dark)
                Text(title).font(.system(size: 15, weight: .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, listed ? ProviderListItem.inset : 0)
            .frame(width: listed ? ProviderListItem.width : 242, height: listed ? ProviderListItem.height : 45, alignment: listed ? .leading : .center)
            .background(dark ? Color.white : Color.black, in: .rect(cornerRadius: ProviderListItem.radius))
            .contentShape(.rect(cornerRadius: ProviderListItem.radius))
        }
        .buttonStyle(BrandButtonStyle())
        .disabled(loading)
        .modifier(FocusVisibleRing())
        .accessibilityLabel(loading ? "Signing in with ChatGPT, finish in your browser" : "Continue with ChatGPT")
    }

    /// In a list the button is the only sign of progress; in Settings the card says where to finish.
    private var title: String {
        guard loading else { return "Continue with ChatGPT" }
        return listed ? "Finish in your browser…" : "Opening ChatGPT…"
    }
}

// MARK: - First sign-in

/// Shown once, after the first successful sign-in (OpenAI UI guidelines: confirm what the plan is used for).
struct ChatGPTWelcomeSheet: View {
    let done: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            ChatGPTMark(size: 72)
            VStack(spacing: 8) {
                Text("You’re signed in with ChatGPT")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Corrections in Oops now use your ChatGPT plan and count toward its usage limits. Manage usage anytime in ChatGPT settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: done) { Text("Got it").frame(maxWidth: .infinity) }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 380)
    }
}
