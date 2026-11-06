import ClaudeDeckCore
import SwiftUI

/// Settings → Agents: the xAI key and the agents (Grok bots) to ask about a session.
struct AgentsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var key = AgentKeychain.xaiKey ?? ""
    @State private var editing: AgentProfile?
    @State private var showLog = false
    @State private var copied = false

    var body: some View {
        if !model.pendingAgents.isEmpty { pendingSection }
        Section {
            SecureField("xAI API key", text: $key, prompt: Text("xai-…"))
                .onSubmit { AgentKeychain.setXAIKey(key) }
                .onChange(of: key) { _, value in AgentKeychain.setXAIKey(value) }
            ForEach(model.agents) { agent in
                HStack {
                    Image(systemName: agent.usesWebhook ? "link" : "sparkles").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                        Text(agent.usesWebhook ? (agent.webhookURL ?? "") : (agent.model.isEmpty ? String(localized: "No model picked") : agent.model))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Edit…") { editing = agent }
                    Button(role: .destructive) {
                        model.mutate(userInitiated: false) { $0.settings.agents.removeAll { $0.id == agent.id } }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add Agent…") { editing = AgentProfile(name: String(localized: "New Agent")) }
            apiRows
            Button("Activity Log…") { showLog = true }
        } header: {
            Text("Agents")
        } footer: {
            Text("Grok bots (a system prompt and a model, through the xAI API) or any service behind a webhook. Ask them about a session from its menu or the phone; their answers come back as notes, and you choose whether Claude gets them. The session's last message, Claude's answer and the uncommitted changes are sent to the agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { agent in AgentEditor(agent: agent) }
        .sheet(isPresented: $showLog) { AgentActivityLog() }
    }

    /// Agents that signed themselves up through the local API: nothing reaches them until approved.
    private var pendingSection: some View {
        Section {
            ForEach(model.pendingAgents) { record in PendingAgentForm(record: record) }
        } header: {
            Text("Agents Waiting for Approval")
        } footer: {
            Text("They asked through the local API. Approved, an agent gets webhook requests and shows in Ask Agent; it may not type into Claude and follows no project until you change that.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The local API: on/off, port, token.
    @ViewBuilder
    private var apiRows: some View {
        Toggle("Local API for agents on this Mac (127.0.0.1)", isOn: Binding(
            get: { model.deck.settings.agentAPIEnabled },
            set: { on in
                model.mutate(userInitiated: false) { $0.settings.agentAPIEnabled = on }
                model.agentAPI.refresh()
            }
        ))
        if model.deck.settings.agentAPIEnabled {
            LabeledContent("Port") {
                TextField("Port", value: Binding(
                    get: { model.deck.settings.agentAPIPort },
                    set: { port in
                        model.mutate(userInitiated: false) { $0.settings.agentAPIPort = port }
                        model.agentAPI.refresh()
                    }
                ), format: .number.grouping(.never))
                .frame(width: 80)
                .labelsHidden()
            }
            LabeledContent("Status") {
                switch model.agentAPI.state {
                case .off: Text("Off").foregroundStyle(.secondary)
                case .listening(let port): Text(verbatim: "http://127.0.0.1:\(port)").textSelection(.enabled)
                case .failed(let reason): Text(reason).foregroundStyle(.orange)
                }
            }
            LabeledContent("Bearer token") {
                HStack {
                    Text(model.agentAPI.token.map { String($0.prefix(6)) + "…" } ?? "-").font(.body.monospaced()).foregroundStyle(.secondary)
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.agentAPI.token ?? "", forType: .string)
                        copied = true
                    }
                    Button("Regenerate…") {
                        if Confirm.ask(String(localized: "Regenerate the token?"),
                                             detail: String(localized: "Agents using the old token stop working until they get the new one."),
                                             action: String(localized: "Regenerate")) {
                            model.agentAPI.regenerateToken()
                            copied = false
                        }
                    }
                }
            }
        }
    }
}

/// Above the sidebar's waiting tray while agents that signed themselves up wait for approval:
/// decided here without opening Settings.
struct PendingAgentsTray: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.pendingAgents
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "person.badge.clock").foregroundStyle(.orange)
                Text("Agents Waiting for Approval · \(pending.count)").sidebarFont(.callout, weight: .semibold)
                Spacer()
            }
            .padding(.horizontal, 14)
            .sidebarRowPadding(7)
            VStack(spacing: 2) {
                ForEach(pending) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.name).fontWeight(.semibold).lineLimit(1)
                        Text(record.host.isEmpty ? String(localized: "No webhook URL yet") : record.host)
                            .sidebarFont(.caption).foregroundStyle(record.host.isEmpty ? Color.orange : .secondary).lineLimit(1).help(record.url)
                        if !record.description.isEmpty {
                            Text(record.description).sidebarFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack {
                            if record.needs.isEmpty {
                                Button("Approve") { model.approveAgent(record.id) }
                            } else {
                                // URL and header to paste: the form, in a sheet (the tray is narrow).
                                Button("Fill In and Approve…") { model.agentSheet = .approve(record.id) }
                            }
                            Button("Reject", role: .destructive) { model.rejectAgent(record.id) }
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sidebarRowPadding(5)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .background(.bar)
        .animation(.snappy(duration: 0.25), value: pending.map(\.id))
    }
}

/// A pending agent with Approve / Reject; when it registered without a webhook URL (a Grok Bot
/// routine can't see its own), the URL and Authorization header to paste, checked as typed.
struct PendingAgentForm: View {
    @Environment(AppModel.self) private var model
    let record: AgentRegistration
    @State private var url = ""
    @State private var header = ""
    @State private var failure: String?

    var body: some View {
        let problem = AgentRegistry.completionProblem(record, url: url, authHeader: header)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: "person.badge.clock").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                    if !record.host.isEmpty { Text(record.host).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(record.url) }
                    if !record.description.isEmpty {
                        Text(record.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer()
                Button("Reject", role: .destructive) { model.rejectAgent(record.id) }
                Button("Approve") { failure = model.approveAgent(record.id, url: url, authHeader: header) }
                    .disabled(problem != nil)
            }
            if !record.needs.isEmpty {
                if record.needs.contains("url") {
                    HStack {
                        TextField("Webhook URL", text: $url, prompt: Text("https://…"))
                        Button("Paste from Clipboard") { url = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? url }
                    }
                }
                if record.needs.contains("auth_header") {
                    HStack {
                        SecureField("Authorization header", text: $header, prompt: Text("Bearer …"))
                        Button("Paste from Clipboard") { header = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? header }
                    }
                }
                if let problem, !(url.isEmpty && header.isEmpty) {
                    Text(problem.message).font(.caption).foregroundStyle(.orange)
                } else if problem != nil {
                    Text("It registered without its webhook address: paste the URL and header from the routine's panel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
    }
}

/// What went out to agents and what came in, newest first.
struct AgentActivityLog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Activity").font(.headline)
            List(model.agentActivity.reversed()) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.inbound ? "arrow.down.left" : "arrow.up.right")
                        .foregroundStyle(item.ok ? (item.inbound ? Color.green : Color.accentColor) : Color.orange)
                    Text(item.date, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.agent).font(.callout.weight(.semibold))
                    Text(item.summary).font(.callout).foregroundStyle(item.ok ? .primary : Color.orange).lineLimit(2).textSelection(.enabled)
                }
            }
            .overlay { if model.agentActivity.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 640, height: 460)
    }
}

struct AgentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var agent: AgentProfile
    @State private var models: [String] = []
    @State private var loadError: String?
    @State private var useWebhook = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var authorization = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent").font(.headline)
            Form {
                TextField("Name", text: $agent.name)
                Picker("Runs on", selection: $useWebhook) {
                    Text("xAI API (Grok)").tag(false)
                    Text("Webhook").tag(true)
                }
                .pickerStyle(.segmented)
                if useWebhook {
                    Toggle("Asynchronous (the answer comes later through the local API)", isOn: $agent.async)
                    TextField("Webhook URL", text: Binding(get: { agent.webhookURL ?? "" }, set: { agent.webhookURL = $0 }), prompt: Text("https://… or http://127.0.0.1:…"))
                    SecureField("Authorization header (optional)", text: $authorization, prompt: Text("Bearer …"))
                    Text("ClaudeDeck POSTs {agent, system, model, message} and shows {\"reply\": \"…\"} (or the plain text it answers).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        TextField("Model", text: $agent.model, prompt: Text("grok-…"))
                        Menu("Models") {
                            if models.isEmpty { Text(loadError ?? String(localized: "Loading…")) }
                            ForEach(models, id: \.self) { id in Button(id) { agent.model = id } }
                        }
                        .fixedSize()
                    }
                }
                Toggle("Asks by itself when a session finishes a turn or waits on a permission or a question", isOn: $agent.autoTrigger)
                if agent.autoTrigger {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Only in these projects").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(model.deck.projects) { project in
                                    Toggle(project.name, isOn: Binding(
                                        get: { agent.autoProjects.contains(project.id) },
                                        set: { on in
                                            agent.autoProjects.removeAll { $0 == project.id }
                                            if on { agent.autoProjects.append(project.id) }
                                        }
                                    ))
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                        if agent.autoProjects.isEmpty {
                            Text("No project chosen: it isn't asked by itself anywhere.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Toggle("May type into Claude through the local API (otherwise its texts become notes)", isOn: $agent.canSendDirectly)
                Toggle("Claude may ask it from its session (claudedeck-ask; the answer is a note for you)", isOn: $agent.claudeCanAsk)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions (system prompt)")
                    TextEditor(text: $agent.systemPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                }
            }
            .formStyle(.grouped)
            if let testResult {
                ScrollView { Text(testResult).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            HStack {
                Button(testing ? String(localized: "Testing…") : String(localized: "Test")) { test() }
                    .disabled(testing)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(agent.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 600, height: 680)
        .onAppear {
            useWebhook = agent.usesWebhook
            authorization = AgentKeychain.webhookAuthorization(agent.id) ?? ""
        }
        .task {
            do { models = try await AgentRunner.xaiModels() } catch { loadError = error.localizedDescription }
        }
    }

    private var edited: AgentProfile {
        var copy = agent
        copy.name = copy.name.trimmingCharacters(in: .whitespaces)
        if !useWebhook { copy.webhookURL = nil }
        return copy
    }

    private func save() {
        let profile = edited
        AgentKeychain.setWebhookAuthorization(useWebhook ? authorization : nil, for: profile.id)
        model.mutate(userInitiated: false) { deck in
            if let index = deck.settings.agents.firstIndex(where: { $0.id == profile.id }) {
                deck.settings.agents[index] = profile
            } else {
                deck.settings.agents.append(profile)
            }
        }
        dismiss()
    }

    private func test() {
        testing = true
        testResult = nil
        let profile = edited
        AgentKeychain.setWebhookAuthorization(useWebhook ? authorization : nil, for: profile.id)
        Task {
            do { testResult = try await AgentRunner.test(profile) }
            catch { testResult = error.localizedDescription }
            testing = false
        }
    }
}

/// The session menu's "Ask Agent" items.
struct AskAgentMenu: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID

    var body: some View {
        if !model.agents.isEmpty {
            Menu("Ask Agent") {
                ForEach(model.agents) { agent in
                    Button(agent.name) { ask([agent.id]) }
                }
                if model.agents.count > 1 {
                    Divider()
                    Button("All Agents") { ask(model.agents.map(\.id)) }
                }
                Divider()
                Button("Preview What's Sent…") { model.previewAgentRequest(model.agents.map(\.id), about: sessionID, request: "") }
            }
        }
        if !(model.agentReviewHistory[sessionID] ?? []).isEmpty {
            Button("Past Reviews…") { model.agentSheet = .history(session: sessionID) }
        }
    }

    private func ask(_ ids: [UUID]) {
        // What to look at is optional: Cancel asks nothing, an empty field asks for a review.
        guard let request = TextPrompt.ask(title: String(localized: "Ask Agent"), placeholder: String(localized: "What should it look at? (optional)"), allowEmpty: true) else { return }
        model.askAgents(ids, about: sessionID, request: request)
    }
}

/// Under a session's terminal: the agents' notes, with Send to Claude / Queue / Dismiss.
/// Agents' notes under a session's terminal: one line each (click to read it all), sending it on
/// in the menu, dismissing with the ×. As tall as the notes, scrolling past 220 pt.
struct AgentNotesStrip: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    @State private var expanded: Set<UUID> = []
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            notesList
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(max(contentHeight, 1), 220))
        .background(.bar)
    }

    private var notesList: some View {
        let notes = model.agentNotes[sessionID] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(notes) { note in
                let open = expanded.contains(note.id)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        Text(note.agentName).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                        if !open {
                            Text(summary(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if note.pending { ProgressView().controlSize(.mini) }
                        if let reply = note.reply {
                            Menu {
                                Button("Send to Claude") { model.agentNoteAction(note.id, in: sessionID, action: .sendToClaude) }
                                Button("Queue for Claude") { model.agentNoteAction(note.id, in: sessionID, action: .queueForClaude) }
                                Divider()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(reply, forType: .string)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Send it on to Claude, or queue it for Claude's next turn")
                        }
                        Button { model.agentNoteAction(note.id, in: sessionID, action: .dismiss) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                    .controlSize(.small)
                    if open {
                        if !note.request.isEmpty { Text(note.request).font(.caption).foregroundStyle(.secondary) }
                        if let reply = note.reply {
                            Text(reply)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let error = note.error {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let failure = note.actionError {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture { if open { expanded.remove(note.id) } else { expanded.insert(note.id) } }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func summary(_ note: AgentNote) -> String {
        if let reply = note.reply { return reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply }
        if let error = note.error { return error }
        return String(localized: "Thinking…")
    }
}

/// The agents sheet: what would be sent (then send it), or a session's past reviews.
struct AgentSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sheet: AgentSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch sheet {
            case .preview(let session, let agents, let text):
                Text("What's Sent to Agents").font(.headline)
                Text("Key- and token-looking strings are replaced with [redacted]. The diff and new files are cut to size.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Send to All Agents") {
                        model.askAgents(agents, about: session, request: "")
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .approve(let id):
                Text("Agent Waiting for Approval").font(.headline)
                if let record = model.pendingAgents.first(where: { $0.id == id }) {
                    Form { PendingAgentForm(record: record) }.formStyle(.grouped)
                } else {
                    Text("This agent isn't waiting for approval any more.").foregroundStyle(.secondary)
                }
                Spacer()
                HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            case .history(let session):
                Text("Past Reviews").font(.headline)
                List((model.agentReviewHistory[session] ?? []).reversed()) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.note.agentName).font(.callout.weight(.semibold))
                            Text(record.outcome == "sent" ? String(localized: "Sent to Claude") : record.outcome == "queued" ? String(localized: "Queued") : String(localized: "Dismissed"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(record.date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(record.note.reply ?? record.note.error ?? "").font(.callout).textSelection(.enabled).lineLimit(8)
                    }
                    .padding(.vertical, 2)
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(16)
        .frame(width: 640, height: 520)
    }
}
