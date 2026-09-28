import AppKit
import SwiftUI

/// Shows the selected session's terminal. The container only swaps subviews; terminal views
/// (and their processes) live in `TerminalRegistry` and are never torn down here.
struct TerminalHost: NSViewRepresentable {
    let sessionID: UUID
    let registry: TerminalRegistry
    /// Changes when the process (re)starts so the host re-attaches the view.
    let generation: Bool
    /// Only the focused pane takes keyboard focus.
    var isFocused = true

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = registry.view(for: sessionID) else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
        }
        guard isFocused else { return }
        DispatchQueue.main.async {
            if terminal.window != nil, terminal.window?.firstResponder !== terminal {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Detach only — the registry keeps the view and its process alive.
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
