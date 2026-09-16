import XCTest

/// WHAT A UI TEST IS FOR HERE.
///
/// The unit suite proves what the model DOES. It cannot see whether a
/// surface is on screen, whether a menu item is reachable, or whether one
/// keystroke produced one effect — and every one of those failed in the
/// product while the model tests stayed green:
///
/// - the reference sheet was complete, correct, read from the table, and
///   instantiated NOWHERE, so `⇧⌘/` set a flag nobody read;
/// - `⌘K` ran its command twice, because consuming an event in a monitor
///   does not stop a menu's key equivalent, and the palette opened and
///   shut in one press.
///
/// Both are one assertion each below. That is the standard for adding to
/// this suite: a defect that reached the human, written down so it cannot
/// come back quietly.
///
/// ON A CONFIG ROOT OF ITS OWN, always. These tests press keys that create
/// and destroy panes, and the human's real `~/.config/synapty` is not a
/// fixture ([[WI-2026-08-18-004]] — dev launches once grew their workspace
/// from a couple of panes to twelve).
class UITestCase: XCTestCase {

    var app: XCUIApplication!
    private var configRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // THE TERMINAL DOES NOT START IN THIS HARNESS, and the reason is
        // measured rather than suspected. A session socket lives under
        // this root; the kernel bounds a unix socket path at 104 bytes on
        // macOS; and the test runner is CONTAINERISED, so its temporary
        // directory is
        // `…/Library/Containers/com.synapty.uitests.xctrunner/Data/tmp`
        // — 63 bytes before anything of ours, and 112 by the time
        // `/machine/sessions/<id>.sock` is on the end. The runner cannot
        // escape to a shorter base either: writing to /tmp from here is
        // `Operation not permitted`.
        //
        // SO THE SUITE HAS BEEN GREEN ABOUT A DEAD TERMINAL. Nothing here
        // asserts on terminal CONTENT — the file, services and browser
        // panes are what these tests read — so the failure was invisible
        // until a screenshot showed a Zig stack trace in the pane. It is
        // recorded rather than papered over: the repair is on the Synapty
        // side, where the socket path is derived from an arbitrarily deep
        // root, and it is a design decision about where a durable
        // artifact lives.
        //
        // The tag is short anyway, because a shorter root costs nothing.
        let tag = String(UUID().uuidString.prefix(8)).lowercased()
        configRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("syn-ui-\(tag)")
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["SYNAPTY_CONFIG_ROOT"] = configRoot.path
        // A HUB PORT OF ITS OWN PER TEST. Every instance otherwise wants
        // :9000, so a launch that overlaps the previous test's app — one
        // that is terminating, or whose hub child outlived it — spends its
        // startup waiting for a port it will not get. That is the shape of
        // the failure this suite showed: the first test green, the ones
        // after it hanging for a minute, and each of them green again when
        // run alone.
        //
        // ALSO KEEPS THE OPERATOR'S OWN APP OUT OF IT: a running Synapty
        // on :9000 is exactly the collision the tests would otherwise pick
        // a fight with.
        app.launchEnvironment["SYNAPTY_HUB_PORT"] = String(Self.uniquePort())
        // Scrubbed for the same reason every dev relaunch is: `open`
        // hands the caller's environment to the app and the app hands it
        // to every pane shell.
        for key in ProcessInfo.processInfo.environment.keys
        where key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") {
            app.launchEnvironment[key] = ""
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
        // TERMINATED IS NOT GONE. The app's hub is a child process that
        // outlives a terminate, and the next test's instance would find
        // the port still held — the leak this project has been bitten by
        // before ([[project-gui-visual-iteration]]: orphaned hubs holding
        // :9000 masked an app-start race for a whole day).
        if let port = app?.launchEnvironment["SYNAPTY_HUB_PORT"] {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", "synapty-cli hub.*\(port)"]
            try? kill.run()
            kill.waitUntilExit()
        }
        if let configRoot { try? FileManager.default.removeItem(at: configRoot) }
    }

    /// A port nobody else in this run is using. Derived from the process
    /// and a counter rather than random, so a failure names a port that
    /// can be looked for in a log.
    private static var portCounter = 0
    private static func uniquePort() -> Int {
        portCounter += 1
        return 19_000 + (Int(ProcessInfo.processInfo.processIdentifier) % 500) * 20 + portCounter
    }

    /// Launch and wait for the window, so a test never races the first
    /// frame.
    func launch(_ arguments: [String] = []) {
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20),
                      "the window never appeared")
    }

    /// PHOTOGRAPH THE STEP. Attached to the result bundle, which is how a
    /// failure two weeks from now can be looked at rather than reasoned
    /// about — and how a human reviewing this suite can see what it saw.
    ///
    /// THE SCREEN AND NOT THE WINDOW ELEMENT. An element screenshot needs
    /// an accessibility snapshot, which waits for the application to go
    /// idle — and a focused text field never does, because its caret
    /// blinks on a timer. Photographing a window with a text field in it
    /// hung for thirty seconds and then failed the test around it, which
    /// cost an hour of blaming the product for the camera.
    func photograph(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
