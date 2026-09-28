import ClaudeDeckCore
import SwiftUI

/// Lists previous conversations of a project (from ~/.claude/projects) to continue with --resume.
struct ResumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var sessions: [ResumableSession] = []
    @State private var loaded = false
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(project.name) — Previous Conversations").font(.headline)
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    Text("No saved Claude conversations for this project.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(sessions, selection: $selection) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).lineLimit(2)
                            Text("\(s.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(s.id)
                        .padding(.vertical, 2)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                        if let id = ids.first { resume(id) }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Resume") { if let selection { resume(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
        .task {
            let path = project.path
            sessions = await Task.detached { TranscriptIndex.sessions(forProject: path) }.value
            loaded = true
        }
    }

    private func resume(_ id: String) {
        let title = sessions.first { $0.id == id }?.title
        // Already open in a deck session? Just select it.
        if let existing = model.deck.sessions.first(where: { $0.claudeSessionID == id }) {
            if !model.terminals.isRunning(existing.id) { model.launch(existing.id, resume: true) }
            model.selectedSessionID = existing.id
        } else {
            model.newSession(in: project.id, resumeID: id, title: title)
        }
        dismiss()
    }
}
