import AppKit
import ClaudeDeckCore
import SwiftUI

/// The Pencil desktop app (Pen.app, pen.dev): finding it, opening `.pen` files in it and the
/// MCP config that `AppModel.launch` passes to Claude sessions (see `PencilIntegration`).
@MainActor
enum PencilApp {
    static let bundleID = "dev.pencil.desktop"
    static let fileExtension = "pen"

    static var appURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        let fallback = URL(fileURLWithPath: "/Applications/Pen.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static var isInstalled: Bool { appURL != nil }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static var mcpBinary: URL? { appURL.flatMap { PencilIntegration.mcpBinary(inApp: $0) } }

    static func isPenFile(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    static func open(_ url: URL) {
        guard let app = appURL else { NSWorkspace.shared.open(url); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `--mcp-config <file>` for a Claude session, or nothing (setting off, Pen.app missing,
    /// config not writable). Never fails the launch.
    static func launchArgs(enabled: Bool) -> [String] {
        guard enabled, let binary = mcpBinary else { return [] }
        let directory = DeckDataStore.default().url.deletingLastPathComponent()
        guard let config = try? PencilIntegration.writeConfig(binary: binary, directory: directory) else { return [] }
        return PencilIntegration.launchArgs(configURL: config)
    }
}

/// Settings › Pencil: the toggle plus what was found (checked when the section appears).
struct PencilSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var installed = false
    @State private var binaryFound = false
    @State private var running = false

    var body: some View {
        Section("Pencil") {
            Toggle("Connect Claude sessions to Pencil (Pen.app)", isOn: Binding(
                get: { binaryFound && model.deck.settings.pencilMCP },
                set: { on in model.mutate { $0.settings.pencilMCP = on } }
            ))
            .disabled(!binaryFound)
            .onAppear {
                installed = PencilApp.isInstalled
                binaryFound = PencilApp.mcpBinary != nil
                running = PencilApp.isRunning && PencilIntegration.isRegistered()
            }
            LabeledContent("Status") {
                if !installed {
                    Text("Pen.app not installed").foregroundStyle(.secondary)
                } else if !binaryFound {
                    Text("Pen.app found, but not its MCP server").foregroundStyle(.orange)
                } else if running {
                    Text("Pen.app running · MCP server found").foregroundStyle(.green)
                } else {
                    Text("Pen.app not running · MCP server found").foregroundStyle(.secondary)
                }
            }
            Text("New and resumed Claude sessions get Pencil's MCP server (as “pencil-desktop”, via --mcp-config), connected to the Pencil desktop app instead of the VS Code extension. Your global Claude configuration is not changed. Already running sessions need a restart.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Small "Pencil" tag in the pane header of sessions launched with the Pencil MCP server.
struct PencilBadge: View {
    var body: some View {
        // Icon only: pane headers get narrow in splits and a text label would wrap.
        Image(systemName: "pencil.and.outline")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .fixedSize()
            .accessibilityLabel("Pencil")
            .help("This session can use the Pencil (Pen.app) MCP tools")
    }
}
