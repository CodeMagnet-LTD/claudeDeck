import Foundation

/// Line ending style of a text file. The editor works on "\n" text and restores this on save.
public enum LineEnding: String, Sendable, Equatable {
    case lf
    case crlf

    public var sequence: String { self == .crlf ? "\r\n" : "\n" }

    /// The dominant style: CRLF when at least half of the line breaks are CRLF.
    public static func detect(_ text: String) -> LineEnding {
        var crlf = 0
        var lf = 0
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                if previous == 0x0D { crlf += 1 } else { lf += 1 }
            }
            previous = byte
        }
        return crlf > 0 && crlf >= lf ? .crlf : .lf
    }
}

/// A text file as the editor sees it.
public struct TextFileContents: Sendable, Equatable {
    /// Contents with every CRLF turned into "\n" (the trailing newline, if any, is kept as is).
    public var text: String
    public var lineEnding: LineEnding
    /// The file started with a UTF-8 byte order mark; it is written back.
    public var hasBOM: Bool

    public init(text: String, lineEnding: LineEnding = .lf, hasBOM: Bool = false) {
        self.text = text
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    /// Decodes file bytes (the checks `TextFileIO.read` makes, minus the size limit).
    public static func decode(_ data: Data) throws(TextFileError) -> TextFileContents {
        if data.contains(0) { throw .binary }
        var bytes = data
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        if bom { bytes = bytes.dropFirst(3) }
        guard let raw = String(bytes: bytes, encoding: .utf8) else { throw .notUTF8 }
        let ending = LineEnding.detect(raw)
        let text = raw.contains("\r\n") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        return TextFileContents(text: text, lineEnding: ending, hasBOM: bom)
    }

    /// The bytes to write for `text` in this file's style.
    public func encoded() -> Data {
        var out = lineEnding == .crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        if lineEnding == .crlf {
            // "\r\n" already in the text (pasted) must not become "\r\r\n".
            out = out.replacingOccurrences(of: "\r\r\n", with: "\r\n")
        }
        var data = Data(out.utf8)
        if hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }
}

public enum TextFileError: Error, Equatable, Sendable {
    case notAFile
    case tooLarge(bytes: Int)
    case binary
    case notUTF8
    case io(String)

    public var message: String {
        switch self {
        case .notAFile: String(localized: "This is not a regular file.")
        case .tooLarge: String(localized: "The file is too large to edit here (maximum 8 MB).")
        case .binary: String(localized: "This looks like a binary file.")
        case .notUTF8: String(localized: "The file is not UTF-8 text.")
        case .io(let text): text
        }
    }
}

/// Reading and saving text files for the built-in editor.
/// Adapted from MonoCode (MIT) `read_text_file` / `write_text_file`.
public enum TextFileIO {
    public static let maxBytes = 8 * 1024 * 1024

    public static func read(_ url: URL) throws(TextFileError) -> TextFileContents {
        let size: Int
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw TextFileError.notAFile }
            size = values.fileSize ?? 0
        } catch let error as TextFileError {
            throw error
        } catch {
            throw .io(error.localizedDescription)
        }
        guard size <= maxBytes else { throw .tooLarge(bytes: size) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw .io(error.localizedDescription) }
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count) }
        return try TextFileContents.decode(data)
    }

    /// Cheap check for double-click: small enough, and the first 8 KB have no NUL and decode as UTF-8.
    public static func looksEditable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        if head.contains(0) { return false }
        // The sample may end inside a multi-byte character: allow up to 3 trailing bytes to fail.
        for cut in 0...min(3, head.count) {
            if String(bytes: head.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// Writes `contents` atomically: a temporary file in the same directory, then rename(2) over the
    /// target. Symlinks are followed (the link keeps pointing at the edited file) and the target's
    /// POSIX permissions are kept. Returns the path actually written.
    @discardableResult
    public static func write(_ contents: TextFileContents, to url: URL) throws(TextFileError) -> URL {
        let data = contents.encoded()
        guard data.count <= maxBytes else { throw .tooLarge(bytes: data.count) }
        let fm = FileManager.default
        let destination = fm.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath() : url
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue { throw .notAFile }
        let dir = destination.deletingLastPathComponent()
        let temp = dir.appending(path: ".\(destination.lastPathComponent).claudedeck-\(getpid())-\(UUID().uuidString.prefix(8)).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: nil) else {
            throw .io(String(localized: "Couldn’t create a temporary file in \(dir.path)."))
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if let perms = try? fm.attributesOfItem(atPath: destination.path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: temp.path)
            }
            guard rename(temp.path, destination.path) == 0 else {
                throw TextFileError.io(String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: temp)
            if let error = error as? TextFileError { throw error }
            throw .io(error.localizedDescription)
        }
        return destination
    }
}

/// Indentation of a source file.
public struct Indentation: Sendable, Equatable {
    public var usesTabs: Bool
    public var width: Int

    public init(usesTabs: Bool = false, width: Int = 4) {
        self.usesTabs = usesTabs
        self.width = width
    }

    /// What one Tab key press inserts.
    public var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }

    /// Guesses from the file: tabs if more indented lines start with a tab; otherwise the most common
    /// step between consecutive space indents (2, 4 or 8), 4 if there is nothing to go by.
    public static func detect(_ text: String, default fallback: Indentation = Indentation()) -> Indentation {
        var tabs = 0
        var spaces = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var lines = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines += 1
            if lines > 5000 { break }
            if line.first == "\t" { tabs += 1; continue }
            let count = line.prefix { $0 == " " }.count
            guard count < line.count else { continue } // whitespace-only line
            if count > 0 { spaces += 1 }
            let step = abs(count - previous)
            if step == 2 || step == 4 || step == 8 { steps[step, default: 0] += 1 }
            previous = count
        }
        if tabs > spaces { return Indentation(usesTabs: true, width: fallback.width) }
        guard spaces > 0, let best = steps.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) else {
            return fallback
        }
        return Indentation(usesTabs: false, width: best.key)
    }
}

/// Watches one file for changes, surviving atomic replaces (rename over the path) by other editors.
public final class FileChangeWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "claudedeck.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() { queue.async { self.arm(attempt: 0) } }

    public func stop() {
        queue.async {
            self.stopped = true
            self.pending?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    deinit { source?.cancel() }

    private func arm(attempt: Int) {
        guard !stopped else { return }
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-replace or deleted: try again for a while (the file may come back).
            if attempt < 40 { queue.asyncAfter(deadline: .now() + 0.25) { self.arm(attempt: attempt + 1) } }
            if attempt == 1 { fire() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, let src = self.source else { return }
            let events = src.data
            if events.contains(.delete) || events.contains(.rename) {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.arm(attempt: 0) }
            }
            self.fire()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        if attempt > 0 { fire() }
    }

    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
