import Foundation
import Darwin

public enum StatusDirectory {
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".claude/deck/sessions")
    }

    /// Reads every status file in the directory. Unreadable / partial files are skipped.
    public static func readAll(in dir: URL) -> [(url: URL, status: HookStatus)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "json", !url.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: url),
                  let status = try? HookStatus.decode(data)
            else { return nil }
            return (url, status)
        }
    }

    /// Newest status per terminal. After `/clear` a terminal gets a new `session_id`,
    /// so older files of the same terminal are superseded.
    public static func latestByTerminal(_ statuses: [HookStatus]) -> [String: HookStatus] {
        var result: [String: HookStatus] = [:]
        for status in statuses {
            guard let tid = status.terminalID else { continue }
            if let current = result[tid], current.updatedAt >= status.updatedAt { continue }
            result[tid] = status
        }
        return result
    }

    /// Files that can be deleted: superseded, ended, or whose process is gone,
    /// once they are older than `grace`. Files of live processes are always kept.
    public static func filesToDelete(
        _ entries: [(url: URL, status: HookStatus)],
        now: Date,
        grace: TimeInterval = 24 * 3600,
        isAlive: (Int32) -> Bool = processIsAlive
    ) -> [URL] {
        let latest = latestByTerminal(entries.map(\.status))
        return entries.compactMap { entry in
            let s = entry.status
            let alive = s.pid.map(isAlive) ?? false
            if alive && s.state != .ended { return nil }
            let superseded = s.terminalID.flatMap { latest[$0] }.map { $0.sessionID != s.sessionID } ?? true
            let old = now.timeIntervalSince(s.updatedAt) > grace
            return (superseded && !alive) || old ? entry.url : nil
        }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Watches a directory with a vnode DispatchSource (no polling). Atomic renames into the
/// directory fire `.write`; events are coalesced with a short debounce.
public final class DirectoryWatcher: @unchecked Sendable {
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval

    public init(url: URL, queue: DispatchQueue = .main, debounce: TimeInterval = 0.05, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    deinit { source?.cancel() }
}

/// Follows a growing file (a transcript) and delivers newly appended complete lines.
public final class FileTailer: @unchecked Sendable {
    public let url: URL
    private let queue: DispatchQueue
    private let onLines: @Sendable (String) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var remainder = Data()

    public init(url: URL, queue: DispatchQueue = .main, onLines: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.queue = queue
        self.onLines = onLines
    }

    /// Starts at the current end of file; only new lines are reported.
    public func start() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write], queue: queue)
        source.setEventHandler { [weak self] in self?.readNew() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    private func readNew() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; remainder = Data() }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offset += UInt64(data.count)
        var chunk = remainder + data
        if let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) {
            remainder = chunk[(lastNewline + 1)...]
            chunk = chunk[..<lastNewline]
            onLines(String(decoding: chunk, as: UTF8.self))
        } else {
            remainder = chunk
        }
    }

    deinit { source?.cancel() }
}
