import Foundation

/// Run a subprocess while draining stdout/stderr CONCURRENTLY, with a hard
/// timeout (WI-2026-08-08-005).
///
/// Why this exists: a pipe nobody drains blocks the child the moment the
/// ~64KB kernel pipe buffer fills. The old call sites read stdout only
/// after `waitUntilExit()` (or never read stderr at all), so a chatty
/// child wedged forever: monitoring silently died, tunnel sessions hung in
/// .connecting, and no error ever surfaced. The readability handlers drain
/// both pipes on a private dispatch queue while the child runs, and the
/// timeout guarantees a stuck child cannot hang the caller.
enum SubprocessRunner {
    struct Output {
        var stdout: String
        var stderr: String
        /// True when the process had to be SIGTERMed after `timeout`.
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
                process.terminate()
                _ = exited.wait(timeout: .now() + 5)
            }
        } else {
            // The pipes never close for a process that never ran; drop the
            // handlers so their captured state is released (nothing ever
            // calls drainGroup.leave() — we must not wait on it below).
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
        }

        if launchError == nil {
            // EOF handlers have run by the time the child exited.
            drainGroup.wait()
        }

        return Output(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            timedOut: timedOut,
            error: launchError
        )
    }
}
