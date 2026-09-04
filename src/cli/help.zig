const std = @import("std");
const clap = @import("clap");
const mem = std.mem;
const io_mod = @import("io");
const types = @import("types.zig");

/// WHAT THE CLI SAYS ABOUT ITSELF, printed from the table it parses with
/// ([[types]]`.subcommands`).
///
/// IT USED TO SAY ONE THING TO EVERYONE. Every `--help`, at every depth,
/// raised the same `ParseError.HelpRequested`, and the one handler for it
/// printed the top-level usage — so `synapty send --help` answered with a
/// list of subcommands and the advice "try 'synapty <subcommand> --help'",
/// which is what the caller had just done ([[WI-2026-08-28-023]]).

/// `synapty --help`, and the usage line for a missing subcommand.
///
/// GROUPED BY WHO TYPES IT. Twenty-nine names in a row tell a human
/// nothing about which of them are theirs, and the CLI serves four kinds
/// of caller at once ([[ADR-0004]]: one binary).
pub fn printOverview(comptime full: bool) !void {
    try io_mod.stdoutWriteAll("usage: synapty <subcommand> [args]\n");
    if (!full) {
        try io_mod.stdoutWriteAll("try 'synapty --help' for the list of subcommands\n");
        return;
    }
    inline for (comptime std.enums.values(types.Group)) |group| {
        try io_mod.stdoutWriteAll("\n" ++ comptime group.heading() ++ "\n");
        inline for (types.subcommands) |sc| {
            if (sc.group == group) {
                try io_mod.stdoutWriteAll(comptime pad(sc.name) ++ sc.summary ++ "\n");
            }
        }
    }
    try io_mod.stdoutWriteAll("\ntry 'synapty <subcommand> --help' for a subcommand's options\n");
}

/// One subcommand's own help: what it is for, and — where zig-clap does
/// the parsing — the flags, printed from the very text they parse from.
pub fn printSubcommand(name: []const u8) !void {
    inline for (types.subcommands) |sc| {
        if (mem.eql(u8, sc.name, name)) {
            try io_mod.stdoutWriteAll("synapty " ++ sc.name ++ " — " ++ sc.summary ++ "\n\n");
            try io_mod.stdoutWriteAll(
                "usage: synapty " ++ sc.name
                    ++ (if (sc.usage.len > 0) " " ++ sc.usage else "")
                    ++ (if (comptime hasFlags(sc.params)) " [options]" else "") ++ "\n");
            if (comptime hasFlags(sc.params)) {
                try io_mod.stdoutWriteAll("\n");
                var buf: [4096]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buf);
                try clap.help(&writer, clap.Help, comptime flagsOf(sc.params), .{});
                try io_mod.stdoutWriteAll(writer.buffered());
            }
            if (sc.notes.len > 0) try io_mod.stdoutWriteAll("\n" ++ sc.notes);
            return;
        }
    }
    try printOverview(true);
}

/// THE NAMED FLAGS ONLY. zig-clap's positional parameters carry no name,
/// so `clap.help` renders each as a blank row — `synapty send --help`
/// printed two of them. What a positional IS lives in the table's `usage`
/// field, which is the only place it can.
fn flagsOf(comptime source: []const u8) []const clap.Param(clap.Help) {
    const all = comptime clap.parseParamsComptime(source);
    comptime {
        var out: [all.len]clap.Param(clap.Help) = undefined;
        var n: usize = 0;
        for (all) |param| {
            if (param.names.short != null or param.names.long != null) {
                out[n] = param;
                n += 1;
            }
        }
        const fixed = out[0..n].*;
        return &fixed;
    }
}

fn hasFlags(comptime source: []const u8) bool {
    return source.len > 0 and flagsOf(source).len > 0;
}

/// Two columns, so the summaries line up without anyone counting spaces.
fn pad(comptime name: []const u8) []const u8 {
    const width = 14;
    comptime var out: []const u8 = "  " ++ name;
    comptime {
        while (out.len < width) out = out ++ " ";
    }
    return out;
}
