import SwiftUI

/// The Mac's projects, then their folders and text files (read-only, inside the project only).
struct ProjectFilesView: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        List(store.projects) { project in
            NavigationLink(project.name) { DirectoryView(projectID: project.id, path: "", title: project.name) }
        }
        .navigationTitle("Files")
    }
}

struct DirectoryView: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    let title: String
    @AppStorage("files.showHidden") private var showHidden = false

    var body: some View {
        let state = store.directories[RemoteStore.fileKey(projectID, path)]
        let entries = (state?.entries ?? []).filter { showHidden || !$0.isHidden }
        List(entries) { entry in
            let child = path.isEmpty ? entry.name : path + "/" + entry.name
            if entry.isDirectory {
                NavigationLink { DirectoryView(projectID: projectID, path: child, title: entry.name) } label: {
                    Label(entry.name, systemImage: "folder")
                }
            } else {
                NavigationLink { FileTextView(projectID: projectID, path: child) } label: {
                    HStack {
                        Label(entry.name, systemImage: "doc.text")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if state == nil { ProgressView() }
            else if let error = state?.error { Text(error).foregroundStyle(.secondary) }
            else if entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHidden.toggle() } label: { Image(systemName: showHidden ? "eye" : "eye.slash") }
                    .accessibilityLabel(showHidden ? "Hide Hidden Files" : "Show Hidden Files")
            }
        }
        .refreshable { store.listDirectory(projectID, path: path) }
        .onAppear { store.listDirectory(projectID, path: path) }
    }
}

struct FileTextView: View {
    @Environment(RemoteStore.self) private var store
    let projectID: UUID
    let path: String
    @State private var wrap = false

    var body: some View {
        let state = store.files[RemoteStore.fileKey(projectID, path)]
        Group {
            if let text = state?.text {
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .padding(10)
                }
            } else if let error = state?.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
            }
        }
        .onAppear { store.readFile(projectID, path: path) }
    }
}
