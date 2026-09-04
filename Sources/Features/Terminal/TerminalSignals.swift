import AppKit
import Carbon.HIToolbox

/// WHAT THE TERMINAL CORE TELLS US THAT WE USED TO IGNORE.
///
/// An audit of ghostty's action vocabulary against our `action_cb` found
/// 79 actions and 15 handled. Most of the rest are window and tab
/// management this application does itself. These are the ones that were
/// simply dropped: the pointer never changed shape over text or a link, a
/// password prompt never turned on secure keyboard entry, a finished
/// command said nothing, a progress report drew nothing, an unhealthy
/// renderer looked like an empty pane. Each is one case in a switch and
/// one small piece of behaviour; this file holds the pieces a test can
/// hold ([[WI-2026-09-02-002]]).
enum TerminalSignals {

    // MARK: - Pointer

    /// The platform cursor for a shape the core asked for. The mapping is
    /// the one ghostty's own macOS app uses, so a pane here and a pane
    /// there feel the same under the pointer.
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: return .resizeLeft
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: return .resizeUpDown
        default: return .arrow
        }
    }

    // MARK: - Finished commands

    /// `1m 23s`, `4.2s`, `850ms` — the shape a human reads at a glance.
    static func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }

    /// How long a command must have run, in a pane the human is not
    /// watching, before its end rings the pane's bell. Ghostty's own
    /// default is five seconds; ten keeps a background `git pull` quiet.
    static let commandFinishBell: TimeInterval = 10

    // MARK: - Split snapping

    /// The nearest cell boundary, so a divider lands where the grid does
    /// and no pane carries a half-row of dead space along its edge.
    static func snap(_ offset: CGFloat, toCell cell: CGFloat) -> CGFloat {
        guard cell > 0 else { return offset }
        return (offset / cell).rounded() * cell
    }

    // MARK: - Shell integration

    /// The `shell-integration` value for the human's shell, or nil to leave
    /// ghostty's default (`detect`) alone.
    ///
    /// DETECTION CANNOT WORK HERE, and this is why the setting is written
    /// out: ghostty detects the shell from the command's `basename(arg0)`,
    /// and every pane's arg0 is our own wrapper — `synapty run … -- $SHELL`
    /// — so it saw `synapty`, gave up, and logged "shell could not be
    /// detected". Without integration there are no OSC 133 prompt marks,
    /// no `jump_to_prompt`, no finished-command reports, and no OSC 7 from
    /// a local shell — the last being the whole reason [[ProcessCwd]] had
    /// to go and ask the kernel. Naming the shell explicitly restores all
    /// of it: the injection rides environment variables, which pass
    /// through the wrapper untouched.
    static func shellIntegrationValue(forShellPath path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return ["bash", "zsh", "fish", "elvish"].contains(name) ? name : nil
    }
}

/// macOS Secure Keyboard Entry, driven by the core's password-prompt
/// detection. Every terminal on this platform does this; a keylogger-shaped
/// process cannot read what is typed while it is on.
@MainActor
enum SecureInput {
    private(set) static var enabled = false
    /// THE SURFACES THAT WANT IT ([[WI-2026-09-02-019]]). One app-global
    /// flag raced: two panes prompting for passwords at once, and the
    /// first one's OFF disabled secure entry while the second still
    /// prompted. Secure entry is on while ANY surface asks for it.
    private static var wanting: Set<UnsafeRawPointer> = []

    static func set(_ on: Bool) {
        guard on != enabled else { return }
        if on { EnableSecureEventInput() } else { DisableSecureEventInput() }
        enabled = on
    }

    static func apply(_ mode: ghostty_action_secure_input_e, surface: UnsafeRawPointer) {
        set(decide(mode, surface: surface, wanting: &wanting))
    }

    /// The pure half: what the set of asking surfaces becomes, and whether
    /// secure entry should be on afterwards.
    static func decide(_ mode: ghostty_action_secure_input_e, surface: UnsafeRawPointer,
                       wanting: inout Set<UnsafeRawPointer>) -> Bool {
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON: wanting.insert(surface)
        case GHOSTTY_SECURE_INPUT_OFF: wanting.remove(surface)
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            if wanting.contains(surface) { wanting.remove(surface) } else { wanting.insert(surface) }
        default: break
        }
        return !wanting.isEmpty
    }

    /// A surface that is gone asks for nothing.
    static func forget(surface: UnsafeRawPointer) {
        wanting.remove(surface)
        set(!wanting.isEmpty)
    }
}

/// A MODIFIER KEY'S PRESS OR RELEASE, from a flagsChanged event
/// ([[WI-2026-09-02-019]]). AppKit reports only the resulting flag state;
/// which key moved, and which way, is read from the keycode against that
/// state — and for a right-hand key from the device-side mask, so pressing
/// right shift while left shift is held is a press, not a no-op. This is
/// upstream ghostty's rule, ported. flagsChanged used to report PRESS for
/// every event, so a program on the kitty keyboard protocol saw a modifier
/// pressed and never released.
enum ModifierKey {
    // IOKit's device-side flag bits (IOLLEvent.h), which NSEvent carries in
    // its raw modifierFlags.
    static let rightShift: UInt = 0x0000_0004
    static let rightControl: UInt = 0x0000_2000
    static let rightOption: UInt = 0x0000_0040
    static let rightCommand: UInt = 0x0000_0010

    struct Change: Equatable {
        /// The GHOSTTY_MODS_* bit this key contributes.
        var mod: UInt32
        var pressed: Bool
    }

    /// Nil for a keycode that is not a modifier (fn, for one): nothing to
    /// send. `mods` is the translated ghostty mods for the event's flags.
    static func classify(keyCode: UInt16, rawFlags: UInt, mods: UInt32) -> Change? {
        let mod: UInt32
        switch keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return nil
        }
        guard mods & mod != 0 else { return Change(mod: mod, pressed: false) }
        // The flag is set; for a right-hand key that only means "some
        // side is down", so ask the device mask whether it was THIS side.
        let sidePressed: Bool
        switch keyCode {
        case 0x3C: sidePressed = rawFlags & rightShift != 0
        case 0x3E: sidePressed = rawFlags & rightControl != 0
        case 0x3D: sidePressed = rawFlags & rightOption != 0
        case 0x36: sidePressed = rawFlags & rightCommand != 0
        default: sidePressed = true
        }
        return Change(mod: mod, pressed: sidePressed)
    }
}
