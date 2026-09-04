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
@MainActor @Observable
final class ModifierHintState {
    enum Level {
        case session
        case tab
        case pane
    }

    private(set) var level: Level?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var pending: DispatchWorkItem?

    /// Install the flagsChanged monitor (idempotent).
    func install() {
        guard monitor == nil else { return }
        // Dev/test: `--hint-level` pins badges on for screenshots.
        switch DevLaunchArgs.hintLevel {
        case "session": level = .session
        case "tab": level = .tab
        case "pane": level = .pane
        default: break
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in self?.update(flags) }
            return event
        }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection(.deviceIndependentFlagsMask)
        let target: Level?
        if mods == [.command] {
            target = .session
        } else if mods == [.command, .option] {
            target = .tab
        } else if mods == [.command, .control] {
            target = .pane
        } else {
            target = nil
        }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }
}
