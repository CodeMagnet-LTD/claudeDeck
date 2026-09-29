import CoreServices
import Foundation

/// Recursive file-level watcher over one or more directory trees (FSEvents). Events are batched
/// by FSEvents itself (`latency`) and delivered on `queue`. The stream stops when the watcher is
/// released.
public final class FSEventsWatcher: @unchecked Sendable {
    public struct Event: Sendable {
        /// Real (symlink-resolved) path.
        public var path: String
        /// The kernel dropped events below `path`: rescan it.
        public var mustRescan: Bool
    }

    /// Owned by the stream (retained through the context), so a late callback never reaches a freed watcher.
    private final class Handler: @unchecked Sendable {
        let onEvents: @Sendable ([Event]) -> Void
        init(_ onEvents: @escaping @Sendable ([Event]) -> Void) { self.onEvents = onEvents }
    }

    public let paths: [String]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: Handler
    private var stream: FSEventStreamRef?

    public init(paths: [URL], latency: TimeInterval = 0.2, queue: DispatchQueue = .main,
                onEvents: @escaping @Sendable ([Event]) -> Void) {
        self.paths = paths.map(\.path)
        self.latency = latency
        self.queue = queue
        self.handler = Handler(onEvents)
    }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(handler).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<AnyObject>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let path = array[i] as? String else { continue }
                let f = flags[i]
                let rescan = f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || f & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                events.append(Event(path: path, mustRescan: rescan))
            }
            handler.onEvents(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            Unmanaged.passUnretained(handler).release()   // balance passRetained: the stream never took it
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)   // releases the handler via the context's release callback
        self.stream = nil
    }

    deinit { stop() }
}
