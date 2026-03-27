import Foundation
import AppKit

/// Wraps the single ghostty_app_t instance. One per application.
/// Ghostty internally manages PTYs, VT parsing, and Metal rendering.
class GhosttyApp {
    /// Singleton for clipboard callback access (C callbacks can't capture Swift context).
    static weak var shared: GhosttyApp?

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// The currently focused surface. Updated by GhosttyNSView when it becomes first responder.
    var activeSurface: ghostty_surface_t?
    /// Deduplicates wakeup → tick: multiple wakeups before the main queue drains
    /// result in a single tick() call, so all pending PTY output is processed at
    /// once and rendered in one frame.
    private var tickScheduled = false

    init() {
        GhosttyApp.shared = self

        // Initialize the Ghostty library — must be called before any other ghostty_ function
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("Failed to initialize Ghostty: \(initResult)")
            return
        }

        // Create and finalize config
        guard let cfg = ghostty_config_new() else {
            print("Failed to create Ghostty config")
            return
        }
        config = cfg
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)

        // Build runtime config with callbacks
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared?.requestTick()
            }
        }
        runtime.action_cb = { app, target, action in
            // Minimal action handler — just handle close surface for now
            return false
        }
        runtime.close_surface_cb = { _, _ in }

        // Clipboard callbacks — required for mouse selection and paste to work.
        // Without write_clipboard_cb, ghostty dereferences a null function pointer
        // when a mouse selection completes.

        runtime.write_clipboard_cb = { _, location, content, len, _ in
            guard let content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var text: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        text = value
                        break
                    }
                }
                if text == nil { text = value }
            }
            guard let text else { return }
            let pb: NSPasteboard
            if location == GHOSTTY_CLIPBOARD_SELECTION {
                pb = NSPasteboard(name: .find)
            } else {
                pb = NSPasteboard.general
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        // read_clipboard_cb: ghostty requests clipboard content for paste/OSC 52.
        // Uses GhosttyApp.shared.activeSurface (avoids userdata which may be per-surface).
        runtime.read_clipboard_cb = { _, location, state in
            guard let surface = GhosttyApp.shared?.activeSurface else { return false }
            let pb: NSPasteboard
            if location == GHOSTTY_CLIPBOARD_SELECTION {
                pb = NSPasteboard(name: .find)
            } else {
                pb = NSPasteboard.general
            }
            guard let str = pb.string(forType: .string) else { return false }
            str.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }

        // confirm_read_clipboard_cb: ghostty has content and wants user confirmation.
        // Auto-confirm in V1 (no confirmation dialog).
        runtime.confirm_read_clipboard_cb = { _, content, state, _ in
            guard let content else { return }
            guard let surface = GhosttyApp.shared?.activeSurface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        // Create the Ghostty app
        app = ghostty_app_new(&runtime, config)
        if app == nil {
            print("Failed to create Ghostty app")
        }
    }

    /// Schedule a tick if one isn't already pending. Multiple wakeups between
    /// main queue drains collapse into a single tick, so all PTY output is
    /// processed at once and rendered in one display link frame.
    func requestTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            self.tick()
        }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }
}
