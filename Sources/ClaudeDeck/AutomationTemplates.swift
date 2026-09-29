import ClaudeDeckCore
import Foundation

/// A ready-made automation: name, description, prompt and a suggested schedule.
struct AutomationTemplate: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let trigger: AutomationTrigger
    let prompt: String

    func makeAutomation(projectID: UUID?) -> Automation {
        Automation(name: name, prompt: prompt, projectID: projectID, triggers: [trigger])
    }

    // Prompts adapted from MonoCode (MIT, Copyright (c) 2026 Nick), automationTemplates.ts.
    // They are sent to Claude as-is, so they stay in English.
    static let all: [AutomationTemplate] = [
        AutomationTemplate(
            id: "find-critical-bugs",
            name: String(localized: "Find critical bugs"),
            summary: String(localized: "Review recent commits for high-severity correctness bugs and fix the safe ones."),
            symbol: "ladybug",
            trigger: .weekdays(ClockTime(hour: 9, minute: 0)),
            prompt: """
            Review recent git history in this repo for high-severity correctness bugs.

            Focus on:
            - Logic errors, race conditions, and data loss
            - Broken error handling that can fail silently in production
            - Regressions introduced in the last few days of commits

            Only report issues you can validate from the current code. If a fix is clearly safe and local, implement it. Skip style nits and speculative issues.

            At the end, summarize what you found, what you changed, and anything that still needs a human.
            """
        ),
        AutomationTemplate(
            id: "dependency-audit",
            name: String(localized: "Audit dependencies"),
            summary: String(localized: "Check manifests and lockfiles for vulnerable, unused or unexpectedly upgraded packages."),
            symbol: "shippingbox",
            trigger: .weekly(weekday: 2, ClockTime(hour: 9, minute: 30)),
            prompt: """
            Audit this repo's dependencies.

            - Inspect lockfiles and package manifests for vulnerable, unused, or unexpectedly upgraded packages
            - Confirm findings against the project's current tooling (npm, cargo, swift package, etc.)
            - Only propose upgrades or removals you can justify
            - Do not bump majors unless the current version is unsafe and the upgrade is clearly required

            Report what is risky, what you changed, and what still needs a human.
            """
        ),
        AutomationTemplate(
            id: "weekly-changelog",
            name: String(localized: "Weekly changelog"),
            summary: String(localized: "Summarize the week's commits into a changelog people can read."),
            symbol: "doc.text",
            trigger: .weekly(weekday: 6, ClockTime(hour: 16, minute: 0)),
            prompt: """
            Write a concise changelog for this repo covering the last 7 days of commits.

            Group by user-facing changes, fixes, and internal work. Skip noise (formatting, lockfile-only, merge commits). Use the project's existing changelog or docs style if one exists; otherwise write a short markdown summary. Do not invent features that are not in the commits.
            """
        ),
        AutomationTemplate(
            id: "triage-todos",
            name: String(localized: "Triage TODOs"),
            summary: String(localized: "Collect TODO / FIXME comments, resolve the trivial ones and rank the rest."),
            symbol: "checklist",
            trigger: .weekly(weekday: 4, ClockTime(hour: 10, minute: 0)),
            prompt: """
            Find the TODO, FIXME, HACK and XXX comments in this repo (skip vendored and generated code).

            - Group them by area and estimate the effort and risk of each
            - Resolve the ones that are trivial, clearly correct and local; remove comments that are obsolete
            - Do not start large refactors

            Finish with a ranked list of the remaining items, with file paths and a one-line suggestion for each.
            """
        ),
        AutomationTemplate(
            id: "test-health",
            name: String(localized: "Test health"),
            summary: String(localized: "Run the tests, lint and type checks and diagnose anything that is red."),
            symbol: "checkmark.seal",
            trigger: .weekdays(ClockTime(hour: 8, minute: 30)),
            prompt: """
            Run the project's existing test / lint / typecheck commands.

            If something fails:
            - Identify the first real failure, not the cascade
            - Fix it if the cause is local and obvious
            - Otherwise write a short diagnosis with the command, the error, and the suspected file

            Do not add new test infrastructure. Do not "fix" flakes by weakening assertions.
            """
        ),
    ]
}
