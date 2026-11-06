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
            }
        }
    }

    private func ask(_ ids: [UUID]) {
        // What to look at is optional: Cancel asks nothing, an empty field asks for a review.
        guard let request = TextPrompt.ask(title: String(localized: "Ask Agent"), placeholder: String(localized: "What should it look at? (optional)"), allowEmpty: true) else { return }
        model.askAgents(ids, about: sessionID, request: request)
    }
}

/// Under a session's terminal: the agents' notes, with Send to Claude / Queue / Dismiss.
struct AgentNotesStrip: View {
    @Environment(AppModel.self) private var model
    let sessionID: UUID
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let notes = model.agentNotes[sessionID] ?? []
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.purple)
                        Text(note.agentName).font(.caption.weight(.semibold))
                        if !note.request.isEmpty { Text("· \(note.request)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        if note.pending {
                            ProgressView().controlSize(.small)
                        } else if note.reply != nil {
                            Button("Send to Claude") { model.agentNoteAction(note.id, in: sessionID, action: .sendToClaude) }
                            Button("Queue") { model.agentNoteAction(note.id, in: sessionID, action: .queueForClaude) }
                                .help("Sent when it's your turn")
                        }
                        Button { model.agentNoteAction(note.id, in: sessionID, action: .dismiss) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                    .controlSize(.small)
                    if let reply = note.reply {
                        Text(reply)
                            .font(.callout)
                            .textSelection(.enabled)
                            .lineLimit(expanded.contains(note.id) ? nil : 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onTapGesture { if expanded.contains(note.id) { expanded.remove(note.id) } else { expanded.insert(note.id) } }
                    } else if let error = note.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if let failure = note.actionError {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxHeight: 320)
        .background(.bar)
    }
}
