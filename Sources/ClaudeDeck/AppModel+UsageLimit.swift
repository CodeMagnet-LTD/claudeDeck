import ClaudeDeckCore
import Foundation
import os

private let limitLog = Logger(subsystem: "co.codemagnet.ClaudeDeck", category: "usage-limit")

/// A session that stopped on the plan's usage limit.
struct UsageLimitHit: Equatable {
    /// The limit entry's transcript timestamp — identifies the limit event.
    var at: Date
    /// From the limit message ("resets 3:20am (Europe/Istanbul)"); nil = use the usage API's reset.
    var resetsAt: Date?
}

/// Sessions that stop on the usage limit get the "continue" message once the limit resets
/// (Settings › Sessions), at most once per limit event.
extension AppModel {
    /// A little after the reset, so the first request doesn't race the window rolling over.
    static let usageLimitGrace: TimeInterval = 60

    func receiveUsageLimit(_ event: UsageLimitEvent, for id: UUID) {
        switch event {
        case .hit(let at, let resetsAt):
            guard usageLimitHits[id]?.at != at else { return }
            // The same reset we already continued for: our continue came too early (wrong time
            // zone, clock skew). Don't trust the message again — wait for the usage API instead.
            let reset = resetsAt == continuedLimitResets[id] ? nil : resetsAt
            usageLimitHits[id] = UsageLimitHit(at: at, resetsAt: reset)
            limitLog.info("Session \(id, privacy: .public) hit the usage limit")
            scheduleUsageLimitChecks()
        case .cleared(let at):
            if let hit = usageLimitHits[id], at > hit.at { usageLimitHits[id] = nil }
        }
    }

    /// When the session's limit resets: the message's time, else the usage API's exhausted window.
    func usageLimitReset(for id: UUID) -> Date? {
        guard let hit = usageLimitHits[id] else { return nil }
        return hit.resetsAt ?? usage.state.usage?.exhaustedUntil
    }

    private func scheduleUsageLimitChecks() {
        guard usageLimitTask == nil else { return }
        usageLimitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !self.usageLimitHits.isEmpty else { break }
                await self.continueSessionsPastTheirLimit()
            }
            self?.usageLimitTask = nil
        }
    }

    private func continueSessionsPastTheirLimit() async {
        guard deck.settings.continueAfterUsageLimit else { return }
        let now = Date()
        let due = usageLimitHits.keys.filter { id in
            guard let reset = usageLimitReset(for: id) else { return false }
            return now >= reset.addingTimeInterval(Self.usageLimitGrace)
        }
        guard !due.isEmpty else { return }
        // Make sure the plan really is usable again; otherwise wait for the API's reset time.
        await usage.refresh()
        if let until = usage.state.usage?.exhaustedUntil, until > Date() {
            for id in due { usageLimitHits[id]?.resetsAt = until }
            return
        }
        for id in due {
            guard let hit = usageLimitHits[id], let reset = usageLimitReset(for: id) else { continue }
            guard terminals.isRunning(id) else { usageLimitHits[id] = nil; continue }
            // Still sitting at the prompt (the user hasn't carried on or been asked something).
            // (StopFailure leaves it idle; a hook older than the hit means nothing happened since.)
            let display = status(of: id).display
            if display.isBlocked { continue }
            if !display.isIdle, let hook = hookStatuses[id], hook.updatedAt > hit.at {
                usageLimitHits[id] = nil // working again
                continue
            }
            usageLimitHits[id] = nil
            continuedLimitResets[id] = reset
            limitLog.info("Continuing session \(id, privacy: .public) after the usage limit reset")
            Task { await sendContinueMessage(id) }
        }
    }
}
