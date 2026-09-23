import AppKit
import Observation

/// Modifier-hold hint state (WI-2026-08-09-015) — the discoverability
/// layer of the three-tier switching scheme:
///
///   hold ⌘        → number badges on sidebar SESSIONS   (⌘1–9)
///   hold ⌘⌥       → number badges on TAB chips          (⌘⌥1–9)
///   hold ⌘⌃       → number badges on split PANE corners (⌘⌃1–9)
///
/// Appearance is DELAYED (350ms) so ordinary chords (⌘C, ⌘T…) never
/// flash badges; release hides instantly. Local flagsChanged monitor —
/// the reliable event layer in this app (focused terminals consume key
/// events before menu dispatch, but flagsChanged always flows).
///
/// A LOCAL MONITOR ONLY HEARS WHAT THIS APP IS SENT, AND THAT IS WHY THE
/// BADGES USED TO STICK ([[WI-2026-09-21-001]]). Every way of leaving the
/// workbench with ⌘ already down takes the key-up with it: ⌘Tab hands the
/// switcher the release, ⌘Space hands it to Spotlight, ⌘` ⌘H ⌘M all do
/// the same. The monitor never hears the modifier come up, so the numbers
/// stayed on every workspace row until the human pressed and released ⌘
/// again inside the app — which is the one input that could still reach
/// it.
///
/// SO LEAVING THE APP IS ITSELF AN EVENT. Losing active status means the
/// keyboard is somebody else's now, and nothing this object believes
/// about the modifiers can still be true. Coming back re-asks the
/// keyboard rather than assuming, because the human may well arrive still
/// holding ⌘ — that is what finishing a ⌘Tab looks like.
@MainActor @Observable
final class ModifierHintState {
    enum Level {
        case session
        case tab
        case pane
    }

    /// WHAT A SET OF MODIFIERS MEANS, with no state and no timer in it, so
    /// the mapping can be asked directly rather than through a monitor
    /// nothing in a test can post to.
    ///
    /// EXACT SETS, NOT `contains`. ⌘⇧ is a selection gesture and ⌘⌥⌃ is
    /// nothing this app claims; a hint shown for either would be a promise
    /// that the matching chord does something.
    static func level(for flags: NSEvent.ModifierFlags) -> Level? {
        switch flags.intersection(.deviceIndependentFlagsMask) {
        case [.command]: return .session
        case [.command, .option]: return .tab
        case [.command, .control]: return .pane
        default: return nil
        }
    }

    /// HOW LONG A HOLD MUST LAST BEFORE IT COUNTS AS A HOLD. Long enough
    /// that ⌘C never flashes anything, short enough that someone reaching
    /// for the feature does not conclude it is missing.
    static let appearanceDelay: TimeInterval = 0.35

    private(set) var level: Level?

    /// PINNED FOR A SCREENSHOT, and then nothing may move it
    /// (`--hint-level`). This used to be a one-off write to `level`, which
    /// the first stray modifier undid; now that leaving the app also
    /// clears, a pin that anything could clear would be a pin that usually
    /// is not there by the time the shutter opens.
    @ObservationIgnored private var pinned: Level?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: DispatchWorkItem?

    /// Install the flagsChanged monitor and the activation observers
    /// (idempotent).
    func install() {
        guard monitor == nil else { return }
        // Dev/test: `--hint-level` pins badges on for screenshots.
        switch DevLaunchArgs.hintLevel {
        case "session": pinned = .session
        case "tab": pinned = .tab
        case "pane": pinned = .pane
        default: break
        }
        level = pinned

        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // ALREADY ON THE MAIN THREAD, and said so rather than hopped.
            // This used to wrap the call in a `Task { @MainActor in … }`,
            // which buys nothing an assertion does not and puts the state
            // a runloop turn behind the keyboard — with two unstructured
            // tasks in flight for a press and its release.
            MainActor.assumeIsolated {
                self?.modifiersChanged(to: event.modifierFlags)
            }
            return event
        }

        let centre = NotificationCenter.default
        observers.append(centre.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationResignedActive() }
        })
        observers.append(centre.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applicationBecameActive(holding: NSEvent.modifierFlags)
            }
        })
    }

    /// The modifiers changed while this app had the keyboard.
    func modifiersChanged(to flags: NSEvent.ModifierFlags) {
        guard pinned == nil else { return }
        let target = Self.level(for: flags)

        pending?.cancel()
        pending = nil

        guard let target else {
            level = nil
            return
        }
        if level != nil {
            // Already showing — retarget instantly (e.g. ⌘ held, ⌥ added).
            level = target
        } else {
            let work = DispatchWorkItem { [weak self] in self?.level = target }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearanceDelay, execute: work)
        }
    }

    /// THE KEYBOARD IS SOMEBODY ELSE'S NOW. Whatever this object believed
    /// about which modifiers are down, it cannot learn that they came up:
    /// the release is delivered to whatever took over.
    ///
    /// THE PENDING WORK GOES TOO, and that is the second half. A hold that
    /// had not yet reached its delay would otherwise land its badges after
    /// the human had already left — numbers appearing on a window nobody
    /// is looking at, with nothing left that could take them away.
    func applicationResignedActive() {
        guard pinned == nil else { return }
        pending?.cancel()
        pending = nil
        level = nil
    }

    /// BACK, AND THE KEYBOARD IS ASKED RATHER THAN ASSUMED. Arriving with
    /// ⌘ still down is the ordinary way a ⌘Tab ends, and no flagsChanged
    /// describes it — the press happened in another app's hearing.
    ///
    /// THROUGH THE DELAY, NOT AROUND IT. Finishing a ⌘Tab means ⌘ comes up
    /// within a few dozen milliseconds, and badges that flashed on the way
    /// in would be the same noise the delay exists to prevent.
    func applicationBecameActive(holding flags: NSEvent.ModifierFlags) {
        guard pinned == nil else { return }
        level = nil
        modifiersChanged(to: flags)
    }
}
