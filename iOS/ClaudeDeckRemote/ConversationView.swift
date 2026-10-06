import SwiftUI

/// A session's conversation, readable on a phone: messages, Claude's answers, tool steps (tap for
/// the result), older entries on scrolling up, and a field to send a message.
struct ConversationView: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        let conversation = store.conversations[sessionID]
        let session = store.snapshot?.session(sessionID)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if conversation?.hasMoreBefore == true {
                            Button {
                                let anchor = conversation?.entries.first?.id
                                store.loadOlder(sessionID)
                                // Keep the reading position when older entries come in on top.
                                if let anchor {
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(400))
                                        proxy.scrollTo(anchor, anchor: .top)
                                    }
                                }
                            } label: {
                                HStack {
                                    if conversation?.loadingOlder == true { ProgressView() }
                                    Text("Earlier messages")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 4)
                        }
                        ForEach(conversation?.entries ?? []) { entry in
                            ChatEntryView(entry: entry).id(entry.id)
                        }
                        if session?.state == .running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(session?.detail ?? String(localized: "Running")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .id("working")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if conversation?.loaded != true {
                        if store.connection == .connected { ProgressView() } else { Text("Waiting for the other Mac…").foregroundStyle(.secondary) }
                    } else if conversation?.entries.isEmpty == true {
                        Text("No messages yet").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: conversation?.entries.last?.id) { _, _ in
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            Divider()
            composer(session)
        }
        .onAppear { store.openConversation(sessionID) }
        .onDisappear { store.closeConversation(sessionID) }
    }

    @ViewBuilder
    private func composer(_ session: RemoteSession?) -> some View {
        let blocked = session?.state.isBlocked == true
        HStack(alignment: .bottom, spacing: 8) {
            TextField(blocked ? String(localized: "Answer the prompt above first") : String(localized: "Message Claude"),
                      text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .disabled(blocked)
            Button {
                if store.sendPrompt(sessionID, text: draft) { draft = "" }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocked || store.connection != .connected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct ChatEntryView: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            Text(Self.markdown(entry.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(entry.toolName))
                            .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                            .frame(width: 16)
                        Text(entry.toolName ?? "").font(.caption.weight(.semibold))
                        Text(entry.text).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                        Spacer(minLength: 0)
                        if entry.result != nil {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded, let result = entry.result {
                    Text(result)
                        .font(.caption2.monospaced())
                        .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 2)
        case .system:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    /// Bold, italics, `code` and links; headings and lists stay as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func symbol(_ tool: String?) -> String {
        switch tool {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}
