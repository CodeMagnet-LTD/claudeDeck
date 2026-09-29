import Foundation

/// Connects Claude sessions to the Pencil desktop app (Pen.app, pen.dev).
///
/// Pen.app bundles a stdio MCP server that talks to the running app over
/// `~/.pencil/socket/pencil-<app>.sock`; with `--app desktop` it reaches Pen.app itself
/// (the server that Pencil's VS Code extension registers uses `--app visual_studio_code`,
/// which only works while VS Code is open). ClaudeDeck writes a small MCP config for it and
/// passes it with `claude --mcp-config`, so nothing in the user's global Claude config changes.
/// The server starts fine when Pen.app isn't running and connects on the first tool call.
public enum PencilIntegration {
    /// Name of the MCP server in the config. A `--mcp-config` server overrides a user-scoped
    /// one of the same name, so a manually added `pencil-desktop` doesn't show up twice.
    public static let serverName = "pencil-desktop"
    /// The `--app` value Pen.app listens under (`pencil-desktop.sock`, `~/.pencil/apps/desktop`).
    public static let appName = "desktop"
    public static let agentName = "claudeCodeCLI"
    public static let configFileName = "pencil-mcp.json"

    /// Candidate binary names inside the app bundle, the current architecture first.
    static var binaryNames: [String] {
        #if arch(arm64)
        ["mcp-server-darwin-arm64", "mcp-server-darwin-x64", "mcp-server-darwin-amd64"]
        #else
        ["mcp-server-darwin-x64", "mcp-server-darwin-amd64", "mcp-server-darwin-arm64"]
        #endif
    }

    /// The MCP server bundled in Pen.app, if present and executable.
    public static func mcpBinary(inApp appURL: URL, fileManager: FileManager = .default) -> URL? {
        let dir = appURL.appending(path: "Contents/Resources/app.asar.unpacked/out")
        return binaryNames.lazy
            .map { dir.appending(path: $0) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Pen.app has registered itself (`~/.pencil/apps/desktop`) and its socket exists,
    /// i.e. it is (or was, if it crashed) running and reachable.
    public static func isRegistered(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    fileManager: FileManager = .default) -> Bool {
        let pencil = home.appending(path: ".pencil")
        return fileManager.fileExists(atPath: pencil.appending(path: "apps/\(appName)").path)
            && fileManager.fileExists(atPath: pencil.appending(path: "socket/pencil-\(appName).sock").path)
    }

    /// `{"mcpServers": {"pencil-desktop": {"type": "stdio", "command": …, "args": […]}}}`
    public static func mcpConfig(binary: URL) -> Data {
        let server: [String: Any] = [
            "type": "stdio",
            "command": binary.path,
            "args": ["--app", appName, "--agent", agentName],
            "env": [String: String](),
        ]
        let config = ["mcpServers": [serverName: server]]
        // Only strings/arrays/dictionaries: serialization can't fail.
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Writes the config into `directory` (only when it changed) and returns its URL.
    @discardableResult
    public static func writeConfig(binary: URL, directory: URL, fileManager: FileManager = .default) throws -> URL {
        let url = directory.appending(path: configFileName)
        let data = mcpConfig(binary: binary)
        if (try? Data(contentsOf: url)) == data { return url }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Arguments for `claude`. `--mcp-config` is variadic, so these go first: the next `--flag`
    /// ends the list (a positional right after it would be taken as another config).
    public static func launchArgs(configURL: URL) -> [String] {
        ["--mcp-config", configURL.path]
    }
}
