import Combine
import Sparkle
import SwiftUI

/// Sparkle updates: checks the appcast on the project site (`SUFeedURL` in Info.plist) in the
/// background, and on demand from "Check for Updates…". Updates are EdDSA-signed (`SUPublicEDKey`);
/// Sparkle only installs a DMG signed with the matching private key.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// nil in demo mode and in unbundled `swift build` runs (no feed in the Info.plist).
    private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: AnyCancellable?

    /// Development aid: `CLAUDEDECK_UPDATE_FEED` points the updater at another appcast (e.g. a local
    /// test feed) and enables it in demo mode.
    private static let testFeed = ProcessInfo.processInfo.environment["CLAUDEDECK_UPDATE_FEED"]
    @ObservationIgnored private let delegate = UpdaterDelegate(feed: testFeed)
    /// Work held back until the launch update check is settled (see `startHoldingForUpdate`).
    @ObservationIgnored private var held: (@MainActor () -> Void)?
    @ObservationIgnored private var installing = false

    private init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        guard hasFeed, !AppModel.isDemo || Self.testFeed != nil else { controller = nil; return }
        // Started in startHoldingForUpdate, so the launch check is ours.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        self.controller = controller
        delegate.owner = self
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    var isAvailable: Bool { controller != nil }

    /// Starts the updater and, when automatic checks are on, checks right away. `then` (resuming the
    /// sessions) runs once there is no update, the check fails or takes over 8 s, the user
    /// postpones or skips the update, or nobody answers within 2 minutes. If they install it, it doesn't run: the app relaunches into
    /// the new version and the sessions resume there, instead of starting twice.
    func startHoldingForUpdate(then: @escaping @MainActor () -> Void) {
        guard let controller else { return then() }
        controller.startUpdater()
        guard controller.updater.automaticallyChecksForUpdates else { return then() }
        held = then
        // Called right after starting, this replaces Sparkle's own scheduled launch check.
        controller.updater.checkForUpdatesInBackground()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !self.foundUpdate else { return }
            self.release()
        }
        // Nobody may be looking (launched at login into the menu bar): don't hold sessions forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            self?.release()
        }
    }

    @ObservationIgnored fileprivate var foundUpdate = false

    fileprivate func release() {
        guard !installing, let work = held else { return }
        held = nil
        work()
    }

    fileprivate func userChose(_ choice: SPUUserUpdateChoice) {
        if choice == .install { installing = true } else { release() }
    }

    fileprivate func aborted() {
        installing = false
        release()
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let feed: String?
    @MainActor weak var owner: AppUpdater?
    init(feed: String?) { self.feed = feed }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }
    /// A relaunch drops the environment (demo mode, test feed): the relaunched app would run as a
    /// normal instance on the real deck.json and resume every real session a second time.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { feed == nil }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.foundUpdate = true }
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { owner?.release() }
    }
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { owner?.userChose(choice) }
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        MainActor.assumeIsolated { owner?.aborted() }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { owner?.release() }
    }
}

/// App menu: "Check for Updates…" right under "About ClaudeDeck".
struct UpdateCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}

/// Settings › General.
struct UpdateSettingsRows: View {
    @State private var automatic = AppUpdater.shared.automaticallyChecks

    var body: some View {
        let updater = AppUpdater.shared
        if updater.isAvailable {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { automatic },
                set: { automatic = $0; updater.automaticallyChecks = $0 }
            ))
            HStack {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
