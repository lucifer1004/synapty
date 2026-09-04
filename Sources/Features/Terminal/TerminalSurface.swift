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

    /// Belongs to the visible (active) pane. Hidden background panes must
    /// never take keyboard focus, ghostty focus, or the global activeSurface
    /// (WI-2026-08-08-007). Kept in sync by TerminalView.updateNSView.
    var isVisiblePane = true
    /// Is this the focused leaf of the visible pane (split focus).
    var isFocusedLeaf = true
    /// The Terminal PAGE itself is shown (not Hosts/Settings/...): focus
    /// gates include page visibility so a background page's surface can
    /// never steal focus, and returning to the page restores it
    /// (WI-2026-08-08-032).
    var isTerminalPageVisible = true

    /// SET ALL THREE TOGETHER, because the keyboard has to be reconciled
    /// whenever any of them moves. Assigned one by one, a caller could —
    /// and did — hide a pane or leave the page without ever asking
    /// whether this view was still entitled to the responder it held.
    func setPresentation(visiblePane: Bool, focusedLeaf: Bool, terminalPageVisible: Bool) {
        isVisiblePane = visiblePane
        isFocusedLeaf = focusedLeaf
        isTerminalPageVisible = terminalPageVisible
        reconcileKeyboardFocus()
    }

    /// WHETHER GHOSTTY THINKS THIS SURFACE IS FOCUSED, said out loud.
    ///
    /// A surface is focused by default when it is created, and nothing was
    /// telling the ones that are not: focus was only ever set TRUE, on the
    /// pane that took it, and set false by AppKit's own responder
    /// handover. A pane that never held the responder — every split beside
    /// the one the human is in — kept the default and drew a live blinking
    /// block, which reads as three terminals all waiting for the keystroke
    /// that can only go to one of them.
    func applyGhosttyFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, isVisiblePane && isFocusedLeaf && isTerminalPageVisible)
    }

    /// May this view hold the window's keyboard focus right now?
    var mayHoldKeyboard: Bool { isVisiblePane && isTerminalPageVisible }

    /// TAKE THE KEYBOARD OR HAND IT BACK — the two halves of one act.
    ///
    /// Only the taking was ever written. A surface grabs first responder
    /// when it becomes the visible focused leaf of a shown terminal page,
    /// and NOTHING gave it back: leaving for the Hosts page left this view
    /// as the window's first responder, so ⌘V — which the dispatcher
    /// correctly declines to run as a terminal command once the page is
    /// hidden — was handed to the responder chain, and a responder chain
    /// begins at the first responder. This view answers `paste:`. The
    /// clipboard went into the pane the human had just left.
    ///
    /// Handing back to the WINDOW rather than to a chosen view: which
    /// control should have the keyboard on another page is that page's
    /// business, and guessing here would be this view reaching into it.
    func reconcileKeyboardFocus() {
        guard let window, window.firstResponder === self, !mayHoldKeyboard else { return }
        window.makeFirstResponder(window)
    }

    override func becomeFirstResponder() -> Bool {
        guard isVisiblePane, isTerminalPageVisible else {
            // A hidden/background surface (e.g. a background session's pane
            // materializing) must never steal keyboard focus — redirect to
            // the visible focused surface (WI-2026-08-08-007).
            if let activeView = ghosttyApp?.activeView, activeView !== self {
                DispatchQueue.main.async {
                    activeView.window?.makeFirstResponder(activeView)
                }
            }
            return false
        }
        ghosttyApp?.activeSurface = surface
        ghosttyApp?.activeView = self
        if let surface {
            ghostty_surface_set_focus(surface, true)
            if let displayID = window?.screen?.displayID ?? NSScreen.main?.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
        // Notify coordinator of focus change for split navigation
        if let leafID {
            Task { @MainActor in TerminalCoordinatorRef.instance?.leafDidFocus(leafID) }
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
    /// Owned copy of `command` handed to libghostty. ghostty's embedded
    /// newConfig BORROWS opts.command (`config.command = .{ .shell = cmd }`,
    /// no arena dupe — unlike working_directory, which finalize() copies)
    /// and the IO thread reads it AFTER ghostty_surface_new returns, so a
    /// withCString temporary dangles and the surface silently falls back
    /// to the default shell (WI-2026-08-09-025 root cause). Keep the C
    /// string alive for the surface's lifetime instead.
    private var commandCString: UnsafeMutablePointer<CChar>?
    /// The leaf ID in the split tree, used to update paneManager focus on click.
    var leafID: UUID?
    /// Initial working directory (session restore, RFC-0006).
    private let workingDirectory: String?

    init(ghosttyApp: GhosttyApp, command: String? = nil, leafID: UUID? = nil, workingDirectory: String? = nil) {
        self.ghosttyApp = ghosttyApp
        self.command = command
        self.leafID = leafID
        self.workingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        // TWO KINDS OF DRAG ARRIVE HERE and mean entirely different
        // things: a file is copied to this pane's machine, a PANE is
        // moved into this pane's place in the layout
        // ([[WI-2026-08-17-028]]).
        registerForDraggedTypes(DraggedFileReader.acceptedTypes + [PaneDragBoard.type])
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

            if let surface {
                // Refresh the display id once the window/screen is fully
                // ready — a cold-start surface must not stay paused with
                // display_id 0, which stalls the shell spawn until some
                // later event re-applies ids (WI-2026-08-08-078).
                DispatchQueue.main.async { [weak self] in
                    self?.ghosttyApp?.refreshSurfaceDisplayIds()
                }
                // NO display-id write here: registerSurface -> applyDisplayIds
                // is the single source of truth for vsync pausing. Writing
                // the screen id here would un-pause a surface created while
                // hidden (WI-2026-08-08-032).
                updateSurfaceSize()

                // Only the visible focused leaf of the SHOWN terminal page
                // may steal focus: a background session's pane attaching to
                // the window — or any surface materializing while the user
                // is on another page — must not yank keyboard focus,
                // ghostty focus, or the global activeSurface
                // (WI-2026-08-08-007, WI-2026-08-08-032).
                applyGhosttyFocus()
                if isVisiblePane && isFocusedLeaf && isTerminalPageVisible {
                    ghosttyApp?.activeSurface = surface
                    ghosttyApp?.activeView = self
                    window?.makeFirstResponder(self)
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            // ALWAYS, not only in the key window: the pointer's exit from
            // this pane is what restores the arrow, and a human who clicked
            // another app first still moves the mouse away afterwards.
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
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

        // If a command was provided, run it in place of the default shell.
        // ghostty's embedded newConfig BORROWS opts.command (no arena dupe,
        // unlike working_directory, which finalize() copies) and the IO
        // thread may read it after ghostty_surface_new returns — keep the
        // C string alive for the surface's lifetime (commandCString, freed
        // in destroySurface after ghostty_surface_free).
        if let cmd = command, !cmd.isEmpty {
            commandCString = strdup(cmd)
            config.command = UnsafePointer(commandCString)
        }
        // Session restore (RFC-0006): start the shell in the recorded
        // cwd. finalize() COPIES working_directory (unlike command), so
        // a call-scoped C string is enough.
        if let wd = workingDirectory, !wd.isEmpty,
           FileManager.default.fileExists(atPath: wd)
        {
            wd.withCString { ptr in
                config.working_directory = ptr
                surface = ghostty_surface_new(app, &config)
            }
        } else {
            surface = ghostty_surface_new(app, &config)
        }

        if let surface {
            // Register for per-surface color scheme updates (WI-2026-08-07-005)
            // and leaf-ID → surface lookup for the clipboard callbacks
            // (WI-2026-08-08-008).
            ghosttyApp?.registerSurface(surface, leafID: leafID, view: self)
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

    /// WHAT REACHES HERE IS ALREADY THE TABLE'S ANSWER ([[RFC-0016]]
    /// C-DISPATCH). [[KeyDispatcher]] sees every keydown before the window
    /// does and consumes what the table names, so an event arriving here
    /// is one the table does NOT name — row 3, column 3: "offered to the
    /// terminal as key input".
    ///
    /// A SWITCH OF FOURTEEN CASES STOOD HERE, and ten of its chords were
    /// also menu key equivalents. It also asked ghostty whether the key
    /// was bound in ITS configuration, which no longer has an answer to
    /// give: the engine's binding set is empty ([[RFC-0016]] C-TERMINAL),
    /// so the terminal's own commands arrive as actions from the table
    /// rather than as keystrokes resolved down here.
    ///
    /// The guards remain, and they are not redundant: a hidden or
    /// background surface must not consume a shortcut (user report,
    /// WI-2026-08-09-003), and an event offered to a view that does not
    /// hold the responder belongs to whoever does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard isVisiblePane, isTerminalPageVisible else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard surface != nil else { return false }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Human-typing recency for the wake gate (RFC-0005 C-STATE-GATE:
        // injected text must never splice into a half-composed input).
        if let leafID {
            ghosttyApp?.noteHumanInput(leafID: leafID)
        }

        // WHETHER A COMPOSITION WAS IN PROGRESS WHEN THIS KEY ARRIVED, and
        // it has to be read BEFORE the input system sees the key, because
        // the key may be what ends it.
        let wasComposing = hasMarkedText()

        // Route through macOS text input system (handles IME, dead keys, key bindings).
        // This calls insertText/doCommandBySelector/setMarkedText on us.
        pendingText = nil
        interpretKeyEvents([event])

        // Build Ghostty key event with text produced by the input system
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = translateModifiers(event.modifierFlags)
        let disposition = Self.disposition(
            wasComposing: wasComposing,
            isComposing: hasMarkedText(),
            committed: pendingText)
        keyEvent.composing = (disposition == .composing)

        // unshifted_codepoint: the key's base character with no modifiers.
        // Ghostty's ctrlSeq uses it to lowercase letters (e.g. Ctrl+B with
        // caps lock must encode as 0x02). Without it, Ctrl sequences break.
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []),
           let scalar = chars.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }

        // consumed_mods: which modifiers contributed to the text translation.
        // Control and command never contribute to macOS text translation.
        keyEvent.consumed_mods = translateModifiers(
            event.modifierFlags.subtracting([.control, .command])
        )

        // Text handling: ghostty itself encodes control characters (Ctrl+A →
        // 0x01 etc.) from keycode+mods. If we pass the control character
        // produced by interpretKeyEvents (e.g. "\u{02}" for Ctrl+B) as text,
        // ghostty's ctrlSeq hits `else => null` and the key is swallowed —
        // breaking Ctrl passthrough to Zellij and friends. Only pass text for
        // printable characters (>= 0x20), mirroring Ghostty's own keyAction.
        let text: String
        switch disposition {
        case .send(let committed): text = committed ?? ""
        case .composing: text = ""
        }
        // BROADCAST ([[BroadcastRule]]): the same event, to every armed
        // sibling, while the text pointer is still alive. A composing
        // keystroke stays here — only the committed result is a
        // keystroke the others should see.
        let forwards = leafID != nil
            && BroadcastRule.forwards(disposition == .composing ? .imeComposing : .key)
        if !text.isEmpty,
           let first = text.utf8.first,
           first >= 0x20 {
            text.withCString { ptr in
                keyEvent.text = ptr
                ghostty_surface_key(surface, keyEvent)
                if forwards, let leafID { ghosttyApp?.forwardBroadcast(keyEvent, from: leafID) }
            }
        } else {
            keyEvent.text = nil
            ghostty_surface_key(surface, keyEvent)
            if forwards, let leafID { ghosttyApp?.forwardBroadcast(keyEvent, from: leafID) }
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
        if let leafID { ghosttyApp?.forwardBroadcast(keyEvent, from: leafID) }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // A COMPOSITION OWNS ITS MODIFIERS: while marked text is up the
        // input method is reading them, and a release forwarded to the
        // core mid-composition is what upstream skips too.
        if hasMarkedText() { return }
        let mods = translateModifiers(event.modifierFlags)
        guard let change = ModifierKey.classify(keyCode: event.keyCode,
                                                rawFlags: event.modifierFlags.rawValue,
                                                mods: mods.rawValue) else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = change.pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = mods
        keyEvent.composing = false
        keyEvent.text = nil
        ghostty_surface_key(surface, keyEvent)
        // Modifier state travels too, or a ⌃ held here is unheld there.
        if let leafID { ghosttyApp?.forwardBroadcast(keyEvent, from: leafID) }
    }

    /// The core's modifier word, as upstream builds it: the four modifiers,
    /// caps lock, and the right-hand side bits the device reports — the
    /// side is what a kitty-protocol program is told ([[WI-2026-09-02-019]]).
    private func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & ModifierKey.rightShift != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & ModifierKey.rightControl != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & ModifierKey.rightOption != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & ModifierKey.rightCommand != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
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
        pushPreedit()

        pendingText = text
    }

    /// WHAT A KEY MEANS ONCE THE INPUT SYSTEM HAS HAD IT.
    ///
    /// Separated from `keyDown` so the rule can be tested without an IME:
    /// the case that mattered cannot be reproduced from a synthesised
    /// NSEvent, because it is the input method's behaviour that produces
    /// it.
    ///
    /// THE CASE THAT WAS WRONG. Composing `nihao`, press backspace until
    /// the candidate is empty. On that last press the IME consumes the key
    /// and clears its preedit, so `hasMarkedText()` — read AFTER the input
    /// system — is false, the key was encoded, and the terminal deleted a
    /// character the human had already committed. Ghostty's own AppKit
    /// surface names the same case: "Japanese begin composing, then press
    /// backspace or ctrl+h. This should only cancel the composing state
    /// but not actually delete the prior input characters."
    ///
    /// AND WHY THE OBVIOUS REPAIR IS WRONG. Treating "was composing" as
    /// composing outright would suppress the COMMIT too — choosing a
    /// candidate also ends the composition — and Chinese input would stop
    /// producing anything at all. The discriminator is whether the input
    /// system handed back text: it commits through `insertText` and
    /// cancels through neither.
    static func disposition(
        wasComposing: Bool, isComposing: Bool, committed: String?
    ) -> KeyDisposition {
        if let committed { return .send(text: committed) }
        if isComposing || wasComposing { return .composing }
        return .send(text: nil)
    }

    enum KeyDisposition: Equatable {
        /// Encode it, with the text the input system produced if any.
        case send(text: String?)
        /// The input method took it. Nothing reaches the terminal.
        case composing
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

        // `pendingText` IS THE COMMITTED TEXT AND NOTHING ELSE. This also
        // set it to the composing string, so the one signal that says
        // "the IME produced something to type" could not be told from
        // "the IME is showing a candidate" — and the preedit does not
        // need it: Ghostty draws that from `ghostty_surface_preedit`
        // below.
        //
        // AND TELL THE TERMINAL WHAT IS BEING COMPOSED. Ghostty draws the
        // preedit itself, in the cells at the cursor, and reports the
        // cursor rect accordingly — so without this the terminal has no
        // idea a composition is in progress and `firstRect` above answers
        // for a cursor that has not moved to make room for it.
        pushPreedit()
    }

    func unmarkText() {
        markedTextStorage.mutableString.setString("")
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        pushPreedit()
    }

    /// The composing text, or its absence, handed to the terminal.
    private func pushPreedit() {
        guard let surface else { return }
        let text = markedTextStorage.string
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
            }
        }
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

    /// WHERE THE CANDIDATE WINDOW GOES: the CURSOR's cell, not the pane.
    ///
    /// This returned `bounds` — the whole pane — so macOS placed the
    /// candidate list at that rect's origin and every composition
    /// appeared at the top of the pane, however far down the cursor was.
    /// Most visible under a multiplexer, where the cursor is rarely near
    /// the top; but it was never right anywhere.
    ///
    /// Ghostty knows where the cursor is and will say so, in POINTS from
    /// the TOP-LEFT — AppKit measures from the bottom-left, so the flip
    /// is the whole of the conversion. The cell height it reports is
    /// used as the rect's height, which is what makes the candidate
    /// window sit below the line being typed rather than over it.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        guard let surface else { return window.convertToScreen(convert(bounds, to: nil)) }

        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        // Local space flips against bounds, not frame: equal today, wrong
        // the day the bounds origin moves.
        let cell = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        return window.convertToScreen(convert(cell, to: nil))
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
            Task { @MainActor in TerminalCoordinatorRef.instance?.leafDidFocus(leafID) }
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
        // RE-APPLY WHAT THE CORE LAST SAID. The core deduplicates its own
        // shape reports, so after we showed the arrow on exit it will not
        // repeat "text" on re-entry — it believes it already said so.
        // Measured: after a few rounds the I-beam never came back. Two
        // states are kept apart on purpose: what the core asked for
        // (never reset here) and what the pointer shows (ours, by
        // position).
        pointerInside = true
        TerminalSignals.cursor(for: coreShape).set()
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        // THE CORE DOES NOT SAY "DEFAULT" ON THE WAY OUT — it only knows
        // about cells, and leaving the pane is not a cell. Measured: the
        // I-beam followed the pointer into the sidebar and stayed there.
        // The exit is ours to see, so the reset is ours to do — and ONLY
        // the displayed cursor is reset; `coreShape` keeps the core's
        // last word for the next entry.
        pointerInside = false
        // NOT MID-DRAG. A selection dragged past the pane's edge keeps its
        // I-beam until the button is released; the arrow would otherwise
        // flicker in the middle of the gesture (upstream makes the same
        // exception).
        if NSEvent.pressedMouseButtons == 0 { NSCursor.arrow.set() }
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    // MARK: - Pointer shape ([[WI-2026-09-02-002]])

    /// What the core last asked the pointer to be over this pane. Never
    /// reset by an exit — see `mouseEntered`.
    private var coreShape = GHOSTTY_MOUSE_SHAPE_DEFAULT
    /// Whether the pointer is over this pane right now, which decides
    /// whether a shape report is shown immediately or merely remembered.
    private var pointerInside = false

    func setPointer(_ shape: ghostty_action_mouse_shape_e) {
        guard shape != coreShape else { return }
        coreShape = shape
        window?.invalidateCursorRects(for: self)
        if pointerInside { TerminalSignals.cursor(for: shape).set() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: TerminalSignals.cursor(for: coreShape))
    }

    // MARK: - Scrollbar ([[WI-2026-09-02-001]])

    private var scrollbarView: TerminalScrollbarView?

    /// Fed by GHOSTTY_ACTION_SCROLLBAR through GhosttyApp. Created on
    /// first report, because a surface that never reports one (dead pty)
    /// has nothing to draw.
    func noteScrollbar(total: Int, offset: Int, len: Int) {
        let bar: TerminalScrollbarView
        if let scrollbarView {
            bar = scrollbarView
        } else {
            bar = TerminalScrollbarView(frame: bounds)
            bar.autoresizingMask = [.width, .height]
            bar.onScrollToRow = { [weak self] row in
                guard let self, let surface = self.surface else { return }
                _ = "scroll_to_row:\(row)".withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
                }
            }
            addSubview(bar)
            scrollbarView = bar
        }
        bar.update(total: total, offset: offset, len: len)
    }

    // MARK: - Copy / Paste

    @IBAction func copy(_ sender: Any?) {
        guard let surface else { return }
        _ = "copy_to_clipboard".withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// NOT BROADCAST, by rule ([[BroadcastRule]]): a paste's size is
    /// invisible at the moment of the act, and armed or not, it lands
    /// only where ⌘V was pressed.
    @IBAction func paste(_ sender: Any?) {
        guard let surface else { return }
        _ = "paste_from_clipboard".withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }

    // MARK: - Cleanup

    func destroySurface() {
        if Thread.isMainThread {
            destroySurfaceOnMain()
            return
        }
        // A BACKGROUND DEINIT HANDS THE POINTERS OVER AND LETS GO
        // ([[WI-2026-09-02-022]]). This was `DispatchQueue.main.sync`: with
        // the main thread blocked — and it can be, for seconds — a teardown
        // on a SwiftUI background thread waited on it, one more waiter
        // short of a deadlock. Nothing here may touch `self` later (it is
        // being deallocated), so the raw pointers and the app go across
        // and the former view is known only by address, for the identity
        // comparison and nothing else.
        let surface = self.surface
        let userdata = surfaceUserdata
        let command = commandCString
        let app = ghosttyApp
        let former = Unmanaged.passUnretained(self).toOpaque()
        self.surface = nil
        surfaceUserdata = nil
        commandCString = nil
        DispatchQueue.main.async {
            GhosttyNSView.freeDetached(surface: surface, userdata: userdata,
                                       command: command, app: app, formerView: former)
        }
    }

    private func destroySurfaceOnMain() {
        let surface = self.surface
        let userdata = surfaceUserdata
        let command = commandCString
        self.surface = nil
        surfaceUserdata = nil
        commandCString = nil
        Self.freeDetached(surface: surface, userdata: userdata, command: command,
                          app: ghosttyApp, formerView: Unmanaged.passUnretained(self).toOpaque())
    }

    /// The one teardown, for both the main-thread and the detached path.
    @MainActor
    private static func freeDetached(surface: ghostty_surface_t?,
                                     userdata: UnsafeMutablePointer<UUID>?,
                                     command: UnsafeMutablePointer<CChar>?,
                                     app: GhosttyApp?, formerView: UnsafeMutableRawPointer) {
        if let surface {
            // A SURFACE THAT IS GONE ASKS FOR NOTHING. Without this a pane
            // closed at a password prompt left secure input on for the
            // rest of the process, and a reused pointer could inherit a
            // stale entry ([[WI-2026-09-02-033]]).
            SecureInput.forget(surface: UnsafeRawPointer(surface))
            if let app {
                if app.activeSurface == surface { app.activeSurface = nil }
                if let active = app.activeView,
                   Unmanaged.passUnretained(active).toOpaque() == formerView {
                    app.activeView = nil
                }
                // Teardown after shutdown would free a surface the app
                // already freed — the UAF isShuttingDown exists to guard.
                if !app.isShuttingDown {
                    app.unregisterSurface(surface)
                    ghostty_surface_free(surface)
                }
            }
        }
        if let ptr = userdata {
            ptr.deinitialize(count: 1)
            ptr.deallocate()
        }
        // Safe to free only after ghostty_surface_free: the surface's IO
        // side borrowed this string (see commandCString).
        if let cmdPtr = command { free(cmdPtr) }
    }

    deinit {
        destroySurface()
    }

    // MARK: - Dropping files onto a terminal

    /// Answers what a drop would do, for the hint shown while dragging.
    /// nil means this terminal will not take it.
    var dropPreview: (([FileEndpoint]) -> String?)?
    /// Performs the drop. True when it was taken.
    var dropHandler: (([FileEndpoint]) -> Bool)?

    /// THE ANSWER IS SHOWN BEFORE THE DROP COMMITS. The same gesture
    /// transfers across machines and inserts a path within one, and the
    /// destination directory may be a fallback rather than the shell's real
    /// one — none of which the human can infer from the drag itself
    /// ([[WI-2026-08-15-009]]).
    /// WHERE GHOSTTY SAYS THE LINK UNDER THE POINTER GOES, which is not
    /// necessarily what the human is reading: a hyperlink escape supplies
    /// the display text and the target separately.
    ///
    /// SHOWN, NOT MERELY HELD. [[RFC-0015]] C-DERIVED requires the
    /// resolved target in full before the action is taken, and for a link
    /// ghostty matched this is the only place it exists — the display text
    /// may be a name, a phrase, or nothing that names a destination at
    /// all. Holding it without drawing it left the human with a clickable
    /// span and no way to learn where it went.
    var linkUnderPointer: String? {
        didSet {
            guard linkUnderPointer != oldValue else { return }
            drawLinkPreview()
        }
    }

    private var linkPreview: NSView?

    private var dropHint: NSView?
    /// What the chip currently says, so an unchanged answer does not
    /// rebuild it on every mouse move.
    private var dropHintText: String?

    /// A PANE NOBODY CAN SEE MUST BE ABSENT, not merely transparent.
    ///
    /// Every leaf of every session lives in one ZStack at the SAME frame —
    /// measured, three leaves all reporting `289,39 1822x1295` — with the
    /// inactive ones behind the visible one under `.opacity(0)` and
    /// `.allowsHitTesting(false)`. That pair governs SwiftUI's own hit
    /// testing and says nothing to the AppKit drag machinery, which finds
    /// its destination by walking the NSView tree. So a file dragged onto
    /// the visible local terminal was offered to, and accepted by, an
    /// invisible pane belonging to another host: the transfer log recorded
    /// `remotehost:/home/operator/Caddyfile -> otherhost:~`.
    ///
    /// REFUSING IS NOT ENOUGH, and this was measured too. A `hitTest`
    /// returning nil and a `draggingEntered` returning no operation both
    /// end the search rather than passing it to the sibling underneath —
    /// with the guard in place the log showed the drag arriving at a leaf
    /// with `visible=false` and then nothing at all, so the pane the human
    /// was pointing at was never asked. `isHidden` is the one state AppKit
    /// treats as "this view is not in the hierarchy for hit-testing
    /// purposes", which is exactly the claim being made.
    ///
    /// The surface itself keeps living: the view stays in the tree, its
    /// frame is untouched, and the pty and its children run on. Removing
    /// the view is what would kill them, which is why nothing here does.
    func applyVisibility() {
        let shown = isVisiblePane && isTerminalPageVisible
        guard isHidden == shown else { return }
        isHidden = !shown
    }

    /// A PANE RELEASED ON THIS ONE, and where in it. nil means this
    /// terminal will not take a pane — the same shape the file handlers
    /// use ([[WI-2026-08-17-028]]).
    var paneDropHandler: ((UUID, PaneDropRegion) -> Void)?

    /// The region highlighted right now, so a pointer moving inside one
    /// region does not rebuild the overlay on every mouse move.
    private var dockHint: NSView?
    private var dockRegion: PaneDropRegion?

    /// The region a pane drag currently sits over, or nil when this drag
    /// is not carrying a pane.
    private func dockRegion(for sender: any NSDraggingInfo) -> PaneDropRegion? {
        guard paneDropHandler != nil,
              PaneDragBoard.paneID(on: sender.draggingPasteboard) != nil else { return nil }
        return PaneDropRegion.at(flippingY: convert(sender.draggingLocation, from: nil),
                                 in: bounds.size)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // WHICH VIEW APPKIT PICKED, before anything can refuse and hide the
        // answer. Every leaf of every session overlaps every other, so the
        // question "who was asked" has been the root of two wrong-machine
        // bugs and cannot be reasoned out from the source.
        let inWindow = sender.draggingLocation
        let mine = convert(bounds, to: nil)
        AppLog.transfer.info(
            "drag over leaf=\(self.leafID?.uuidString.prefix(8) ?? "none", privacy: .public) visible=\(self.isVisiblePane, privacy: .public) page=\(self.isTerminalPageVisible, privacy: .public) point=\(Int(inWindow.x), privacy: .public),\(Int(inWindow.y), privacy: .public) frame=\(Int(mine.minX), privacy: .public),\(Int(mine.minY), privacy: .public) \(Int(mine.width), privacy: .public)x\(Int(mine.height), privacy: .public) hidden=\(self.isHidden, privacy: .public)")
        guard isVisiblePane, isTerminalPageVisible else { return [] }
        if let region = dockRegion(for: sender) {
            showDockHint(region)
            return .move
        }
        let endpoints = DraggedFileReader.readAll(from: sender.draggingPasteboard)
        // WHAT THE BOARD ACTUALLY CARRIES, because refusing a drag is
        // invisible: the cursor simply never accepts, and no code runs
        // afterwards to report anything. A human dragging from the panel
        // onto a terminal saw nothing happen and nothing said why.
        if endpoints.isEmpty || dropPreview == nil {
            let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
            let preview = self.dropPreview == nil ? "nil" : "set"
            AppLog.transfer.error(
                "drag refused: endpoints=\(endpoints.count, privacy: .public) preview=\(preview, privacy: .public) board=[\(types, privacy: .public)]")
        }
        guard !endpoints.isEmpty, let hint = dropPreview?(endpoints) else { return [] }
        showDropHint(hint)
        return .copy
    }

    /// THE ANSWER CAN ARRIVE MID-DRAG. A remote pane's working directory
    /// costs an ssh round trip, which cannot be spent inside
    /// `draggingEntered` — AppKit wants that turn back. So the hint is
    /// shown with what is known, the query runs, and this replaces the text
    /// when it lands; a human hovers for longer than the round trip takes.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // A PANE DRAG IS TRACKED THE WHOLE WAY ACROSS. Which region the
        // pointer is in IS the answer here — unlike a file, whose
        // destination is the pane and does not change as the pointer
        // moves within it.
        if let region = dockRegion(for: sender) {
            if region != dockRegion { showDockHint(region) }
            return .move
        }
        guard dropHint != nil else { return [] }
        let endpoints = DraggedFileReader.readAll(from: sender.draggingPasteboard)
        if let hint = dropPreview?(endpoints), hint != dropHintText { showDropHint(hint) }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropHint()
        clearDockHint()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearDropHint()
        clearDockHint()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        clearDropHint()
        // Belt to the hit test's braces: this one decides where a file
        // GOES, and the cost of the two disagreeing is a file on the wrong
        // machine.
        guard isVisiblePane, isTerminalPageVisible else { clearDockHint(); return false }
        // THE REGION IS READ FROM THIS EVENT, not from what was last
        // highlighted. The two agree while the pointer is moving, and the
        // release is the one that counts.
        if let region = dockRegion(for: sender),
           let paneID = PaneDragBoard.paneID(on: sender.draggingPasteboard) {
            clearDockHint()
            paneDropHandler?(paneID, region)
            return true
        }
        clearDockHint()
        let endpoints = DraggedFileReader.readAll(from: sender.draggingPasteboard)
        guard !endpoints.isEmpty else { return false }
        return dropHandler?(endpoints) ?? false
    }

    /// WHERE THE PANE WILL LAND, drawn over the terminal it will land on.
    ///
    /// THE SAME VIEW MOVES; IT IS NOT REBUILT. Tearing this down and
    /// adding another one made the mark TELEPORT from a pane's left half
    /// to its centre as the pointer crossed the band — the single thing
    /// that made this read as a debug overlay rather than a preview. The
    /// frame is animated instead, so the shape the human is choosing
    /// grows into the shape they will get.
    ///
    /// Drawn in AppKit and not SwiftUI for the same reason the file chip
    /// is: this view renders through a Metal layer a sibling would have
    /// to be layered over, and the drag session is AppKit's already. It
    /// draws what `DropMark` specifies — soft fill, no stroke, radius 2
    /// — because a mark that differed here would be a second vocabulary
    /// on the one surface that shows both.
    private func showDockHint(_ region: PaneDropRegion) {
        let frame = PaneDragBoard.highlight(region, in: bounds, flipped: true)
        guard let block = dockHint else {
            let block = NSView(frame: frame)
            block.wantsLayer = true
            // RESOLVED AGAINST THIS VIEW'S APPEARANCE, because a CGColor
            // is a resolved value and a layer will not re-resolve it. The
            // mark is torn down at the end of every drag, so resolving
            // here is resolving at the moment it is shown.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                block.layer?.backgroundColor = DS.accentSoftNSColor.cgColor
            }
            block.layer?.cornerRadius = DropMark.cornerRadius
            block.alphaValue = 0
            addSubview(block)
            dockHint = block
            dockRegion = region
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                block.animator().alphaValue = 1
            }
            return
        }
        dockRegion = region
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            block.animator().frame = frame
        }
    }

    private func clearDockHint() {
        dockHint?.removeFromSuperview()
        dockHint = nil
        dockRegion = nil
    }

    private func showDropHint(_ text: String) {
        clearDropHint()
        dropHintText = text
        // Drawn here rather than in a SwiftUI overlay: this view renders
        // through a Metal layer that a sibling would have to be layered
        // over, and the state being reported belongs to the drag session
        // AppKit is already running.
        // PADDING IS A CONTAINER'S JOB, NOT THE LABEL'S. Growing the
        // label's own frame past sizeToFit made NSTextField draw its text
        // against the top of that frame, so the chip clipped the ascenders
        // — the padding was there and the text was not inside it.
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.alignment = .center
        label.sizeToFit()

        let padding = NSSize(width: 14, height: 9)
        let chip = NSView(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2))
        chip.wantsLayer = true
        // Sits over arbitrary terminal content whose colours are the
        // human's, so it carries its own contrast rather than borrowing
        // any. A pill, not a box: it is a transient label following a
        // pointer, and a rectangle with a hairline reads as a panel that
        // arrived.
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        chip.layer?.cornerRadius = chip.frame.height / 2
        chip.layer?.shadowColor = NSColor.black.cgColor
        chip.layer?.shadowOpacity = 0.35
        chip.layer?.shadowRadius = 8
        chip.layer?.shadowOffset = .zero
        label.frame = NSRect(
            x: padding.width, y: padding.height,
            width: label.frame.width, height: label.frame.height)
        chip.addSubview(label)
        chip.setFrameOrigin(NSPoint(
            x: (bounds.width - chip.frame.width) / 2,
            y: bounds.height * 0.12))
        addSubview(chip)
        dropHint = chip

        wantsLayer = true
        layer?.borderWidth = DropMark.lineThickness
        // THE SAME ACCENT THE PANE MARK USES. Both say "this surface is
        // receiving what you are dragging", and answering that in the
        // system blue for a file and the brand teal for a pane made one
        // surface speak two languages ([[ADR-0011]]).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = DS.accentNSColor.cgColor
        }
    }

    private func clearDropHint() {
        dropHint?.removeFromSuperview()
        dropHint = nil
        dropHintText = nil
        layer?.borderWidth = 0
    }

    // MARK: - What the pointer is over ([[RFC-0015]] C-DERIVED)

    /// THE DESTINATION, BESIDE THE POINTER AND NEVER OVER THE LINE IT
    /// DESCRIBES.
    private func drawLinkPreview() {
        linkPreview?.removeFromSuperview()
        linkPreview = nil
        guard let reported = linkUnderPointer, let window,
              let surface, let metrics = OutputAffordance.Metrics(surface: surface, bounds: bounds),
              let location = window.mouseLocationOutsideOfEventStream
                as CGPoint?,
              let cell = metrics.cell(at: convert(location, from: nil))
        else { return }
        // WHAT WOULD OPEN, WHICH IS THIS APPLICATION'S ANSWER AND NOT THE
        // ONE GHOSTTY RESOLVED — a relative path resolved against OSC 7 is
        // a place the child chose, and showing it would promise the human
        // something else opens.
        let shownTarget: String
        switch target(forLink: reported) {
        case .path(let path): shownTarget = path
        case .declared(_, let declared, _): shownTarget = declared
        case .none: shownTarget = reported
        }
        let chip = Self.makeAffordanceChip(text: shownTarget, appearance: effectiveAppearance)
        let span = metrics.rect(row: cell.row, cells: cell.column..<(cell.column + 1))
        let above = span.maxY + 4
        let y = above + chip.frame.height <= bounds.height
            ? above : span.minY - chip.frame.height - 4
        chip.setFrameOrigin(NSPoint(
            x: min(max(0, span.minX), max(0, bounds.width - chip.frame.width)), y: y))
        addSubview(chip)
        linkPreview = chip
    }

    /// WHAT THE HUMAN AGREED TO, WHICH IS NOT ALWAYS WHAT GHOSTTY RESOLVED.
    ///
    /// Its matcher finds the span and reports a target. For a scheme url
    /// that target is the answer — it is either the characters themselves
    /// or a hyperlink escape's declared one, and rule two decides between
    /// them. For a PATH it is not: `resolvePathForOpening` resolves a
    /// relative name against `terminal.getPwd()`, which is OSC 7 and so a
    /// directory the child chose. Those characters are re-read here and
    /// resolved against a base the child cannot choose ([[RFC-0015]]
    /// C-DERIVED rule two).
    private func target(forLink url: String) -> Resolution? {
        let shown = textUnderPointer() ?? ""
        if let resolved = URL(string: url), resolved.scheme != nil {
            return .declared(shown: shown, target: url, url: resolved)
        }
        let base = TerminalCoordinatorRef.instance.flatMap {
            leafID.flatMap($0.resolutionBase(ofLeaf:))
        }
        guard case .path(let path)? = OutputDetector.detect(in: shown, base: base).first?.kind
        else { return nil }
        return .path(path)
    }

    private enum Resolution {
        case path(String)
        case declared(shown: String, target: String, url: URL)
    }

    /// Follow what ghostty marked, once this application has decided what
    /// it actually is.
    func followLink(_ url: String) {
        switch target(forLink: url) {
        case .none:
            return
        case .path(let path):
            guard let leafID else { return }
            TerminalCoordinatorRef.instance?.showWhereItLives(path, from: leafID)
        case .declared(let shown, let target, let resolved):
            // A FILE IS SHOWN, NOT LAUNCHED. Handing one to the system
            // opener starts whatever application claims the extension,
            // which is running a program on a target untrusted text chose.
            if resolved.isFileURL {
                guard DeclaredTarget.verdict(shown: shown, target: target) == .follow else {
                    return askBeforeFollowing(shown: shown, target: target, resolved: resolved)
                }
                guard let leafID else { return }
                TerminalCoordinatorRef.instance?.showWhereItLives(resolved.path, from: leafID)
                return
            }
            // EVERY OTHER SCHEME REACHES A REGISTERED APPLICATION. The web
            // is the one a human can judge from the string they were shown
            // ([[RFC-0015]] C-DERIVED rule five). ONE LIST, the one the
            // browser leaf already publishes under C-CONTENT's obligation.
            guard let scheme = resolved.scheme?.lowercased(),
                  BrowserAddress.allowedSchemes.contains(scheme)
            else { return refuse(scheme: resolved.scheme ?? "", target: target) }

            switch DeclaredTarget.verdict(shown: shown, target: target) {
            case .follow: NSWorkspace.shared.open(resolved)
            case .ask: askBeforeFollowing(shown: shown, target: target, resolved: resolved)
            }
        }
    }

    /// The whitespace-delimited characters under the pointer — what the
    /// human is actually reading, whatever the link claims.
    private func textUnderPointer() -> String? {
        guard let surface,
              let metrics = OutputAffordance.Metrics(surface: surface, bounds: bounds),
              let location = window?.mouseLocationOutsideOfEventStream
        else { return nil }
        let point = convert(location, from: nil)
        guard let cell = metrics.cell(at: point) else { return nil }
        return OutputAffordance.token(
            surface: surface, row: cell.row, column: cell.column, columns: metrics.columns)
    }

    /// A SCHEME THIS APPLICATION WILL NOT HAND TO THE SYSTEM, and what it
    /// will. The wording is the browser leaf's, from the same list.
    private func refuse(scheme: String, target: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "This link opens an application, not a page"
        alert.informativeText =
            "\"\(Self.readable(scheme)):\" would hand \(Self.readable(target)) to whichever "
            + "application claims it, and nothing here can tell you which. "
            + "Links are followed for \(BrowserAddress.allowedSchemes.joined(separator: " and ")) "
            + "addresses."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    private func askBeforeFollowing(shown: String, target: String, resolved: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This link does not go where it says"
        // BOTH, VERBATIM AND IN THE SAME TYPEFACE. The whole content of
        // the warning is that these two differ, so presenting one of them
        // more prettily than the other would bury it.
        // WHICH CHARACTERS WERE COMPARED, SAID PLAINLY. The clause requires
        // an implementation comparing less than the whole link span to name
        // what it did compare — a warning that implies it read the whole
        // phrase would be making a promise this does not keep.
        alert.informativeText =
            "The word under the pointer reads as:\n\(Self.readable(shown))\n\n"
            + "It opens:\n\(Self.readable(target))\n\n"
            + "An agent chose both. Open it only if you meant to go to the second."
        // CANCEL FIRST, SO IT IS THE DEFAULT. A dialog whose default
        // button does the risky thing does it whenever a human presses
        // Return out of habit.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Anyway")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.open(resolved)
        }
    }

    /// A PILL CARRYING A DESTINATION, over terminal colours that are the
    /// human's, so it brings its own contrast rather than borrowing any.
    private static func makeAffordanceChip(text: String, appearance: NSAppearance) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        let padding = NSSize(width: 8, height: 4)
        let chip = NSView(frame: NSRect(
            x: 0, y: 0,
            width: label.frame.width + padding.width * 2,
            height: label.frame.height + padding.height * 2))
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        chip.layer?.cornerRadius = 4
        label.frame = NSRect(
            x: padding.width, y: padding.height,
            width: label.frame.width, height: label.frame.height)
        chip.addSubview(label)
        return chip
    }

    /// STRIP WHAT CAN REORDER WHAT IS READ. The whole content of that
    /// warning is that two strings differ, and both come from the party
    /// being warned about — a bidirectional override inside one of them
    /// could make it render as the other.
    private static func readable(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return false
            default: return !(scalar.properties.generalCategory == .control)
            }
        })
    }

}

/// SwiftUI wrapper for GhosttyNSView.
struct TerminalView: NSViewRepresentable {
    let ghosttyApp: GhosttyApp
    /// Optional command to run inside the terminal instead of the default shell.
    var command: String?
    /// Initial working directory (session restore, RFC-0006).
    var workingDirectory: String?
    /// The leaf ID in the split tree for focus tracking.
    var leafID: UUID?
    /// Belongs to the visible (active) pane — hidden panes must not steal
    /// keyboard focus (WI-2026-08-08-007).
    var isVisiblePane: Bool = true
    /// Is the focused leaf of the visible pane (split focus).
    var isFocusedLeaf: Bool = true
    /// The Terminal page is the shown page (WI-2026-08-08-032).
    var isTerminalPageVisible: Bool = true
    /// Files dropped onto this surface ([[WI-2026-08-15-009]]). Resolved by
    /// the caller, which knows which session this leaf belongs to.
    var dropPreview: (([FileEndpoint]) -> String?)?
    var dropHandler: (([FileEndpoint]) -> Bool)?
    /// A pane dropped onto this one ([[WI-2026-08-17-028]]).
    var paneDropHandler: ((UUID, PaneDropRegion) -> Void)?

    func makeNSView(context: Context) -> GhosttyNSView {
        let nsView = GhosttyNSView(
            ghosttyApp: ghosttyApp, command: command, leafID: leafID,
            workingDirectory: workingDirectory)
        nsView.setPresentation(visiblePane: isVisiblePane, focusedLeaf: isFocusedLeaf,
                               terminalPageVisible: isTerminalPageVisible)
        nsView.dropPreview = dropPreview
        nsView.dropHandler = dropHandler
        nsView.paneDropHandler = paneDropHandler
        nsView.applyVisibility()
        return nsView
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        let wasFocused = nsView.isVisiblePane && nsView.isFocusedLeaf && nsView.isTerminalPageVisible
        nsView.leafID = leafID
        // Re-bound every update: these closures capture the pane manager's
        // current state, and a stale one would resolve the drop against a
        // session layout that has moved on.
        nsView.dropPreview = dropPreview
        nsView.dropHandler = dropHandler
        nsView.paneDropHandler = paneDropHandler
        nsView.setPresentation(visiblePane: isVisiblePane, focusedLeaf: isFocusedLeaf,
                               terminalPageVisible: isTerminalPageVisible)
        nsView.applyVisibility()
        // SAID ON EVERY UPDATE, not only on the way in. AppKit resigns the
        // responder it hands over FROM, so pane-to-pane switching told the
        // old one; nothing told a pane that lost focus without another
        // taking the responder — a rearrange, a close, a page change.
        nsView.applyGhosttyFocus()
        let nowFocused = isVisiblePane && isFocusedLeaf && isTerminalPageVisible
        if nowFocused && !wasFocused {
            // This leaf just became the focused terminal (pane/session/split
            // switch, or RETURNING to the Terminal page) — take keyboard
            // focus so keystrokes land here instead of on the hidden
            // previous surface (WI-2026-08-08-007, WI-2026-08-08-032).
            DispatchQueue.main.async { [weak nsView] in
                guard let nsView else { return }
                // Re-check: the user may have clicked elsewhere in the
                // meantime (WI-2026-08-08-032).
                guard nsView.isVisiblePane, nsView.isTerminalPageVisible else { return }
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

