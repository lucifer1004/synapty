import Darwin
import Foundation

/// Where a process on THIS Mac is standing.
///
/// OSC 7 IS THE SHELL VOLUNTEERING, and most shells do not. A plain login
/// emits nothing, so every consumer of a terminal's working directory —
/// what a drop delivers into, what a restored session reopens at, what an
/// agent is told its cwd is — had one answer for a configured shell and a
/// shrug for everyone else. "Working directory unknown" was accurate and
/// useless.
///
/// The kernel already knows. `proc_pidinfo(PROC_PIDVNODEPATHINFO)` reads
/// the process's own current directory, so a shell that never says a word
/// still gives a true answer, and one that `cd`s without a prompt hook
/// gives an up-to-date one.
///
/// THIS MAC ONLY, and the limit is real rather than an oversight: a pane
/// running `ssh` has a foreground process whose cwd is the ssh client's,
/// which is on the wrong machine. Nothing here can answer for a remote
/// shell — that needs the remote side to speak, which is what the holder
/// is asked for ([[RemotePwd]]).
enum ProcessCwd {

    /// The process's current directory, or nil if it cannot be read —
    /// which includes a process that has exited between being named and
    /// being asked, so a nil is ordinary rather than exceptional.
    static func of(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        // A short read is a failure, not a partial answer: the path would
        // be whatever the uninitialised tail of the struct holds.
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// WHERE THE SHELL IS, asked of the shell and not of what it happens
    /// to be running ([[WI-2026-08-18-004]]).
    ///
    /// A terminal's foreground process is whatever the human last typed —
    /// and a command that `cd`s takes the directory with it. `jenv rehash`
    /// runs from every `.zshrc` on this machine and spends its life in
    /// `~/.jenv/shims`; asked during a shell's own startup, the kernel
    /// answered with the shim directory, confidently, and a pane
    /// duplicated from that answer opened there.
    ///
    /// Falls back to the foreground process, because an answer from the
    /// wrong process still beats none for the readers that were living on
    /// it before this existed.
    static func ofShell(foregroundPID pid: pid_t) -> String? {
        of(pid: shell(from: pid) ?? pid)
    }

    /// The pane's own shell at or above `pid`, or nil when the chain does
    /// not look like one of ours.
    ///
    /// FOUND BY ITS PARENT, WHICH IS OUR OWN WRAPPER. A pane's chain is
    /// `login` -> `synapty run` -> `$SHELL` -> whatever the human typed,
    /// so the shell is the process the wrapper spawned, and nothing about
    /// it has to be guessed.
    ///
    /// TWO RULES WERE TRIED AND BOTH WERE WRONG, and they are recorded
    /// because each looked obviously right. Job control — "the top job of
    /// the session" — is true of a shell under `login` and false of one
    /// under `script`, where the shell is itself the session leader. And
    /// the process's NAME does not separate an interactive shell from a
    /// shell script it is running: `jenv-rehash` is `#!/usr/bin/env bash`,
    /// so the very case this exists for stops on a process called `bash`,
    /// standing in the shim directory. Sampling a real pane's startup
    /// killed the remaining idea, that the script would at least not be a
    /// process-group leader: it is one in the second half of `.zshrc` and
    /// not in the first.
    ///
    /// None of those are facts about our panes. This one is: we spawn the
    /// shell, so we can find it by what spawned it.
    static func shell(from pid: pid_t) -> pid_t? {
        shell(from: pid, parent: parent(of:), name: name(of:))
    }

    /// The rule itself, over any process table. A test supplies a chain;
    /// the live one supplies the kernel's.
    static func shell(from pid: pid_t,
                      parent: (pid_t) -> pid_t?,
                      name: (pid_t) -> String?) -> pid_t? {
        guard pid > 0 else { return nil }
        var cursor = pid
        // A chain, not a search — four deep — and the bound is here so a
        // corrupt parent link cannot spin.
        for _ in 0..<16 {
            guard let ppid = parent(cursor), ppid > 1, ppid != cursor else { break }
            if name(ppid) == Self.wrapperName { return cursor }
            cursor = ppid
        }
        return nil
    }

    /// `proc_name` reports the executable's own name, which for the pane
    /// wrapper is the bundled helper: Contents/Helpers/synapty.
    static let wrapperName = "synapty"

    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    static func parent(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
