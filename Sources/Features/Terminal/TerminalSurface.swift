import AppKit
import SwiftUI

/// An NSView subclass that hosts a ghostty_surface_t with a CAMetalLayer.
/// Ghostty renders into the Metal layer; we just provide the view.
/// Implements NSTextInputClient for proper macOS text input handling.
class GhosttyNSView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private weak var ghosttyApp: GhosttyApp?

    /// Text accumulated from interpretKeyEvents → insertText for the current keyDown.
    private var pendingText: String?
    /// Track whether we sent a left mouse press to ghostty (to avoid unbalanced release).
    private var leftMousePressed = false
    /// Marked text for input method composition (CJK, etc.)
    private var markedTextStorage = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        ghosttyApp?.activeSurface = surface
        if let surface {
            ghostty_surface_set_focus(surface, true)
            if let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
        // Notify coordinator of focus change for split navigation
        if let leafID {
            DispatchQueue.main.async { TerminalCoordinatorRef.instance?.leafDidFocus(leafID) }
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }

    /// Optional shell command to run inside this surface instead of the default shell.
    /// Must be set before the surface is added to a window.
    var command: String?
    /// The leaf ID in the split tree, used to update paneManager focus on click.
    var leafID: UUID?

    init(ghosttyApp: GhosttyApp, command: String? = nil, leafID: UUID? = nil) {
        self.ghosttyApp = ghosttyApp
        self.command = command
        self.leafID = leafID
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
            layer?.contentsScale = window?.backingScaleFactor ?? 2.0
            createSurface(app: app)
            ghosttyApp?.activeSurface = surface

            // Set display ID so ghostty can use CVDisplayLink for vsync-driven
            // rendering. Without this, ghostty renders immediately on every wakeup
            // which causes visible re-render churn (e.g., during paste).
            if let surface,
               let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }

            updateSurfaceSize()
            if let surface {
                ghostty_surface_set_focus(surface, true)
            }
            window?.makeFirstResponder(self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    /// Heap-allocated container for leaf ID, passed as ghostty surface userdata.
    /// Lets close_surface_cb identify which leaf's process exited.
    private var surfaceUserdata: UnsafeMutablePointer<UUID>?

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

        // Set per-surface userdata so close_surface_cb can identify this leaf.
        if let leafID {
            let ptr = UnsafeMutablePointer<UUID>.allocate(capacity: 1)
            ptr.initialize(to: leafID)
            surfaceUserdata = ptr
            config.userdata = UnsafeMutableRawPointer(ptr)
        }

        // If a command was provided, run it instead of the default shell.
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
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
        // Update display ID when backing properties change (e.g., moved to another screen).
        if let surface,
           let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)

        let backingSize = convertToBacking(bounds).size
        let wpx = UInt32(max(backingSize.width, 1))
        let hpx = UInt32(max(backingSize.height, 1))
        ghostty_surface_set_size(surface, wpx, hpx)
    }

    // MARK: - Keyboard Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface else { return false }

        // Handle Cmd+C and Cmd+V directly via ghostty binding actions.
        // Going through keyDown → ghostty_surface_key doesn't reliably trigger
        // ghostty's keybinding system for key equivalents.
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased() {
            let hasShift = event.modifierFlags.contains(.shift)
            switch chars {
            case "f":
                // Cmd+F → ghostty find-in-scrollback (WI-2026-03-31-006)
                _ = "start_search".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "=":
                // Cmd+= → increase font size (WI-2026-03-31-005).
                // Ghostty actions increase_font_size/decrease_font_size take a
                // required f32 parameter (e.g. ":1"); without it Action.parse
                // fails and the binding silently does nothing.
                _ = "increase_font_size:1".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "0":
                // Cmd+0 → reset font size
                _ = "reset_font_size".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "c":
                _ = "copy_to_clipboard".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "v":
                _ = "paste_from_clipboard".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "d":
                let direction: SplitNode.SplitDirection = hasShift ? .vertical : .horizontal
                DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestSplit(direction: direction) }
                return true
            case "\\":
                DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestSplit(direction: .horizontal) }
                return true
            case "-":
                if hasShift {
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestSplit(direction: .vertical) }
                    return true
                }
                // Cmd+- → decrease font size (WI-2026-03-31-005); f32 param
                // required (see "=" above).
                _ = "decrease_font_size:1".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
                return true
            case "w":
                DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestCloseSplit() }
                return true
            case "]":
                if hasShift {
                    // Cmd+Shift+] → next tab
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestNextTab() }
                } else {
                    // Cmd+] → next split
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestFocusNextSplit() }
                }
                return true
            case "[":
                if hasShift {
                    // Cmd+Shift+[ → previous tab
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestPreviousTab() }
                } else {
                    // Cmd+[ → previous split
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestFocusPreviousSplit() }
                }
                return true
            case "t":
                // Cmd+T → new tab in current session
                DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestNewTab() }
                return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                // Cmd+1–9 → switch to session by number
                if let num = Int(chars) {
                    DispatchQueue.main.async { TerminalCoordinatorRef.instance?.requestSwitchSession(index: num) }
                    return true
                }
            default:
                break
            }
        }

        // Route all other key equivalents through keyDown so ghostty processes them.
        keyDown(with: event)
        return true
    }

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

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        return translateModifiers(event.modifierFlags)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Update split focus on every click (becomeFirstResponder only fires on change)
        if let leafID {
            DispatchQueue.main.async { TerminalCoordinatorRef.instance?.leafDidFocus(leafID) }
        }
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        }
        leftMousePressed = true
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface, leftMousePressed else { return }
        leftMousePressed = false
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        // Build scroll mods: bit 0 = precision, bits 1+ = momentum phase.
        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    // MARK: - Copy / Paste

    @IBAction func copy(_ sender: Any?) {
        guard let surface else { return }
        _ = "copy_to_clipboard".withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    @IBAction func paste(_ sender: Any?) {
        guard let surface else { return }
        _ = "paste_from_clipboard".withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: - Cleanup

    func destroySurface() {
        if let surface {
            // Clear activeSurface if it points to this surface (prevents stale clipboard callbacks)
            if let app = ghosttyApp, app.activeSurface == surface {
                app.activeSurface = nil
            }
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let ptr = surfaceUserdata {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
            surfaceUserdata = nil
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
    /// The leaf ID in the split tree for focus tracking.
    var leafID: UUID?

    func makeNSView(context: Context) -> GhosttyNSView {
        return GhosttyNSView(ghosttyApp: ghosttyApp, command: command, leafID: leafID)
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        nsView.leafID = leafID
    }
}
