import AppKit
import SwiftUI

/// An NSView subclass that hosts a ghostty_surface_t with a CAMetalLayer.
/// Ghostty renders into the Metal layer; we just provide the view.
/// Implements NSTextInputClient for proper macOS text input handling.
class GhosttyNSView: NSView, NSTextInputClient {
    private var surface: ghostty_surface_t?
    private weak var ghosttyApp: GhosttyApp?

    /// Text accumulated from interpretKeyEvents → insertText for the current keyDown.
    private var pendingText: String?
    /// Marked text for input method composition (CJK, etc.)
    private var markedTextStorage = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)

    override var acceptsFirstResponder: Bool { true }

    /// Optional shell command to run inside this surface instead of the default shell.
    /// Must be set before the surface is added to a window.
    var command: String?

    init(ghosttyApp: GhosttyApp, command: String? = nil) {
        self.ghosttyApp = ghosttyApp
        self.command = command
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if surface == nil, let app = ghosttyApp?.app, window != nil {
            createSurface(app: app)
            window?.makeFirstResponder(self)
        }
    }

    private func createSurface(app: ghostty_app_t) {
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // If a command was provided, run it instead of the default shell.
        // We use withCString so the pointer is valid for the duration of this call.
        if let cmd = command, !cmd.isEmpty {
            cmd.withCString { cStr in
                config.command = cStr
                surface = ghostty_surface_new(app, &config)
            }
        } else {
            surface = ghostty_surface_new(app, &config)
        }

        if surface == nil {
            print("Failed to create Ghostty surface")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(newSize.width * scale),
            UInt32(newSize.height * scale)
        )
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Route through macOS text input system (handles IME, dead keys, key bindings).
        // This calls insertText/doCommandBySelector/setMarkedText on us.
        pendingText = nil
        interpretKeyEvents([event])

        // Build Ghostty key event with text produced by the input system
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        keyEvent.composing = hasMarkedText()

        let text = pendingText ?? ""
        if text.isEmpty {
            keyEvent.text = nil
            ghostty_surface_key(surface, keyEvent)
        } else {
            text.withCString { ptr in
                keyEvent.text = ptr
                ghostty_surface_key(surface, keyEvent)
            }
        }
        pendingText = nil
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        keyEvent.composing = false
        keyEvent.text = nil
        ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        keyEvent.composing = false
        keyEvent.text = nil
        ghostty_surface_key(surface, keyEvent)
    }

    private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= 1 }
        if flags.contains(.control) { mods |= 2 }
        if flags.contains(.option) { mods |= 4 }
        if flags.contains(.command) { mods |= 8 }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - NSTextInputClient (required methods)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let s = string as? NSAttributedString {
            text = s.string
        } else {
            return
        }

        // Clear any marked text on commit
        markedTextStorage.mutableString.setString("")
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)

        pendingText = text
    }

    override func doCommand(by selector: Selector) {
        // Called by interpretKeyEvents for non-text keys (arrows, delete, escape, etc.)
        // We handle these through the keycode path in keyDown, so intentionally empty.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String {
            markedTextStorage.mutableString.setString(s)
        } else if let s = string as? NSAttributedString {
            markedTextStorage.setAttributedString(s)
        }
        markedSelectedRange = selectedRange

        // Set pending text as the composing text so Ghostty sees it
        pendingText = markedTextStorage.string
    }

    func unmarkText() {
        markedTextStorage.mutableString.setString("")
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        // Terminal doesn't have a text selection in the NSTextInputClient sense
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        if markedTextStorage.length > 0 {
            return NSRange(location: 0, length: markedTextStorage.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        return markedTextStorage.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the view's position in screen coordinates for IME candidate window placement
        guard let window else { return .zero }
        let viewRect = convert(bounds, to: nil)
        return window.convertToScreen(viewRect)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: - Cleanup

    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    deinit {
        destroySurface()
    }
}

/// SwiftUI wrapper for GhosttyNSView.
struct TerminalView: NSViewRepresentable {
    let ghosttyApp: GhosttyApp
    /// Optional command to run inside the terminal instead of the default shell.
    var command: String?

    func makeNSView(context: Context) -> GhosttyNSView {
        return GhosttyNSView(ghosttyApp: ghosttyApp, command: command)
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
    }
}
