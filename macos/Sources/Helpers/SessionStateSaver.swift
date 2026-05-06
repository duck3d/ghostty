import AppKit
import Foundation
import GhosttyKit

/// Saves session state to a JSON file that the restore daemon can read.
/// This runs alongside the existing NSWindowRestoration system — it doesn't
/// replace it. The daemon reads this file to resolve PIDs to restore commands,
/// and writes session-restore.json which Ghostty reads on next launch.
enum SessionStateSaver {
    /// The directory where state files live.
    private static var stateDirectory: URL {
        // Match the Zig core's xdg.state path: ~/.local/state/ghostty/
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".local/state/ghostty", isDirectory: true)
    }

    static var statePath: URL {
        stateDirectory.appendingPathComponent("session-state.json")
    }

    static var restorePath: URL {
        stateDirectory.appendingPathComponent("session-restore.json")
    }

    // MARK: - Save

    /// Save the current session state to disk. Call this before quit.
    static func save() {
        let controllers = TerminalController.all
        guard !controllers.isEmpty else { return }

        var windows: [[String: Any]] = []
        var activeWindowIndex: Int? = nil

        for (windowIndex, controller) in controllers.enumerated() {
            guard let window = controller.window else { continue }

            if window.isMainWindow {
                activeWindowIndex = windowIndex
            }

            var tabs: [[String: Any]] = []
            let tabState = buildTabState(from: controller)
            tabs.append(tabState)

            let windowState: [String: Any] = [
                "width": Int(window.frame.width),
                "height": Int(window.frame.height),
                "maximized": window.isZoomed,
                "fullscreen": window.styleMask.contains(.fullScreen),
                "selected_tab": 0,
                "tabs": tabs,
            ]
            windows.append(windowState)
        }

        let state: [String: Any] = [
            "version": 1,
            "active_window": activeWindowIndex as Any,
            "windows": windows,
        ]

        writeAtomically(state, to: statePath)
    }

    private static func buildTabState(from controller: TerminalController) -> [String: Any] {
        var nodes: [[String: Any]] = []
        var focusedNode: Int? = nil

        buildNodes(
            from: controller.surfaceTree.root,
            into: &nodes,
            focusedSurface: controller.focusedSurface,
            focusedNode: &focusedNode
        )

        return [
            "focused_node": focusedNode as Any,
            "zoomed_node": NSNull(),
            "nodes": nodes,
        ]
    }

    private static func buildNodes(
        from node: SplitTree<Ghostty.SurfaceView>.Node?,
        into nodes: inout [[String: Any]],
        focusedSurface: Ghostty.SurfaceView?,
        focusedNode: inout Int?
    ) {
        guard let node else { return }

        switch node {
        case .leaf(let view):
            let idx = nodes.count
            if let focused = focusedSurface, focused.id == view.id {
                focusedNode = idx
            }

            var leaf: [String: Any] = [
                "kind": "leaf",
            ]

            // Get PID from the surface
            if let surface = view.surface {
                let pid = ghostty_surface_foreground_pid(surface)
                if pid != 0 {
                    leaf["pid"] = pid
                }
            }

            // Get working directory
            if let pwd = view.pwd {
                leaf["working_directory"] = pwd
            }

            // Get title
            let title = view.title
            if !title.isEmpty {
                leaf["title_override"] = title
            }

            nodes.append(leaf)

        case .split(let split):
            let idx = nodes.count
            // Reserve our slot
            nodes.append([:])

            let leftStart = nodes.count
            buildNodes(from: split.left, into: &nodes,
                       focusedSurface: focusedSurface, focusedNode: &focusedNode)

            let rightStart = nodes.count
            buildNodes(from: split.right, into: &nodes,
                       focusedSurface: focusedSurface, focusedNode: &focusedNode)

            nodes[idx] = [
                "kind": "split",
                "layout": split.direction == .horizontal ? "horizontal" : "vertical",
                "ratio": split.ratio,
                "left": leftStart,
                "right": rightStart,
            ]
        }
    }

    // MARK: - Restore Commands

    /// Load restore commands from the daemon's file.
    /// Returns a dictionary of (window, tab, node) → command string.
    static func loadRestoreCommands() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: restorePath.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: restorePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? Int, version == 1,
              let commands = json["commands"] as? [[String: Any]] else {
            return nil
        }

        var result: [String: String] = [:]
        for cmd in commands {
            guard let nodeIndex = cmd["node_index"] as? Int,
                  let command = cmd["command"] as? String else { continue }
            let windowIndex = cmd["window_index"] as? Int ?? 0
            let tabIndex = cmd["tab_index"] as? Int ?? 0
            let key = "\(windowIndex)-\(tabIndex)-\(nodeIndex)"
            result[key] = command
        }

        return result
    }

    /// Delete the restore file after consuming.
    static func deleteRestoreFile() {
        try? FileManager.default.removeItem(at: restorePath)
    }

    // MARK: - File I/O

    private static func writeAtomically(_ dict: [String: Any], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )

            // Write to temp file, then rename (atomic)
            let tmpURL = url.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [.atomic])

            // Set permissions to 0600
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )

            AppDelegate.logger.info("saved session state to \(url.path)")
        } catch {
            AppDelegate.logger.warning("failed to save session state: \(error)")
        }
    }
}
