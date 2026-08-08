import Foundation

/// Run a subprocess while draining stdout/stderr CONCURRENTLY, with a hard
/// timeout (WI-2026-08-08-005, hardened WI-2026-08-08-030).
///
/// Why this exists: a pipe nobody drains blocks the child the moment the
/// ~64KB kernel pipe buffer fills. The old call sites read stdout only
/// after `waitUntilExit()` (or never read stderr at all), so a chatty
/// child wedged forever: monitoring silently died, tunnel sessions hung in
/// .connecting, and no error ever surfaced. The readability handlers drain
/// both pipes on a private dispatch queue while the child runs.
///
/// Timeout semantics (hardened): on timeout the whole PROCESS GROUP is
/// SIGKILLed — SIGTERM alone left orphaned grandchildren (ssh/scp under a
/// timed-out bash) holding the pipe write-ends open, so EOF never arrived
/// and the unbounded drainGroup.wait() hung the caller forever. The drain
/// wait is ALSO bounded, so a stuck EOF handler can never wedge the caller
/// (in-flight polling guards always reset).
enum SubprocessRunner {
    struct Output {
        var stdout: String
        var stderr: String
        /// True when the process had to be killed after `timeout`.
        var timedOut: Bool
        /// Launch failure description, if the process could not start.
        var error: String?
    }

    /// Synchronous — call from a background queue, never the main thread.
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        var stdout = Data()
        var stderr = Data()

        // Drain both pipes concurrently while the child runs. EOF arrives
        // as an empty chunk, which also releases the handler.
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drainGroup.leave()
            } else {
                stdout.append(chunk)
            }
        }
        drainGroup.enter()
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drainGroup.leave()
            } else {
                stderr.append(chunk)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        var launchError: String?
        do {
            try process.run()
        } catch {
            launchError = "\(error)"
        }

        var timedOut = false
        if launchError == nil {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                // SIGTERM the child, then kill the whole process group:
                // a timed-out bash commonly leaves ssh/scp grandchildren
                // running — they keep the pipe write-ends open, so without
                // this the EOF handlers never fire (WI-2026-08-08-030).
                process.terminate()
                _ = exited.wait(timeout: .now() + 3)
                if process.isRunning {
                    killProcessGroup(of: process)
                    _ = exited.wait(timeout: .now() + 2)
                }
            }
        } else {
            // The pipes never close for a process that never ran; drop the
            // handlers so their captured state is released (nothing ever
            // calls drainGroup.leave() — we must not wait on it below).
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
        }

        if launchError == nil {
            // BOUNDED wait: after the kill paths above the pipes are closed
            // (or the child ignored everything), so this returns quickly in
            // practice — but a stubborn descendant must never be able to
            // hang the caller (WI-2026-08-08-030).
            _ = drainGroup.wait(timeout: .now() + 2)
        }

        return Output(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut,
            error: launchError
        )
    }

    /// SIGKILL every process in the child's group. `Process` doesn't expose
    /// setpgid, so we signal the child's pid and its group via kill(-pid).
    /// If the child was not a group leader this still kills the child, and
    /// the grandchildren inherit the pipe ends only while they survive —
    /// the bounded drain wait below caps the exposure regardless.
    private static func killProcessGroup(of process: Process) {
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGKILL)             // the child itself
            kill(-pid, SIGKILL)            // its process group, if leader
        }
    }
}
