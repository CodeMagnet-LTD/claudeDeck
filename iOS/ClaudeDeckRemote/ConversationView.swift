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
                TextField(blocked ? String(localized: "Answer the prompt above first") : String(localized: "Message Claude"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .disabled(blocked)
                    .submitLabel(.send)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { send(session); return .handled }
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
                        send(session)
                    }
                if sending {
                    ProgressView().frame(width: 30, height: 36)
                } else {
                    Button {
                        send(session)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                    }
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                              || blocked || store.connection != .connected)
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

    private func send(_ session: RemoteSession?) {
        guard session?.state.isBlocked != true, store.connection == .connected, !store.sendingFiles.contains(sessionID),
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return }
        if attachments.isEmpty {
            if store.sendPrompt(sessionID, text: draft) { draft = "" }
        } else {
            // Cleared once the Mac took it (a failure keeps them for another try).
            store.sendPrompt(sessionID, text: draft, files: attachments.map(\.upload))
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
        let label = Text(ChatEntryView.markdown(text)).font(.subheadline).fontWeight(bold ? .semibold : .regular)
        if text.count > 32 {
            label.frame(width: 260, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        } else {
            label.fixedSize()
        }
    }
}
