import ClaudeDeckCore
import Foundation
import Observation
import os

private let usageLog = Logger(subsystem: "co.codemagnet.ClaudeDeck", category: "usage")

/// Polls the Claude plan's 5-hour / weekly usage while the app runs.
///
/// Uses Claude Code's own OAuth access token strictly read-only: it is read from the Keychain item
/// (or `~/.claude/.credentials.json`) for each request, never refreshed, rotated, stored or logged.
/// Missing or expired credentials make the meter "unavailable" (hidden) — Claude Code refreshes
/// its token itself the next time it runs.
@MainActor
@Observable
final class UsageMonitor {
    private(set) var state: UsageState = .idle
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastFetch: Date = .distantPast
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: true)
                let delay = ClaudeUsageAPI.nextDelay(failures: self?.failures ?? 0)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Fetches now unless a fetch happened within the last minute (opening the popover, or right
    /// before continuing a session that hit the limit).
    func refresh(force: Bool = false) async {
        if let inFlight { return await inFlight.value }
        guard force || Date().timeIntervalSince(lastFetch) > 60 else { return }
        let task = Task { await fetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func fetch() async {
        lastFetch = Date()
        if AppModel.isDemo {
            state = .ok(Self.demoUsage())
            return
        }
        let result = await Task.detached(priority: .utility) { await Self.load() }.value
        switch result {
        case .usage(let usage):
            failures = 0
            state = usage.isEmpty ? .unavailable : .ok(usage)
        case .unavailable:
            failures = 0
            state = .unavailable
        case .failed(let reason):
            failures += 1
            usageLog.info("Usage fetch failed: \(reason, privacy: .public)")
            state = .failed(last: state.usage)
        }
    }

    private enum LoadResult: Sendable {
        case usage(ClaudeUsage)
        case unavailable
        case failed(String)
    }

    /// Off the main actor: read the token, call the endpoint. The token stays in this function.
    nonisolated private static func load() async -> LoadResult {
        guard let token = readAccessToken() else { return .unavailable }
        var request = URLRequest(url: ClaudeUsageAPI.url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ClaudeUsageAPI.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(ClaudeUsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 401: Claude Code's token expired or was revoked; 403: no plan usage for this account.
            if status == 401 || status == 403 { return .unavailable }
            guard (200..<300).contains(status) else { return .failed("HTTP \(status)") }
            guard let usage = ClaudeUsageAPI.parse(data) else { return .failed("unreadable response") }
            return .usage(usage)
        } catch {
            return .failed((error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "request error")
        }
    }

    /// Claude Code keeps its credentials in the login Keychain ("Claude Code-credentials") on macOS,
    /// elsewhere in `~/.claude/.credentials.json`. Read through `security`, the same tool Claude Code uses.
    nonisolated private static func readAccessToken() -> String? {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        for account in [nil, user] {
            var args = ["find-generic-password", "-s", ClaudeUsageAPI.keychainService]
            if let account { args += ["-a", account] }
            args.append("-w")
            if let blob = runSecurity(args), let token = ClaudeUsageAPI.accessToken(fromCredentials: blob) {
                return token
            }
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        guard let blob = try? Data(contentsOf: file) else { return nil }
        return ClaudeUsageAPI.accessToken(fromCredentials: blob)
    }

    nonisolated private static func runSecurity(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read while it runs (a full pipe would block it); never hang on a Keychain prompt: 5 s.
        let box = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? box.data : nil
    }

    private final class DataBox: @unchecked Sendable { var data: Data? }

    /// Fixture for tools/demo.sh (no Keychain, no network).
    private static func demoUsage() -> ClaudeUsage {
        let now = Date()
        return ClaudeUsage(
            fiveHour: UsageWindow(usedPercent: 62, resetsAt: now.addingTimeInterval(80 * 60)),
            sevenDay: UsageWindow(usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86400 + 6 * 3600)),
            fetchedAt: now
        )
    }
}
