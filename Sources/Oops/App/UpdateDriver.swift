import Foundation
import Sparkle

/// Sparkle's user interface, as states of `Updates` for About's card instead of Sparkle's windows.
/// Sparkle asks, `Updates` answers through `answer(_:)` when the user picks Update or Relaunch.
@MainActor final class UpdateDriver: NSObject, SPUUserDriver {
    weak var updates: Updates?
    private var reply: ((SPUUserUpdateChoice) -> Void)?
    private var release: Updates.Release?
    private var expected: UInt64 = 0, received: UInt64 = 0

    /// Answers Sparkle's open question (the update found, or ready to relaunch) once.
    func answer(_ choice: SPUUserUpdateChoice) {
        let reply = reply
        self.reply = nil
        reply?(choice)
    }

    /// Never asked: Info.plist turns daily checks on (`SUEnableAutomaticChecks`), so there's no consent prompt.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        updates?.show(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let release = Updates.Release(
            version: appcastItem.displayVersionString,
            notes: Self.notes(appcastItem.itemDescription ?? ""),
            page: appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil
        )
        self.release = release
        self.reply = reply
        // Installing: downloaded and staged by an earlier run; Install relaunches at once.
        updates?.show(state.stage == .installing ? .ready(release) : .available(release))
    }

    /// Notes linked rather than embedded in the feed (ours are embedded; kept for a feed that links them).
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard var release, case .available = updates?.state else { return }
        release.notes = Self.notes(String(decoding: downloadData.data, as: UTF8.self))
        self.release = release
        updates?.show(.available(release))
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        updates?.show(.upToDate)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        updates?.show(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0; received = 0
        progress(0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        progress(min(1, Double(received) / Double(expected)))
    }

    /// Extracting and checking the signatures take a moment after the download: the bar stays full.
    func showDownloadDidStartExtractingUpdate() { progress(1) }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        if let release { updates?.show(.ready(release)) }
    }

    /// Sparkle asks Oops to quit next; the card keeps showing Relaunch until it does.
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    /// The end of every cycle, also after Up to date or an error: those stay shown until the next check.
    func dismissUpdateInstallation() {
        reply = nil
        release = nil
        switch updates?.state {
        case .checking, .available, .downloading, .ready: updates?.show(.idle)
        default: break
        }
    }

    private func progress(_ value: Double) {
        if let release { updates?.show(.downloading(release, progress: value)) }
    }

    /// The release's CHANGELOG.md entries: `script/release_appcast.py` embeds them as Markdown, one `- ` line each.
    nonisolated static func notes(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
            .map { String($0.dropFirst(2)) }
    }
}
