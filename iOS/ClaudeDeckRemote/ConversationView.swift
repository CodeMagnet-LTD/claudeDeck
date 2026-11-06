import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A session's conversation, readable on a phone: messages, Claude's answers, tool steps (tap for
/// the result), older entries on scrolling up, and a field to send a message.
struct ConversationView: View {
    @Environment(RemoteStore.self) private var store
    let sessionID: UUID
    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var attachments: [Attachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var attachError: String?
    /// Shift+Return on a hardware keyboard: the next newline stays a newline.
    @State private var shiftReturn = false
    @AppStorage(ConversationTextSize.key) private var textSize = ConversationTextSize.standard
    /// Optional: while Claude works, messages wait in the Mac's queue and go in one per turn.
    @AppStorage("composer.queue") private var queueMode = false
    @State private var editingPrompt: QueuedPrompt?
    @State private var editText = ""

    var body: some View {
        let conversation = store.conversations[sessionID]
        let session = store.snapshot?.session(sessionID)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a page is at most a few dozen entries, and a lazy stack only guesses
                    // the heights of rows it hasn't drawn, so scrolling to the end landed short and
                    // left gaps until the list was scrolled by hand.
                    VStack(alignment: .leading, spacing: 10) {
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
                        ForEach(ChatItem.group(conversation?.entries ?? [])) { item in
                            switch item {
                            case .entry(let entry) where entry.questions != nil:
                                QuestionCard(entry: entry, sessionID: sessionID, pending: entry.id == pendingQuestion).id(entry.id)
                            case .entry(let entry):
                                ChatEntryView(entry: entry).id(entry.id)
                            case .tools(let entries):
                                ToolGroupView(entries: entries).id(item.id)
                            }
                        }
                        ForEach(conversation?.agentNotes ?? []) { note in
                            AgentNoteCard(note: note, sessionID: sessionID).id(note.id)
                        }
                        if session?.state == .running {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(MarkdownBlocks.shortToolNames(session?.detail ?? String(localized: "Running"))).listFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Button {
                                    store.interrupt(sessionID)
                                } label: {
                                    Label("Stop", systemImage: "stop.circle").listFont(.caption)
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
                    .listFont(.body)
                }
                .dynamicTypeSize(ConversationTextSize.size(textSize))
                .environment(\.listFontScale, ConversationTextSize.listScale(textSize))
                // Pinch: one step bigger or smaller per gesture.
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    if value.magnification > 1.15 { textSize = ConversationTextSize.listStep(textSize, by: 1) }
                    if value.magnification < 0.87 { textSize = ConversationTextSize.listStep(textSize, by: -1) }
                })
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .overlay {
                    if conversation?.loaded != true {
                        if store.connection == .connected { ProgressView() } else { Text("Waiting for the other Mac…").foregroundStyle(.secondary) }
                    } else if conversation?.entries.isEmpty == true {
                        Text("No messages yet").foregroundStyle(.secondary)
                    }
                }
                .onChange(of: conversation?.entries.last?.id) { old, _ in
                    // Opening: straight to the end; new messages after that: animated.
                    if old == nil {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(150))
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } else {
                        withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            Divider()
            composer(session)
        }
        .onAppear {
            store.openConversation(sessionID)
            store.permissionMode(sessionID)
        }
        .onDisappear { store.closeConversation(sessionID) }
        // The mode can change on the Mac too; it shows again after each turn.
        .onChange(of: session?.state) { _, _ in store.permissionMode(sessionID) }
    }

    @ViewBuilder
    private func composer(_ session: RemoteSession?) -> some View {
        let blocked = session?.state.isBlocked == true
        let sending = store.sendingFiles.contains(sessionID)
        VStack(alignment: .leading, spacing: 6) {
            if let queue = session?.queue, !queue.isEmpty { queueList(queue) }
            if let error = attachError ?? store.promptError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 4)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                                attachError = nil
                            }
                        }
                    }
                }
                .disabled(sending)
            }
            HStack(spacing: 8) {
            if let session, session.state != .shell, store.snapshot?.supports(RemoteSnapshot.Feature.permissionMode) == true {
                let mode = store.permissionModes[sessionID]
                Button { store.permissionMode(sessionID, cycle: true) } label: {
                    Label(mode.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? String(localized: "Permission Mode"),
                          systemImage: Self.modeSymbol(mode))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(blocked || store.connection != .connected)
                .accessibilityHint(Text("Switches to the next permission mode, like Shift+Tab"))
            }
            if let agents = store.snapshot?.agents, !agents.isEmpty, store.snapshot?.supports(RemoteSnapshot.Feature.agents) == true,
               session?.state != .shell {
                Menu {
                    Section(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? String(localized: "Asks for a review of the latest work")
                            : String(localized: "Asks about what you typed")) {
                        ForEach(agents) { agent in
                            Button(agent.name) { ask([agent.id]) }
                        }
                        if agents.count > 1 {
                            Button { ask(agents.map(\.id)) } label: { Label("All Agents", systemImage: "person.3") }
                        }
                    }
                } label: {
                    Label("Ask", systemImage: "sparkles").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.connection != .connected)
            }
            if canQueue(session) {
                Button { queueMode.toggle() } label: {
                    Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(queueMode ? .accentColor : .secondary)
                .controlSize(.small)
                .accessibilityValue(Text(queueMode ? "On" : "Off"))
                .accessibilityHint(Text("While Claude works, messages wait and go in one per turn"))
            }
            // How full Claude's context is: tokens, and a rough share of the window (the window
            // depends on the model: 200k assumed, 1M once past it).
            if let tokens = store.conversations[sessionID]?.contextTokens, tokens > 0 {
                let window = tokens > 200_000 ? 1_000_000 : 200_000
                let percent = min(100, tokens * 100 / window)
                Label("\(tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)") · ~%\(percent)", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(percent >= 80 ? Color.orange : Color.secondary)
                    .accessibilityLabel(Text("Context: \(tokens) tokens, about \(percent) percent"))
            }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    if store.snapshot?.supports(RemoteSnapshot.Feature.files) == true {
                        Button { choosingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        Button { choosingFiles = true } label: { Label("Choose File", systemImage: "doc") }
                    } else {
                        // An older ClaudeDeck on the Mac would skip the files without answering.
                        Text("Update ClaudeDeck on the Mac to send photos and files.")
                    }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 20)).frame(width: 30, height: 36)
                }
                .disabled(blocked || sending)
                TextField(blocked && !queuing(session) ? String(localized: "Answer the prompt above first")
                          : queuing(session) ? String(localized: "Queue a message for the next turn") : String(localized: "Message Claude"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .disabled(blocked && !queuing(session))
                    .submitLabel(.send)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { send(session, keepFocus: true); return .handled }
                        shiftReturn = true
                        return .ignored
                    }
                    // Return sends, like the terminal: a single typed newline (on-screen keyboard)
                    // is taken back out and sends the message; a pasted text keeps its lines.
                    .onChange(of: draft) { old, new in
                        let typedNewline = new.count == old.count + 1
                            && new.filter(\.isNewline).count == old.filter(\.isNewline).count + 1
                        defer { if typedNewline { shiftReturn = false } }
                        guard typedNewline, !shiftReturn else { return }
                        draft = old
                        send(session, keepFocus: true)
                    }
                if sending {
                    ProgressView().frame(width: 30, height: 36)
                } else {
                    Button {
                        send(session)
                    } label: {
                        Image(systemName: queuing(session) ? "text.line.first.and.arrowtriangle.forward" : "arrow.up.circle.fill")
                            .font(.system(size: queuing(session) ? 22 : 30))
                            .frame(width: 30, height: 30)
                    }
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                              || (blocked && !queuing(session)) || store.connection != .connected)
                    // One message the other way: now, or into the queue.
                    .contextMenu {
                        if canQueue(session), attachments.isEmpty {
                            Button { send(session, queue: false) } label: { Label("Send Now", systemImage: "arrow.up.circle") }
                                .disabled(blocked)
                            Button { send(session, queue: true) } label: { Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: sending) { was, now in
            if was, !now, store.promptError == nil {
                draft = ""
                attachments = []
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    add(Attachment.photo(data, number: attachments.count + 1))
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    attachError = String(localized: "Couldn't read \(url.lastPathComponent).")
                    continue
                }
                add(Attachment.file(data, name: url.lastPathComponent))
            }
        }
    }

    static func modeSymbol(_ mode: String?) -> String {
        let mode = mode?.lowercased() ?? ""
        if mode.contains("plan") { return "list.bullet.clipboard" }
        if mode.contains("accept") { return "checkmark.circle" }
        if mode.contains("auto") || mode.contains("bypass") { return "bolt.fill" }
        if mode.contains("manual") || mode.contains("default") { return "hand.raised" }
        return "slider.horizontal.3"
    }

    /// `keepFocus`: sent with Return, so the keyboard stays for the next message (the field may
    /// already have given up focus by the time this runs, so it isn't asked).
    /// `queue`: nil follows the Queue switch (only while Claude is busy), true / false force it.
    private func send(_ session: RemoteSession?, keepFocus: Bool = false, queue: Bool? = nil) {
        let toQueue = attachments.isEmpty && canQueue(session) && (queue ?? queuing(session))
        guard session?.state.isBlocked != true || toQueue, store.connection == .connected, !store.sendingFiles.contains(sessionID),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return }
        let typing = keepFocus || composing
        if toQueue {
            if store.queuePrompt(sessionID, text: draft) { draft = "" }
        } else if attachments.isEmpty {
            if store.sendPrompt(sessionID, text: draft) { draft = "" }
        } else {
            // Cleared once the Mac took it (a failure keeps them for another try).
            store.sendPrompt(sessionID, text: draft, files: attachments.map(\.upload))
        }
        // Keep the keyboard up for the next message (the field drops focus as the text clears).
        if typing {
            // Again a moment later: clearing the text and the list update can take focus away after.
            composing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { composing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { composing = true }
        }
    }

    /// Agents look at the session; what's typed (if anything) is what they're asked.
    private func ask(_ agents: [UUID]) {
        if store.askAgents(sessionID, agents: agents, request: draft) { draft = "" }
    }

    /// The Mac keeps a queue for this session (a Claude session, a new enough host).
    private func canQueue(_ session: RemoteSession?) -> Bool {
        guard let session, session.state != .shell, session.state != .notStarted else { return false }
        return store.snapshot?.supports(RemoteSnapshot.Feature.queue) == true
    }

    /// The next message goes to the queue: the switch is on and Claude isn't waiting for the user
    /// (working, asking, or messages already waiting their turn).
    private func queuing(_ session: RemoteSession?) -> Bool {
        guard queueMode, canQueue(session), let session, attachments.isEmpty else { return false }
        return session.state != .idle || !(session.queue ?? []).isEmpty
    }

    @ViewBuilder
    private func queueList(_ queue: [QueuedPrompt]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Queue · \(queue.count)", systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(queue.enumerated()), id: \.element.id) { index, prompt in
                HStack(spacing: 6) {
                    Text("\(index + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(prompt.text).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        Button { store.queueAction(sessionID, prompt: prompt.id, .sendNow) } label: { Label("Send Now", systemImage: "arrow.up.circle") }
                        Button {
                            editText = prompt.text
                            editingPrompt = prompt
                        } label: { Label("Edit…", systemImage: "pencil") }
                        if index > 0 {
                            Button { store.queueAction(sessionID, prompt: prompt.id, .moveUp) } label: { Label("Move Up", systemImage: "arrow.up") }
                        }
                        Button(role: .destructive) { store.queueAction(sessionID, prompt: prompt.id, .remove) } label: { Label("Remove", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 18)).frame(width: 30, height: 26)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .alert("Edit Queued Message", isPresented: Binding(get: { editingPrompt != nil }, set: { if !$0 { editingPrompt = nil } })) {
            TextField("Message", text: $editText, axis: .vertical)
            Button("Save") {
                if let prompt = editingPrompt { store.queueAction(sessionID, prompt: prompt.id, .edit(editText)) }
                editingPrompt = nil
            }
            Button("Cancel", role: .cancel) { editingPrompt = nil }
        }
    }

    private func add(_ attachment: Attachment?) {
        guard let attachment else { return }
        let total = attachments.reduce(attachment.upload.data.count) { $0 + $1.upload.data.count }
        guard total <= RemoteUpload.maxTotalBytes else {
            attachError = String(localized: "Too large: up to 5 MB of files per message.")
            return
        }
        attachError = nil
        attachments.append(attachment)
    }
}

/// A photo or file waiting to go with the next message.
struct Attachment: Identifiable {
    let id = UUID()
    let upload: RemoteUpload
    let thumbnail: UIImage?

    /// Longest side in pixels: plenty for Claude, a few hundred KB as JPEG.
    static let maxPixels: CGFloat = 2000

    /// A photo, resized and made JPEG (HEIC isn't one Claude reads).
    static func photo(_ data: Data, number: Int, name: String? = nil) -> Attachment? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixels / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? "photo-\(number)"
        return Attachment(upload: RemoteUpload(name: base + ".jpg", data: jpeg), thumbnail: resized)
    }

    /// Any file; images other than GIF go through `photo`.
    static func file(_ data: Data, name: String) -> Attachment? {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if let type, type.conforms(to: .image), !type.conforms(to: .gif) {
            return photo(data, number: 0, name: name)
        }
        return Attachment(upload: RemoteUpload(name: name, data: data), thumbnail: type?.conforms(to: .gif) == true ? UIImage(data: data) : nil)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc").frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.upload.name).font(.caption).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.upload.data.count), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 140, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .padding(.trailing, 4)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
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
            MarkdownView(text: entry.text)
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(entry.toolName))
                            .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                            .frame(width: 16)
                        Text(MarkdownBlocks.shortToolNames(entry.toolName ?? "")).listFont(.caption, weight: .semibold)
                        Text(entry.text).listFont(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                        Spacer(minLength: 0)
                        if entry.result != nil {
                            Image(systemName: "chevron.right").listFont(.caption2).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded, let result = entry.result {
                    Text(result)
                        .listFont(.caption2, design: .monospaced)
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
                .listFont(.caption)
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
                                .listFont(.caption2, weight: .semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        if question.multiSelect && pending {
                            Text("Choose one or more").listFont(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(question.question).listFont(.subheadline, weight: .semibold)
                    if pending {
                        options(index, question)
                    } else if let answer = entry.answers?[question.question] {
                        Label(answer, systemImage: "arrow.turn.down.right")
                            .listFont(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Text("• " + option.label).listFont(.caption).foregroundStyle(.secondary)
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
                        Text(option.label).listFont(.subheadline)
                        if let description = option.description, !description.isEmpty {
                            Text(description).listFont(.caption).foregroundStyle(.secondary)
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
                    Text("Other…").listFont(.subheadline).foregroundStyle(on ? .primary : .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)
            // Outside the button: a text field in a button's label doesn't take taps.
            if on {
                TextField("Your answer", text: Binding(get: { otherText[index] ?? "" }, set: { otherText[index] = $0 }), axis: .vertical)
                    .listFont(.subheadline)
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
                Text(error).listFont(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// Claude's answer: inline markdown, with tables drawn as tables (scrolling sideways when wide).
struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = MarkdownBlocks.split(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(ChatEntryView.markdown(text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let level, let text):
                    Text(ChatEntryView.markdown(text))
                        .listFont(level <= 1 ? .title3 : level == 2 ? .headline : .subheadline, weight: level <= 1 ? .bold : .semibold)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let header, let rows):
                    MarkdownTableView(header: header, rows: rows)
                }
            }
        }
    }
}

struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(header.indices, id: \.self) { cell(header[$0], bold: true) }
                }
                Divider()
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { cell(rows[row][$0]) }
                    }
                    if row < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Long cells wrap at a fixed width instead of making the table endless (in a sideways
    /// scroll view nothing else bounds them, and the row wouldn't grow for the wrapped lines).
    @ViewBuilder
    private func cell(_ text: String, bold: Bool = false) -> some View {
        let label = Text(ChatEntryView.markdown(text)).listFont(.subheadline, weight: bold ? .semibold : .regular)
        if text.count > 32 {
            label.frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            label.fixedSize()
        }
    }
}

/// A conversation row: an entry, or several finished calls of the same tool in a row (like the
/// terminal's "Called claude-in-chrome 4 times").
enum ChatItem: Identifiable {
    case entry(ChatEntry)
    case tools([ChatEntry])

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .tools(let entries): "tools-" + (entries.first?.id ?? "")
        }
    }

    static func group(_ entries: [ChatEntry]) -> [ChatItem] {
        var items: [ChatItem] = []
        var run: [ChatEntry] = []
        func flush() {
            if run.count > 1 { items.append(.tools(run)) } else { items += run.map(ChatItem.entry) }
            run = []
        }
        for entry in entries {
            // Finished, plain tool calls group; a running one or a question stays on its own.
            let groupable = entry.kind == .tool && entry.questions == nil && entry.result != nil
            if groupable, let first = run.first, first.toolName == entry.toolName {
                run.append(entry)
            } else {
                flush()
                if groupable { run = [entry] } else { items.append(.entry(entry)) }
            }
        }
        flush()
        return items
    }
}

struct ToolGroupView: View {
    let entries: [ChatEntry]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let failed = entries.contains(where: \.isError)
                    Image(systemName: ChatEntryView.symbol(entries.first?.toolName))
                        .foregroundStyle(failed ? Color.red : Color.secondary)
                        .frame(width: 16)
                    Text(MarkdownBlocks.shortToolNames(entries.first?.toolName ?? "")).listFont(.caption, weight: .semibold)
                    Text("×\(entries.count)").listFont(.caption, monospacedDigit: true).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").listFont(.caption2).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(entries) { ChatEntryView(entry: $0).padding(.leading, 12) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The conversation's text size, apart from the system's: a step of Dynamic Type.
enum ConversationTextSize {
    static let key = "conversation.textSize"
    /// The sidebar's (session list) own step.
    static let sidebarKey = "sidebar.textSize"
    static let densityKey = "sidebar.density"
    static let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2]
    static let standard = 3

    static func size(_ index: Int) -> DynamicTypeSize { sizes[min(max(index, 0), sizes.count - 1)] }
    static func step(_ index: Int, by delta: Int) -> Int { min(max(index + delta, 0), sizes.count - 1) }

    /// The session list goes four steps below the smallest Dynamic Type size: its rows' fonts scale.
    static let listMinimum = -4
    static func listStep(_ index: Int, by delta: Int) -> Int { min(max(index + delta, listMinimum), sizes.count - 1) }
    static func listScale(_ index: Int) -> CGFloat { index >= 0 ? 1 : 1 + 0.1 * CGFloat(max(index, listMinimum)) }
}

extension EnvironmentValues {
    /// Below the smallest Dynamic Type size: what the session list's fonts are multiplied by.
    @Entry var listFontScale: CGFloat = 1
    /// The session list's row spacing: 0 normal, 1 compact, 2 tight (Settings).
    @Entry var listDensity = 0
}

/// A session list row's insets for the chosen density (at least `minimum`).
struct ListRowDensity: ViewModifier {
    @Environment(\.listDensity) private var density
    var minimum = 0

    func body(content: Content) -> some View {
        let level = max(density, minimum)
        if level == 0 {
            content
        } else {
            let v: CGFloat = level == 1 ? 4 : 1
            content.listRowInsets(EdgeInsets(top: v, leading: 16, bottom: v, trailing: 16))
        }
    }
}

/// A text style at the current Dynamic Type size, times `listFontScale`.
private struct ListFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.listFontScale) private var scale
    let style: Font.TextStyle
    let weight: Font.Weight
    let monospacedDigit: Bool
    var design: Font.Design = .default

    func body(content: Content) -> some View {
        content.font(font)
    }

    private var font: Font {
        var font: Font
        if scale >= 1 {
            font = .system(style, design: design).weight(weight)
        } else {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
            let size = UIFont.preferredFont(forTextStyle: Self.uiStyle(style), compatibleWith: traits).pointSize * scale
            font = .system(size: size, weight: weight, design: design)
        }
        return monospacedDigit ? font.monospacedDigit() : font
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension View {
    func listFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, monospacedDigit: Bool = false, design: Font.Design = .default) -> some View {
        modifier(ListFont(style: style, weight: weight, monospacedDigit: monospacedDigit, design: design))
    }
}

/// The toolbar menu for it.
struct ConversationTextSizeMenu: View {
    @AppStorage(ConversationTextSize.key) private var textSize = ConversationTextSize.standard

    var body: some View {
        Menu {
            Button { textSize = ConversationTextSize.listStep(textSize, by: 1) } label: { Label("Larger Text", systemImage: "plus.magnifyingglass") }
                .disabled(textSize >= ConversationTextSize.sizes.count - 1)
            Button { textSize = ConversationTextSize.listStep(textSize, by: -1) } label: { Label("Smaller Text", systemImage: "minus.magnifyingglass") }
                .disabled(textSize <= ConversationTextSize.listMinimum)
            Button { textSize = ConversationTextSize.standard } label: { Label("Default Size", systemImage: "arrow.counterclockwise") }
                .disabled(textSize == ConversationTextSize.standard)
        } label: {
            Image(systemName: "textformat.size")
        }
        .accessibilityLabel(Text("Text Size"))
    }
}

/// An agent's note in the conversation: its answer, then Send to Claude / Queue / Dismiss.
struct AgentNoteCard: View {
    @Environment(RemoteStore.self) private var store
    let note: AgentNote
    let sessionID: UUID
    /// Sent, waiting for the Mac: the buttons wait too (cleared when the note changes).
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(note.agentName).listFont(.subheadline, weight: .semibold)
                if !note.request.isEmpty {
                    Text("· \(note.request)").listFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if note.pending || working { ProgressView().controlSize(.small) }
                Button { act(.dismiss) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
            if let reply = note.reply {
                MarkdownView(text: reply)
                HStack(spacing: 8) {
                    Button { act(.sendToClaude) } label: {
                        Label("Send to Claude", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { act(.queueForClaude) } label: {
                        Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .disabled(store.connection != .connected || working)
                if let failure = note.actionError {
                    Text(failure).listFont(.caption).foregroundStyle(.orange)
                }
            } else if let error = note.error {
                Text(error).listFont(.caption).foregroundStyle(.orange)
            } else {
                Text("Thinking…").listFont(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: note) { _, _ in working = false }
        .task(id: working) {
            // No word from the Mac (lost connection): the buttons come back.
            guard working else { return }
            try? await Task.sleep(for: .seconds(8))
            working = false
        }
    }

    private func act(_ action: AgentNoteAction) {
        if store.agentNoteAction(sessionID, note: note.id, action) { working = true }
    }
}
