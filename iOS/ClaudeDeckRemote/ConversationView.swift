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
                        // The question the prompt on the Mac is showing: answerable here.
                        let pendingQuestion = session?.state == .needsAnswer
                            ? conversation?.entries.last(where: { $0.questions != nil }).flatMap { $0.result == nil ? $0.id : nil } : nil
                        ForEach(conversation?.entries ?? []) { entry in
                            if entry.questions != nil {
                                QuestionCard(entry: entry, sessionID: sessionID, pending: entry.id == pendingQuestion).id(entry.id)
                            } else {
                                ChatEntryView(entry: entry).id(entry.id)
                            }
                        }
                        if session?.state == .running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(session?.detail ?? String(localized: "Running")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Button {
                                    store.interrupt(sessionID)
                                } label: {
                                    Label("Stop", systemImage: "stop.circle").font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
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

/// Claude's AskUserQuestion: every question (a tab in the terminal) with its options. While the
/// prompt is open on the Mac it can be answered here; afterwards it shows what was chosen.
struct QuestionCard: View {
    @Environment(RemoteStore.self) private var store
    let entry: ChatEntry
    let sessionID: UUID
    let pending: Bool
    @State private var chosen: [Int: Set<Int>] = [:]
    @State private var otherText: [Int: String] = [:]
    @State private var otherChosen: Set<Int> = []
    @FocusState private var typing: Int?

    private var questions: [ChatQuestion] { entry.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let header = question.header, !header.isEmpty {
                            Text(header)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        if question.multiSelect && pending {
                            Text("Choose one or more").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(question.question).font(.subheadline.weight(.semibold))
                    if pending {
                        options(index, question)
                    } else if let answer = entry.answers?[question.question] {
                        Label(answer, systemImage: "arrow.turn.down.right")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Text("• " + option.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if pending { sendButton }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if pending { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.5)) }
        }
    }

    @ViewBuilder
    private func options(_ index: Int, _ question: ChatQuestion) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
            let on = chosen[index, default: []].contains(optionIndex)
            Button {
                if question.multiSelect {
                    chosen[index, default: []].formSymmetricDifference([optionIndex])
                } else {
                    chosen[index] = [optionIndex]
                    otherChosen.remove(index)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: question.multiSelect ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).font(.subheadline)
                        if let description = option.description, !description.isEmpty {
                            Text(description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
        }
        // The terminal's "Type something": own text, for a single choice.
        if !question.multiSelect {
            let on = otherChosen.contains(index)
            Button {
                otherChosen.insert(index)
                chosen[index] = []
                typing = index
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    Text("Other…").font(.subheadline).foregroundStyle(on ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            // Outside the button: a text field in a button's label doesn't take taps.
            if on {
                TextField("Your answer", text: Binding(get: { otherText[index] ?? "" }, set: { otherText[index] = $0 }), axis: .vertical)
                    .font(.subheadline)
                    .focused($typing, equals: index)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 24)
            }
        }
    }

    /// One answer per question, or nil while any is missing.
    private var answers: [QuestionAnswer]? {
        var result: [QuestionAnswer] = []
        for index in questions.indices {
            if otherChosen.contains(index) {
                let text = (otherText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                result.append(QuestionAnswer(text: text))
            } else {
                let options = chosen[index, default: []]
                guard !options.isEmpty else { return nil }
                result.append(QuestionAnswer(options: options.sorted()))
            }
        }
        return result
    }

    private var sendButton: some View {
        let busy = store.answering.contains(sessionID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    if let answers { store.answerQuestion(sessionID, toolUseID: entry.id, answers: answers) }
                } label: {
                    Text("Send Answers").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(answers == nil || busy || store.connection != .connected)
                if busy { ProgressView() }
            }
            if let error = store.answerError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
