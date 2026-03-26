import Foundation
import AppKit

/// Wraps the single ghostty_app_t instance. One per application.
/// Ghostty internally manages PTYs, VT parsing, and Metal rendering.
class GhosttyApp {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    init() {
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
            guard let userdata else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.tick()
            }
        }
        runtime.action_cb = { app, target, action in
            // Minimal action handler — just handle close surface for now
            return false
        }
        runtime.close_surface_cb = { _, _ in }
        runtime.read_clipboard_cb = nil
        runtime.confirm_read_clipboard_cb = nil
        runtime.write_clipboard_cb = nil

        // Create the Ghostty app
        app = ghostty_app_new(&runtime, config)
        if app == nil {
            print("Failed to create Ghostty app")
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
