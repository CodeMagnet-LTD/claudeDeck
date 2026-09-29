import AppKit
import ClaudeDeckCore
import SwiftUI

/// The Automations window: saved prompts that start Claude sessions on a schedule or on demand.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            AutomationList(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            if let id = selection, model.deck.automation(id) != nil {
                AutomationEditor(automationID: id)
                    .id(id)
            } else {
                AutomationEmptyState(selection: $selection)
            }
        }
        .toolbar {
            ToolbarItem {
                AddAutomationMenu(selection: $selection)
            }
        }
        .onAppear {
            if selection == nil { selection = model.deck.automations.first?.id }
        }
    }
}

// MARK: - List

private struct AutomationList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.deck.automations) { automation in
                AutomationRow(automation: automation).tag(automation.id)
                    .contextMenu {
                        Button("Run Now") { model.automations?.runNow(automation.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { AutomationActions.delete(automation, model: model, selection: $selection) }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.deck.automations.isEmpty {
                Text("No Automations").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Label("Automations run only while ClaudeDeck is running. Keep it in the menu bar and open it at login to never miss one.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}

private struct AutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(
                get: { automation.enabled },
                set: { on in AutomationActions.update(automation.id, model: model, reschedule: true) { $0.enabled = on } }
            )) { Text(automation.name) }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name.isEmpty ? String(localized: "Untitled Automation") : automation.name)
                    .lineLimit(1)
                Group {
                    if let next = automation.nextRunAt, automation.enabled {
                        Text("Next: \(next.formatted(AutomationFormat.nextRun))")
                    } else if !automation.enabled {
                        Text("Off")
                    } else {
                        Text("Not scheduled")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let status = automation.lastRunStatus {
                    RunStatusBadge(status: status)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddAutomationMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        Menu {
            Button("Blank Automation") { add(Automation(projectID: defaultProject)) }
            Section("Templates") {
                ForEach(AutomationTemplate.all) { template in
                    Button {
                        add(template.makeAutomation(projectID: defaultProject))
                    } label: {
                        Label(template.name, systemImage: template.symbol)
                    }
                }
            }
        } label: {
            Label("New Automation", systemImage: "plus")
        }
        .help("New automation")
    }

    private var defaultProject: UUID? { model.browsedProjectID ?? model.selectedProjectID ?? model.deck.projects.first?.id }

    private func add(_ automation: Automation) {
        var a = automation
        a.reschedule()
        model.mutate { $0.automations.append(a) }
        selection = a.id
    }
}

private struct AutomationEmptyState: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Automations").font(.title2.bold())
                Text("Saved prompts that start a Claude session on a schedule or when you click Run Now. Permission prompts show up in Needs Attention like any other session.")
                    .foregroundStyle(.secondary)
                Text("Start from a template").font(.headline).padding(.top, 6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    ForEach(AutomationTemplate.all) { template in
                        Button {
                            var a = template.makeAutomation(projectID: model.browsedProjectID ?? model.deck.projects.first?.id)
                            a.reschedule()
                            model.mutate { $0.automations.append(a) }
                            selection = a.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(template.name, systemImage: template.symbol).font(.headline)
                                Text(template.summary).font(.callout).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Text(template.trigger.sentence).font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

// MARK: - Editor

private struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    let automationID: UUID

    var body: some View {
        if let automation = model.deck.automation(automationID) {
            Form {
                Section {
                    TextField("Name", text: bind(\.name))
                    Picker("Project", selection: bind(\.projectID, reschedule: true)) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.deck.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Toggle("Enabled", isOn: bind(\.enabled, reschedule: true))
                }
                Section("Prompt") {
                    TextEditor(text: bind(\.prompt))
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                }
                Section {
                    ForEach(Array(automation.triggers.enumerated()), id: \.offset) { index, _ in
                        TriggerRow(trigger: triggerBinding(index)) {
                            AutomationActions.update(automationID, model: model, reschedule: true) { $0.triggers.remove(at: index) }
                        }
                    }
                    Button {
                        AutomationActions.update(automationID, model: model, reschedule: true) {
                            $0.triggers.append(.weekdays(ClockTime(hour: 9, minute: 0)))
                        }
                    } label: {
                        Label("Add Schedule", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Schedule")
                } footer: {
                    if let next = automation.nextRunAt, automation.enabled {
                        Text("Next run: \(next.formatted(AutomationFormat.nextRun))")
                    } else if automation.triggers.isEmpty {
                        Text("No schedule: runs only with Run Now.")
                    }
                }
                Section("Run") {
                    Picker("Workspace", selection: bind(\.workspace)) {
                        Text("Project folder").tag(AutomationWorkspace.current)
                        Text("New git worktree for each run").tag(AutomationWorkspace.newWorktree)
                    }
                    Picker("Conversation", selection: bind(\.reuseSession)) {
                        Text("Start fresh each run").tag(false)
                        Text("Continue the last run's session").tag(true)
                    }
                    Picker("If missed", selection: bind(\.missedRunGraceMinutes)) {
                        Text("Skip unless within 15 minutes").tag(15)
                        Text("Skip unless within 1 hour").tag(60)
                        Text("Skip unless within 12 hours").tag(720)
                        Text("Skip unless within 1 day").tag(1440)
                        if ![15, 60, 720, 1440].contains(automation.missedRunGraceMinutes) {
                            Text("Skip unless within \(automation.missedRunGraceMinutes) minutes").tag(automation.missedRunGraceMinutes)
                        }
                    }
                    .help("A scheduled run found later than this (Mac asleep, ClaudeDeck not running) is skipped.")
                }
                Section {
                    HStack {
                        Button {
                            model.automations?.runNow(automationID)
                        } label: {
                            Label("Run Now", systemImage: "play.fill")
                        }
                        .disabled(automation.projectID == nil || automation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (model.automations?.isActive(automationID) ?? false))
                        Spacer()
                        Button("Delete…", role: .destructive) {
                            AutomationActions.delete(automation, model: model, selection: nil)
                        }
                    }
                    Text("Automations run only while ClaudeDeck is running (menu bar mode and opening at login keep it alive).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RunHistory(automationID: automationID)
            }
            .formStyle(.grouped)
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<Automation, T>, reschedule: Bool = false) -> Binding<T> {
        // Fallback keeps a binding read during teardown (just deleted) from crashing.
        let fallback = model.deck.automation(automationID) ?? Automation(id: automationID)
        return Binding(
            get: { (model.deck.automation(automationID) ?? fallback)[keyPath: keyPath] },
            set: { value in AutomationActions.update(automationID, model: model, reschedule: reschedule) { $0[keyPath: keyPath] = value } }
        )
    }

    private func triggerBinding(_ index: Int) -> Binding<AutomationTrigger> {
        Binding(
            get: {
                let triggers = model.deck.automation(automationID)?.triggers ?? []
                return index < triggers.count ? triggers[index] : .daily(ClockTime(hour: 9, minute: 0))
            },
            set: { value in
                AutomationActions.update(automationID, model: model, reschedule: true) {
                    if index < $0.triggers.count { $0.triggers[index] = value }
                }
            }
        )
    }
}

/// One schedule as editable parts, with the resulting sentence ("Every weekday at 09:00").
private struct TriggerRow: View {
    @Binding var trigger: AutomationTrigger
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Repeat", selection: Binding(get: { trigger.schedule }, set: { trigger = trigger.with(schedule: $0) })) {
                    ForEach(AutomationTrigger.Schedule.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if case .weekly = trigger {
                    Picker("Day", selection: Binding(get: { trigger.weekday }, set: { trigger = trigger.with(weekday: $0) })) {
                        ForEach(AutomationFormat.orderedWeekdays, id: \.self) { Text(AutomationFormat.weekdayName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if case .hourly = trigger {
                    Picker("Minute", selection: Binding(get: { trigger.time.minute }, set: { trigger = .hourly(minute: $0) })) {
                        ForEach(Array(stride(from: 0, to: 60, by: 5)) + (trigger.time.minute % 5 == 0 ? [] : [trigger.time.minute]), id: \.self) {
                            Text(String(format: ":%02d", $0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    DatePicker("Time", selection: Binding(
                        get: { AutomationFormat.date(for: trigger.time) },
                        set: { trigger = trigger.with(time: AutomationFormat.clock(from: $0)) }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove schedule")
            }
            Text(trigger.sentence).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RunHistory: View {
    @Environment(AppModel.self) private var model
    let automationID: UUID

    var body: some View {
        let runs = model.deck.runs(of: automationID)
        Section("History") {
            if runs.isEmpty {
                Text("No runs yet").foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                HStack(alignment: .top, spacing: 8) {
                    RunStatusBadge(status: run.status)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(run.trigger == .manual ? String(localized: "· manual") : String(localized: "· scheduled"))
                                .foregroundStyle(.secondary)
                        }
                        if let error = run.error {
                            Text(AutomationFormat.localizedError(error)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !run.status.isFinished {
                        Button("Stop Following") { model.automations?.cancel(run.id) }
                            .buttonStyle(.borderless)
                            .help("Stop tracking this run; the session keeps going.")
                    }
                    // A fresh-run session is dropped once a later run replaces it (AutomationScheduler).
                    if let sid = run.sessionID, model.deck.session(sid) != nil {
                        Button("Open Session") {
                            model.openMainWindow?()
                            model.reveal(sid)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.deck.session(sid) == nil)
                    }
                }
            }
        }
    }
}

private struct RunStatusBadge: View {
    let status: AutomationRunStatus

    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}

// MARK: - Actions & formatting

@MainActor
enum AutomationActions {
    /// Edits an automation; recomputes the next run when the schedule changed (or the automation
    /// became schedulable / unschedulable), so a stale time neither fires nor counts as missed.
    static func update(_ id: UUID, model: AppModel, reschedule: Bool, _ change: @escaping (inout Automation) -> Void) {
        model.mutate { deck in
            deck.updateAutomation(id) { a in
                change(&a)
                a.updatedAt = Date()
                if reschedule || a.isSchedulable != (a.nextRunAt != nil) { a.reschedule() }
            }
        }
    }

    static func delete(_ automation: Automation, model: AppModel, selection: Binding<UUID?>?) {
        let name = automation.name.isEmpty ? String(localized: "Untitled Automation") : automation.name
        guard Confirm.ask(String(localized: "Delete “\(name)”?"), detail: String(localized: "Its run history is deleted too. Sessions it started stay in the sidebar."),
                          action: String(localized: "Delete")) else { return }
        model.mutate { $0.removeAutomation(automation.id) }
        if selection?.wrappedValue == automation.id { selection?.wrappedValue = model.deck.automations.first?.id }
    }
}

enum AutomationFormat {
    static let nextRun = Date.FormatStyle(date: .abbreviated, time: .shortened)

    static func time(_ t: ClockTime) -> String {
        date(for: t).formatted(date: .omitted, time: .shortened)
    }

    static func date(for t: ClockTime) -> Date {
        Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
    }

    static func clock(from date: Date) -> ClockTime {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return ClockTime(hour: c.hour ?? 9, minute: c.minute ?? 0)
    }

    /// Calendar weekdays (1 = Sunday) starting at the user's first weekday.
    static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    static func weekdayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[(weekday - 1 + 7) % 7]
    }

    /// Core writes English error texts; show the translated one when there is one.
    static func localizedError(_ error: String) -> String {
        switch error {
        case "Missed the scheduled run beyond its grace period.": String(localized: "Missed the scheduled run beyond its grace period.")
        case "The previous run was still in progress.": String(localized: "The previous run was still in progress.")
        case "Interrupted when ClaudeDeck quit.": String(localized: "Interrupted when ClaudeDeck quit.")
        default: error
        }
    }
}

extension AutomationTrigger {
    enum Schedule: CaseIterable {
        case hourly, daily, weekdays, weekly

        var title: String {
            switch self {
            case .hourly: String(localized: "Every hour")
            case .daily: String(localized: "Every day")
            case .weekdays: String(localized: "Every weekday")
            case .weekly: String(localized: "Every week")
            }
        }
    }

    var schedule: Schedule {
        switch self {
        case .hourly: .hourly
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekly: .weekly
        }
    }

    var time: ClockTime {
        switch self {
        case .hourly(let minute): ClockTime(hour: 9, minute: minute)
        case .daily(let t), .weekdays(let t), .weekly(_, let t): t
        }
    }

    var weekday: Int {
        if case .weekly(let day, _) = self { day } else { 2 }
    }

    func with(schedule: Schedule) -> AutomationTrigger {
        switch schedule {
        case .hourly: .hourly(minute: time.minute)
        case .daily: .daily(time)
        case .weekdays: .weekdays(time)
        case .weekly: .weekly(weekday: weekday, time)
        }
    }

    func with(time: ClockTime) -> AutomationTrigger {
        switch self {
        case .hourly: .hourly(minute: time.minute)
        case .daily: .daily(time)
        case .weekdays: .weekdays(time)
        case .weekly(let day, _): .weekly(weekday: day, time)
        }
    }

    func with(weekday: Int) -> AutomationTrigger {
        .weekly(weekday: weekday, time)
    }

    /// "Every weekday at 09:00".
    var sentence: String {
        switch self {
        case .hourly(let minute): String(localized: "Every hour at :\(String(format: "%02d", minute))")
        case .daily(let t): String(localized: "Every day at \(AutomationFormat.time(t))")
        case .weekdays(let t): String(localized: "Every weekday at \(AutomationFormat.time(t))")
        case .weekly(let day, let t): String(localized: "Every \(AutomationFormat.weekdayName(day)) at \(AutomationFormat.time(t))")
        }
    }
}

extension AutomationRunStatus {
    var title: String {
        switch self {
        case .pending: String(localized: "Starting")
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .skipped: String(localized: "Skipped")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .running: "play.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "forward.fill"
        case .cancelled: "stop.circle"
        }
    }

    var color: Color {
        switch self {
        case .pending, .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .skipped, .cancelled: .secondary
        }
    }
}

/// Menu item that opens the Automations window (commands can't read `openWindow` directly).
struct OpenAutomationsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Automations…") {
            openWindow(id: "automations")
            NSApp.activate()
        }
    }
}
