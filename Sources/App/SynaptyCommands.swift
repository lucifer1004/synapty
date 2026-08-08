import SwiftUI

/// macOS menu bar commands for Synapty.
/// Provides discoverable keyboard shortcuts and fallback when terminal doesn't have focus.
struct SynaptyCommands: Commands {
    var body: some Commands {
        // Replace default "New Window" with Shell menu items
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                // A brand-new local session (ContentView.addLocalSession via
                // notification). Deliberately NOT requestNewTab(): that would
                // ALSO add a pane to the current session — a double action
                // (WI-2026-08-08-012).
                NotificationCenter.default.post(name: .synaptyNewSession, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab") {
                TerminalCoordinatorRef.instance?.requestNewTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Divider()

            Button("Split Right") {
                TerminalCoordinatorRef.instance?.requestSplit(direction: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split Down") {
                TerminalCoordinatorRef.instance?.requestSplit(direction: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Close Split") {
                TerminalCoordinatorRef.instance?.requestCloseSplit()
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        // Navigate menu
        CommandMenu("Navigate") {
            Button("Next Split") {
                TerminalCoordinatorRef.instance?.requestFocusNextSplit()
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("Previous Split") {
                TerminalCoordinatorRef.instance?.requestFocusPreviousSplit()
            }
            .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button("Next Tab") {
                TerminalCoordinatorRef.instance?.requestNextTab()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Tab") {
                TerminalCoordinatorRef.instance?.requestPreviousTab()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            ForEach(1..<10, id: \.self) { num in
                Button("Session \(num)") {
                    TerminalCoordinatorRef.instance?.requestSwitchSession(index: num)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(num)")), modifiers: .command)
            }
        }

        // Replace default "Synapty Help" with our own help items
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                NotificationCenter.default.post(name: .synaptyShowShortcuts, object: nil)
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }

        // View menu — terminal text size and search. Key equivalents are
        // also handled directly in TerminalSurface when the terminal has
        // focus; these menu items cover the unfocused case.
        CommandMenu("View") {
            Button("Increase Font Size") {
                NotificationCenter.default.post(name: .synaptyFontIncrease, object: nil)
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Decrease Font Size") {
                NotificationCenter.default.post(name: .synaptyFontDecrease, object: nil)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Font Size") {
                NotificationCenter.default.post(name: .synaptyFontReset, object: nil)
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Find") {
                NotificationCenter.default.post(name: .synaptyFind, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button("Toggle Settings Panel") {
                NotificationCenter.default.post(name: .synaptyToggleSettingsPanel, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}

// MARK: - Notification names for menu → ContentView communication

extension Notification.Name {
    static let synaptyNewSession = Notification.Name("synaptyNewSession")
    static let synaptyShowShortcuts = Notification.Name("synaptyShowShortcuts")
    static let synaptyFontIncrease = Notification.Name("synaptyFontIncrease")
    static let synaptyFontDecrease = Notification.Name("synaptyFontDecrease")
    static let synaptyFontReset = Notification.Name("synaptyFontReset")
    static let synaptyFind = Notification.Name("synaptyFind")
    static let synaptyTunnelFailed = Notification.Name("synaptyTunnelFailed")
    static let synaptySettingsChanged = Notification.Name("synaptySettingsChanged")
    static let synaptyAppearanceChanged = Notification.Name("synaptyAppearanceChanged")
    static let synaptyReloadRequested = Notification.Name("synaptyReloadRequested")
    static let synaptyToggleSettingsPanel = Notification.Name("synaptyToggleSettingsPanel")
}
