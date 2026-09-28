import ClaudeDeckCore
import Foundation
import Observation

/// Opt-in iCloud Drive sync of projects and groups (`DeckSettings.iCloudSync`).
/// Plain file in iCloud Drive, no entitlements: `~/Library/Mobile Documents/com~apple~CloudDocs/ClaudeDeck/projects.json`.
/// Merge semantics live in `DeckSync` (ClaudeDeckCore).
@MainActor
@Observable
final class DeckSyncController {
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let folderProvider: () -> URL?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var watchedFolder: URL?
    /// Bytes of the file as last read or written — the loop guard: our own write fires the
    /// watcher, finds identical bytes and stops there.
    @ObservationIgnored private var lastFileData: Data?

    init(folder: @escaping () -> URL? = { DeckSyncFile.defaultFolder() }) {
        self.folderProvider = folder
    }

    static var isAvailable: Bool { DeckSyncFile.iCloudDriveAvailable() }

    private var enabled: Bool { model?.deck.settings.iCloudSync == true }

    func start(model: AppModel) {
        self.model = model
        refresh()
    }

    /// Starts or stops syncing to match the setting; when on, syncs right away.
    func refresh() {
        guard enabled, let folder = folderProvider() else {
            watcher?.stop()
            watcher = nil
            watchedFolder = nil
            lastFileData = nil
            return
        }
        if watchedFolder != folder {
            watcher?.stop()
            // DirectoryWatcher creates the folder (iCloud Drive itself exists, checked above).
            let w = DirectoryWatcher(url: folder, debounce: 0.5) { [weak self] in
                Task { @MainActor in self?.remoteChanged() }
            }
            w.start()
            watcher = w
            watchedFolder = folder
        }
        remoteChanged(force: true)
    }

    /// The file changed (or sync was just turned on): merge it into the deck, then write the union back.
    private func remoteChanged(force: Bool = false) {
        guard enabled, let model, let folder = watchedFolder else { return }
        let file = DeckSyncFile(folder: folder)
        let result = file.read()
        if case .ok(let data, _) = result, data == lastFileData, !force { return }
        var next = model.deck
        DeckSync.stamp(&next)
        if case .ok(let data, let remote) = result {
            lastFileData = data
            next = DeckSync.merge(local: next, remote: remote)
        }
        if next != model.deck {
            // The save that follows (AppModel.saveNow → prepareSave) writes the union back.
            model.mutate { $0 = next }
            return
        }
        write(deck: next, file: file, current: result)
    }

    /// Called from `AppModel.saveNow`. Stamps local edits and writes the file if its content
    /// would change. Returns the updated deck (new stamps / merged remote items), or nil.
    func prepareSave(_ deck: DeckData) -> DeckData? {
        guard deck.settings.iCloudSync, let folder = watchedFolder else { return nil }
        let file = DeckSyncFile(folder: folder)
        let result = file.read()
        var updated = deck
        DeckSync.stamp(&updated)
        if case .ok(let data, let remote) = result, data != lastFileData {
            // A remote change we haven't merged yet: merge before overwriting.
            lastFileData = data
            updated = DeckSync.merge(local: updated, remote: remote)
        }
        write(deck: updated, file: file, current: result)
        return updated == deck ? nil : updated
    }

    private func write(deck: DeckData, file: DeckSyncFile, current: DeckSyncFile.ReadResult) {
        let remote: SyncPayload
        switch current {
        case .ok(_, let payload): remote = payload
        case .missing: remote = SyncPayload()
        case .notDownloaded:
            // Never overwrite a file iCloud hasn't downloaded yet; the watcher fires once it arrives.
            return
        case .unreadable:
            lastError = "iCloud'daki \(DeckSync.fileName) okunamadı; üzerine yazılmadı."
            return
        }
        let data = DeckSync.combine(DeckSync.payload(from: deck), remote).encoded()
        if case .ok(let existing, _) = current, existing == data {
            lastFileData = data
            lastSyncAt = Date()
            lastError = nil
            return
        }
        do {
            try file.write(data)
            lastFileData = data
            lastSyncAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
