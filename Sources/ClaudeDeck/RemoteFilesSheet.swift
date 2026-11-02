import AppKit
import ClaudeDeckCore
import SwiftUI
import UniformTypeIdentifiers

/// The other Mac's project files: browse, save one to Downloads, add it to one of its sessions,
/// upload files into the folder shown (Upload… or drop them on the list).
struct RemoteFilesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialProject: UUID? = nil
    @State private var projectID: UUID?
    /// Folders opened, from the project's root.
    @State private var trail: [String] = []
    @State private var dropTargeted = false

    var body: some View {
        let remote = model.remote
        let path = trail.joined(separator: "/")
        let state = projectID.flatMap { remote.hostDirectories[RemoteController.fileKey($0, path)] }
        let canTransfer = remote.snapshot?.supports(RemoteSnapshot.Feature.transfer) == true
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Project", selection: $projectID) {
                    ForEach(remote.hostProjects) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
                if canTransfer {
                    Button("Upload…") { chooseUploads(path: path) }
                        .disabled(projectID == nil)
                }
            }
            // Where we are: the project, then each folder (click to go back up).
            HStack(spacing: 4) {
                Button(remote.hostProjects.first { $0.id == projectID }?.name ?? "") { trail = [] }
                    .buttonStyle(.link)
                ForEach(Array(trail.enumerated()), id: \.offset) { index, name in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(name) { trail = Array(trail.prefix(index + 1)) }.buttonStyle(.link)
                }
                Spacer()
            }
            .font(.callout)
            List {
                ForEach(state?.entries ?? [], id: \.name) { entry in
                    let child = path.isEmpty ? entry.name : path + "/" + entry.name
                    HStack(spacing: 8) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc")
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                            if canTransfer, let projectID {
                                Button { remote.hostTransfers.download(projectID, path: child) } label: { Image(systemName: "arrow.down.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Save to Downloads")
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if entry.isDirectory { trail.append(entry.name) }
                        else if canTransfer, let projectID { remote.hostTransfers.download(projectID, path: child) }
                    }
                    .contextMenu {
                        if entry.isDirectory {
                            Button("Open") { trail.append(entry.name) }
                        } else if let projectID {
                            fileMenu(projectID: projectID, path: child, canTransfer: canTransfer)
                        }
                    }
                }
            }
            .overlay {
                if projectID != nil, state == nil { ProgressView() }
                else if let error = state?.error { Text(error).foregroundStyle(.secondary) }
                else if state?.entries.isEmpty == true { Text("Empty folder").foregroundStyle(.secondary) }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: canTransfer ? $dropTargeted : .constant(false)) { providers in
                guard canTransfer, let projectID else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in remote.hostTransfers.upload(url, to: projectID, folder: path) }
                    }
                }
                return true
            }
            RemoteTransfersList()
            HStack {
                if canTransfer {
                    Text("Double-click a file to save it to Downloads; drop files here to upload them into this folder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Update ClaudeDeck on the other Mac to send and save files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
        .onAppear { if projectID == nil { projectID = initialProject ?? remote.hostProjects.first?.id } }
        .onChange(of: projectID) { _, _ in trail = [] }
        .onChange(of: "\(projectID?.uuidString ?? "")|\(path)", initial: true) { _, _ in
            if let projectID { remote.listHostDirectory(projectID, path: path) }
        }
    }

    @ViewBuilder
    private func fileMenu(projectID: UUID, path: String, canTransfer: Bool) -> some View {
        let remote = model.remote
        let project = remote.hostProjects.first { $0.id == projectID }
        let absolute = project?.path.map { ($0 as NSString).appendingPathComponent(path) }
        if canTransfer {
            Button("Save to Downloads") { remote.hostTransfers.download(projectID, path: path) }
            let sessions = (remote.snapshot?.sessions ?? []).filter { $0.project == project?.name && $0.state != .notStarted && $0.state != .shell }
            if let absolute, !sessions.isEmpty {
                Menu("Add to Session") {
                    ForEach(sessions) { session in
                        Button(session.name) { remote.insertIntoHostSession(session.id, text: "@" + ShellEnvironment.escapedPath(absolute) + " ") }
                    }
                }
            }
        }
        if let absolute {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(absolute, forType: .string)
            }
        }
    }

    private func chooseUploads(path: String) {
        guard let projectID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Upload")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.remote.hostTransfers.upload(url, to: projectID, folder: path) }
    }
}

/// Downloads / uploads in progress (other Mac).
struct RemoteTransfersList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.remote.hostTransfers.items
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.error != nil ? "exclamationmark.triangle" : item.finished ? "checkmark.circle" : item.upload ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(item.error != nil ? Color.orange : item.finished ? Color.green : Color.accentColor)
                        Text(item.name).lineLimit(1).frame(width: 180, alignment: .leading)
                        if let error = item.error {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1)
                        } else if !item.finished {
                            ProgressView(value: item.progress)
                        } else {
                            Text(item.upload ? "Uploaded" : "Saved to Downloads").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if !item.finished || item.error != nil {
                            Button { model.remote.hostTransfers.dismiss(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
