//! The pty holder: a terminal that outlives the client attached to it.
//!
//! [[RFC-0014]] in one file. The holder owns a pseudoterminal, spawns the
//! child on it, and serves at most one attached client over a local
//! socket. Clients come and go; the child does not notice.
//!
//! WHAT IS HERE, slice by slice since [[WI-2026-08-17-003]] laid the
//! first one: RETENTION — the child's output is kept in a bounded ring
//! (`Retained`) and the stream is positioned, so RESUMPTION is a client
//! naming where it stopped reading and receiving what it missed, or being
//! told plainly that it is gone; RESTORATION — a screen model (the same
//! emulator the workbench renders with) paints the current screen for a
//! client that has no position to resume from; ENUMERATION — every
//! session leaves a `Record` beside its socket, which is what `synapty
//! sessions` lists and the attach chooser shows; and THE END POLICY — a
//! session ends when its child exits or when someone asks (`requestEnd`),
//! and never by a timer (`never_reaped`). Each is described where it
//! lives; this header only says which questions the file answers.

const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const paths = @import("paths");
const log = @import("diag").scoped(.holder);

/// The same emulator the workbench renders with ([[ADR-0012]]). A second
/// implementation would mean the far side's idea of the screen and the
/// near side's rendering of it could disagree, and the disagreement would
/// surface only after a reattach — the least observable moment there is.
const vt = @cImport({
    @cInclude("ghostty/vt.h");
});

/// The wire.
///
/// FRAMED, NOT INTERLEAVED. Terminal output is arbitrary bytes, including
/// every byte a delimiter could be made of, so the stream carries length
/// prefixes rather than markers. Five bytes of header per frame is the
/// price of never having to escape the payload.
pub const Frame = enum(u8) {
    /// holder -> client: bytes the child wrote.
    data = 1,
    /// client -> holder: bytes the human typed.
    input = 2,
    /// client -> holder: two u16s, rows then columns.
    resize = 3,
    /// holder -> client: the child is gone. One byte of kind (0 exit, 1
    /// signal) and one of value.
    exit = 4,
    /// holder -> client: another client has taken the session.
    displaced = 5,
    /// client -> holder: version, then rows and columns.
    hello = 6,
    /// holder -> client: version.
    welcome = 7,
    /// client -> holder: what are you doing? A connection that opens with
    /// this is never made the attached client.
    status_request = 8,
    /// holder -> client: attached (0/1), child_exited (0/1).
    status = 9,
    /// client -> holder: end the session and the child with it.
    end_request = 10,
    /// holder -> client: the screen as it stands, for a client that holds
    /// nothing ([[RFC-0014]] C-RESTORE). One byte of which screen, then
    /// rows and columns, then the cursor's row, column and visibility,
    /// then a full-screen repaint — every row positioned and painted,
    /// ending with the cursor ([[WI-2026-08-17-013]]).
    restore = 12,
    /// holder -> client: the catch-up fell behind the child and the
    /// stream has a hole in it. Payload: the offset live output resumes
    /// at. Said rather than left silent ([[RFC-0014]] C-RESUME).
    gap = 11,
    /// holder -> client: we do not speak the same protocol. Payload: the
    /// version THIS holder speaks, then the version the client announced.
    ///
    /// A FRAME RATHER THAN A HANGUP ([[RFC-0014]] C-VERSION: "MUST
    /// surface the refusal as a version mismatch naming both versions").
    /// The holder used to close the socket, so a human met an unexplained
    /// disconnection and had nothing to act on ([[WI-2026-08-28-024]]).
    version_mismatch = 13,
    /// client -> holder: call this session by this name ([[RFC-0014]]
    /// C-SESSION-NAME). Payload: the name, UTF-8. Answered with a status
    /// frame; a connection that opens with this is never made the
    /// attached client. A holder built before this frame existed closes
    /// the connection, which the client reads as "keeps no names".
    set_name = 14,
    _,
};

/// The protocol this build speaks.
///
/// [[RFC-0014]] C-VERSION: it MUST change when the protocol changes in a
/// way that would make one side misread the other, and MUST NOT change
/// otherwise — a holder rendered unreachable by a build stamp is a fault,
/// not a compatibility measure. A holder outlives the deploy that
/// replaced its binary, so the client is routinely the older side.
pub const protocol_version: u8 = 1;

/// WHAT A HOLDER ANSWERED A HELLO WITH.
pub const Welcome = struct {
    answer: ResumeAnswer,
    incarnation: u64,
    position: u64,
    retention: u64,
};

/// READING THE WELCOME AND CHECKING THE VERSION ARE ONE ACT.
///
/// Every client went through its own copy of "read a frame, check it is a
/// welcome, take payload[1] onward" and not one of them looked at
/// payload[0] — the version the holder announced. So a holder NEWER than
/// the client was read best-effort, which [[RFC-0014]] C-VERSION forbids
/// by name, and the case is routine: a holder outlives the deploy that
/// replaced its binary, so the client is the older side whenever a second
/// machine has deployed and this one has not ([[WI-2026-08-28-024]]).
///
/// A client cannot now take the welcome without the check, because there
/// is one way to take it.
///
/// `theirs` is written on `error.VersionMismatch` so the caller can name
/// both versions, which the clause requires and an error cannot carry.
pub fn readWelcome(fd: sys.fd_t, buf: []u8, theirs: *u8) !Welcome {
    const frame = (try readFrame(fd, buf)) orelse return error.Closed;
    if (frame.kind == .version_mismatch) {
        // The holder refused us and said what it speaks.
        theirs.* = if (frame.payload.len > 0) frame.payload[0] else 0;
        return error.VersionMismatch;
    }
    if (frame.kind != .welcome or frame.payload.len < 26) return error.Closed;
    if (frame.payload[0] != protocol_version) {
        theirs.* = frame.payload[0];
        return error.VersionMismatch;
    }
    return .{
        .answer = @enumFromInt(frame.payload[1]),
        .incarnation = std.mem.readInt(u64, frame.payload[2..10], .little),
        .position = std.mem.readInt(u64, frame.payload[10..18], .little),
        .retention = std.mem.readInt(u64, frame.payload[18..26], .little),
    };
}

/// What the child is told it is talking to ([[RFC-0014]] C-TERMINAL-TYPE).
///
/// THE HOLDER MUST BE ABLE TO INTERPRET WHAT IT ADVERTISES. Its screen
/// model is ghostty's emulator, which implements this and more; naming
/// the widely-installed subset rather than `xterm-ghostty` means a host
/// with no ghostty terminfo entry still gets a child that knows it has
/// colours — and the difference the child would notice is capability it
/// mostly cannot use over this path anyway.
///
/// IT IS SET RATHER THAN INHERITED because there is nothing to inherit:
/// the transport carries frames, not a terminal, so nothing upstream has
/// a TERM to pass down. Before this, a remote shell came up with none at
/// all and turned its own syntax highlighting off.
pub const default_term = "xterm-256color";

/// What the holder did with the position a client presented.
pub const ResumeAnswer = enum(u8) {
    /// No position was presented; this client starts from now.
    fresh = 0,
    /// Everything after the position follows, before any newer output.
    resumed = 1,
    /// The position cannot be honoured — a foreign incarnation, or one
    /// older than what is retained. The client starts from now, KNOWING
    /// that it does.
    unavailable = 2,
};

/// [[RFC-0014]] C-RETENTION's floor. A holder is free to keep more; one
/// that keeps less satisfies "bounded" while making resumption fail in
/// every case a human would notice.
pub const min_retention_bytes: usize = 1 << 20;

pub const header_len = 5;

pub fn writeFrame(fd: sys.fd_t, kind: Frame, payload: []const u8) !void {
    var hdr: [header_len]u8 = undefined;
    hdr[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
    try sys.writeAll(fd, &hdr);
    if (payload.len > 0) try sys.writeAll(fd, payload);
}


/// Read one frame into `buf`. Blocks. Returns null at end of stream.
pub fn readFrame(fd: sys.fd_t, buf: []u8) !?struct { kind: Frame, payload: []const u8 } {
    var hdr: [header_len]u8 = undefined;
    if (!try readExactly(fd, &hdr)) return null;
    const len = std.mem.readInt(u32, hdr[1..5], .little);
    if (len > buf.len) return error.TooLarge;
    if (len > 0 and !try readExactly(fd, buf[0..len])) return null;
    return .{ .kind = @enumFromInt(hdr[0]), .payload = buf[0..len] };
}

/// A frame that may have needed the heap, and the means to give it back.
pub const HeldFrame = struct {
    kind: Frame,
    payload: []const u8,
    owned: ?[]u8,

    pub fn deinit(self: HeldFrame, allocator: std.mem.Allocator) void {
        if (self.owned) |o| allocator.free(o);
    }
};

/// The ceiling a frame may not cross. Far above any screen a human sits
/// in front of; here so that a length read off a damaged stream allocates
/// nothing rather than everything.
pub const max_frame_bytes: usize = 16 << 20;

/// Read one frame, using `buf` when it fits and the heap when it does not.
///
/// A RESTORATION IS AS BIG AS THE SCREEN IS. Every other frame is small
/// and bounded — a keystroke, a resize, a chunk of output the pump chose
/// the size of — but a repaint carries a palette and every row of a pane
/// whose size the client chose, which on a large pane is past any buffer
/// a caller would put on its stack. A client that read into a fixed one
/// answered `TooLarge` and hung up, so the bigger the human's window the
/// more certainly the reattach failed.
pub fn readFrameAlloc(
    allocator: std.mem.Allocator,
    fd: sys.fd_t,
    buf: []u8,
) !?HeldFrame {
    var hdr: [header_len]u8 = undefined;
    if (!try readExactly(fd, &hdr)) return null;
    const kind: Frame = @enumFromInt(hdr[0]);
    const len = std.mem.readInt(u32, hdr[1..5], .little);
    if (len > max_frame_bytes) return error.TooLarge;
    if (len == 0) return .{ .kind = kind, .payload = buf[0..0], .owned = null };
    if (len <= buf.len) {
        if (!try readExactly(fd, buf[0..len])) return null;
        return .{ .kind = kind, .payload = buf[0..len], .owned = null };
    }

    const owned = try allocator.alloc(u8, len);
    errdefer allocator.free(owned);
    if (!try readExactly(fd, owned)) {
        allocator.free(owned);
        return null;
    }
    return .{ .kind = kind, .payload = owned, .owned = owned };
}

/// Fill `buf` completely. False means the peer is gone; an error means
/// the read failed for a reason that is not the end of the stream.
///
/// THE DIFFERENCE IS THE WHOLE FUNCTION. Collapsing a timeout into "the
/// connection closed" is what a first draft did, and it made a client
/// that was merely waiting look exactly like one that had hung up —
/// which a caller answers by giving up on a session that is fine.
///
/// A failure that arrives PART WAY THROUGH a frame is worse than either:
/// the stream is now mid-header with no way to resynchronise, so it is
/// reported as such rather than retried into garbage.
fn readExactly(fd: sys.fd_t, buf: []u8) !bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = sys.read(fd, buf[got..]) catch |err| {
            if (got > 0) return error.PartialFrame;
            return err;
        };
        if (n == 0) {
            if (got > 0) return error.PartialFrame;
            return false;
        }
        got += n;
    }
    return true;
}

/// The screen, as the far side understands it.
///
/// WHAT THIS IS FOR, and only this: answering a client that arrives
/// holding nothing, so a cold reattach is a restoration rather than a
/// guess. It is not published to agents and does not move pane
/// classification off the workbench — both are capabilities this makes
/// POSSIBLE and neither is authorised ([[RFC-0014]] C-NON-GOALS).
pub const Screen = struct {
    term: vt.GhosttyTerminal,

    pub fn init(rows: u16, cols: u16) !Screen {
        var term: vt.GhosttyTerminal = undefined;
        if (vt.ghostty_terminal_new(null, &term, cols, rows) != vt.GHOSTTY_SUCCESS) {
            return error.ScreenUnavailable;
        }
        return .{ .term = term };
    }

    pub fn deinit(self: *Screen) void {
        vt.ghostty_terminal_free(self.term);
    }

    pub fn write(self: *Screen, bytes: []const u8) void {
        vt.ghostty_terminal_vt_write(self.term, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Screen, rows: u16, cols: u16) void {
        // Cell pixel dimensions matter only to image protocols and size
        // reports; a holder that renders nothing has no pixels to speak
        // of, and reporting a plausible cell size is more honest than
        // reporting zero.
        _ = vt.ghostty_terminal_resize(self.term, cols, rows, 8, 16);
    }

    /// Where the cursor is, and whether it can be seen.
    ///
    /// CARRIED EXPLICITLY rather than left to the dump. A screen written
    /// as sequences ends wherever its last cell was, which on a mostly
    /// empty screen is the right-hand edge — a prompt on the first line
    /// and a cursor two hundred columns away from it, which is what a
    /// real reconnection looked like. [[RFC-0014]] C-RESTORE asks for the
    /// cursor by name for this reason.
    pub const Cursor = struct { x: u16, y: u16, visible: bool };

    pub fn cursor(self: *Screen) Cursor {
        // uint16_t, as the header says. A wider read here would take the
        // next field's bytes with it.
        var x: u16 = 0;
        var y: u16 = 0;
        var visible: bool = true;
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y);
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible);
        return .{ .x = x, .y = y, .visible = visible };
    }

    pub fn activeScreen(self: *Screen) u8 {
        var which: vt.GhosttyTerminalScreen = vt.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &which);
        return if (which == vt.GHOSTTY_TERMINAL_SCREEN_ALTERNATE) 1 else 0;
    }

    pub fn size(self: *Screen) struct { rows: u16, cols: u16 } {
        var rows: u16 = 0;
        var cols: u16 = 0;
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
        _ = vt.ghostty_terminal_get(self.term, vt.GHOSTTY_TERMINAL_DATA_COLS, &cols);
        return .{ .rows = rows, .cols = cols };
    }

    /// The screen as a full-screen repaint: every row placed where the
    /// session has it.
    ///
    /// A DESCRIPTION OF THE CONTENT IS NOT A RESTORATION. The formatter
    /// emits the screen's content — the rows between the first and last
    /// that have something on them — so where any row lands depends on
    /// where the paint began. That is what put a session's work at the
    /// bottom of a taller pane and split a two-character command across a
    /// wrap that no longer existed ([[WI-2026-08-17-013]]). A multiplexer
    /// does not describe, it paints: position, row, position, row, for
    /// every row of the screen including the blank ones. So does this.
    ///
    /// THE ORDER OF THE THREE PARTS IS THE WHOLE DESIGN. State the paint
    /// depends on goes first — the palette, so the colours are right from
    /// the first cell, and the modes, which is where the alternate screen
    /// lives and which therefore must be entered before anything is
    /// painted into it. The rows follow. State that would disturb the
    /// paint goes last: a scrolling region and tabstops are set after the
    /// cells they would otherwise clip or move, and the cursor is last of
    /// all because everything before it moves it.
    ///
    /// WHAT A REPAINT CANNOT CARRY, said plainly: a row painted at its
    /// own position is not marked as soft-wrapped, so a reflow after the
    /// reattach breaks a wrapped line where this paint ended it. The
    /// multiplexer this replaces has the same limit, and the alternative
    /// — letting the text wrap by writing it without positioning — is the
    /// defect this work exists to close.
    pub fn repaint(self: *Screen, allocator: std.mem.Allocator) ![]u8 {
        const dim = self.size();
        if (dim.rows == 0 or dim.cols == 0) return error.ScreenUnavailable;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "\x1b[H");
        try self.appendState(allocator, &out, .before);

        // ABSOLUTE ADDRESSING, WHATEVER THE PANE WAS LEFT IN. Two things
        // can move a CUP off the screen's own coordinates, and each one
        // covers an axis the other does not: a scrolling region, which
        // the pane may still be carrying from the connection that died
        // and which nothing else here would clear if this session has
        // none; and origin mode, which the modes just emitted may have
        // turned on and which measures a column from the left margin as
        // well as a row from the top one. Both are re-established after
        // the paint, from what the session actually has.
        try out.appendSlice(allocator, "\x1b[r\x1b[?6l");

        var y: u16 = 0;
        while (y < dim.rows) : (y += 1) {
            var buf: [32]u8 = undefined;
            // Position, then clear the row with a default background —
            // BLANK ROWS ARE PAINTED TOO, or a restoration would leave
            // whatever the pane had there before.
            try out.appendSlice(allocator, std.fmt.bufPrint(
                &buf,
                "\x1b[{d};1H\x1b[m\x1b[K",
                .{y + 1},
            ) catch return error.ScreenUnavailable);
            try self.appendRow(allocator, &out, y, dim.cols);
        }

        try out.appendSlice(allocator, "\x1b[H");
        try self.appendState(allocator, &out, .after);
        const origin = self.mode(origin_mode);
        if (origin) try out.appendSlice(allocator, "\x1b[?6h");

        // THE CURSOR IS PLACED BY THE PAINT, not by the client that
        // receives it, because only the paint knows what it did to the
        // addressing modes on the way through, and it is placed last
        // because everything above it moves the cursor.
        //
        // AND UNDER ORIGIN MODE IT IS MEASURED FROM THE REGION
        // ([[WI-2026-08-17-014]]). Re-entering origin mode homes the
        // cursor, so this CUP has to come after it, and a CUP after it is
        // read against the scrolling region rather than the screen — which
        // put a restored cursor four rows low on a session with a region
        // starting at row five. So the position is converted, using a
        // region the library will not answer for but will WRITE: asked to
        // emit only the scrolling region, it produces the DECSTBM and
        // DECSLRM that state it.
        const cur = self.cursor();
        var row = cur.y;
        var col = cur.x;
        if (origin) {
            const region = self.scrollRegion(allocator);
            row -|= region.top;
            col -|= region.left;
        }
        var cbuf: [40]u8 = undefined;
        try out.appendSlice(allocator, std.fmt.bufPrint(
            &cbuf,
            "\x1b[{d};{d}H",
            .{ row + 1, col + 1 },
        ) catch return error.ScreenUnavailable);
        try out.appendSlice(allocator, if (cur.visible) "\x1b[?25h" else "\x1b[?25l");

        return out.toOwnedSlice(allocator);
    }

    /// DEC private mode 6, packed as the library packs modes: the value in
    /// the low fifteen bits, the ANSI flag in the top one.
    const origin_mode: vt.GhosttyMode = 6;

    fn mode(self: *Screen, which: vt.GhosttyMode) bool {
        var value: bool = false;
        if (vt.ghostty_terminal_mode_get(self.term, which, &value) != vt.GHOSTTY_SUCCESS) return false;
        return value;
    }

    /// State that is not cell content, emitted either side of the paint.
    ///
    /// EVERY EXTRA IS ASKED FOR EXPLICITLY, because an attribute left out
    /// is a difference the human sees and cannot explain — so the set is
    /// the minimum [[RFC-0014]] C-RESTORE names, written out rather than
    /// inherited from whatever the library happens to default to.
    ///
    /// THE ONE CELL IS NOT A MISTAKE. The formatter has no way to be
    /// asked for state without content, so it is asked for the smallest
    /// content there is — the cell at the origin — and the caller has
    /// homed the cursor first, which is precisely where that cell
    /// belongs. It is painted again by row zero a moment later.
    fn appendState(
        self: *Screen,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        when: enum { before, after },
    ) !void {
        var opts = std.mem.zeroes(vt.GhosttyFormatterTerminalOptions);
        opts.size = @sizeOf(vt.GhosttyFormatterTerminalOptions);
        opts.emit = vt.GHOSTTY_FORMATTER_FORMAT_VT;
        opts.unwrap = false;
        opts.trim = false;
        opts.extra.size = @sizeOf(vt.GhosttyFormatterTerminalExtra);
        opts.extra.screen.size = @sizeOf(vt.GhosttyFormatterScreenExtra);
        switch (when) {
            .before => {
                opts.extra.palette = true;
                opts.extra.modes = true;
            },
            .after => {
                opts.extra.scrolling_region = true;
                opts.extra.tabstops = true;
                opts.extra.pwd = true;
                opts.extra.keyboard = true;
                opts.extra.screen.style = true;
                opts.extra.screen.hyperlink = true;
                opts.extra.screen.protection = true;
                opts.extra.screen.kitty_keyboard = true;
                opts.extra.screen.charsets = true;
            },
        }

        const origin = self.gridRef(0, 0) orelse return error.ScreenUnavailable;
        var sel = std.mem.zeroes(vt.GhosttySelection);
        sel.size = @sizeOf(vt.GhosttySelection);
        sel.start = origin;
        sel.end = origin;
        opts.selection = &sel;

        try self.appendFormatted(allocator, out, opts);
    }

    /// Where the scrolling region starts, as the terminal itself states it.
    ///
    /// READ BACK OUT OF WHAT THE LIBRARY WRITES. There is no way to ask a
    /// terminal for its scrolling region — `ghostty_terminal_get` has no
    /// such datum — but there is a way to make it SAY it: asked for the
    /// scrolling region and nothing else, the formatter emits DECSTBM
    /// (`ESC [ top ; bottom r`) and, when the margins are not the full
    /// width, DECSLRM (`ESC [ left ; right s`). Those are the same bytes
    /// the restoration sends to the client, so what is parsed here is
    /// exactly what the far side will act on.
    ///
    /// A FULL REGION IS SAID BY SAYING NOTHING: the formatter emits
    /// neither sequence when the region is the whole screen, which is the
    /// ordinary case and the reason this answers zero rather than failing.
    fn scrollRegion(self: *Screen, allocator: std.mem.Allocator) struct { top: u16, left: u16 } {
        var opts = std.mem.zeroes(vt.GhosttyFormatterTerminalOptions);
        opts.size = @sizeOf(vt.GhosttyFormatterTerminalOptions);
        opts.emit = vt.GHOSTTY_FORMATTER_FORMAT_VT;
        opts.extra.size = @sizeOf(vt.GhosttyFormatterTerminalExtra);
        opts.extra.screen.size = @sizeOf(vt.GhosttyFormatterScreenExtra);
        opts.extra.scrolling_region = true;

        const origin_cell = self.gridRef(0, 0) orelse return .{ .top = 0, .left = 0 };
        var sel = std.mem.zeroes(vt.GhosttySelection);
        sel.size = @sizeOf(vt.GhosttySelection);
        sel.start = origin_cell;
        sel.end = origin_cell;
        opts.selection = &sel;

        var said: std.ArrayList(u8) = .empty;
        defer said.deinit(allocator);
        self.appendFormatted(allocator, &said, opts) catch return .{ .top = 0, .left = 0 };
        return .{
            .top = firstParam(said.items, 'r'),
            .left = firstParam(said.items, 's'),
        };
    }

    /// The first parameter of `ESC [ <a> ; <b> <final>`, as a zero-based
    /// index, or zero when the sequence is not there.
    fn firstParam(bytes: []const u8, final: u8) u16 {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, i, 0x1b)) |esc| {
            i = esc + 1;
            if (esc + 1 >= bytes.len or bytes[esc + 1] != '[') continue;
            var at = esc + 2;
            var value: u32 = 0;
            var digits: usize = 0;
            while (at < bytes.len and bytes[at] >= '0' and bytes[at] <= '9') : (at += 1) {
                value = value * 10 + (bytes[at] - '0');
                digits += 1;
            }
            if (digits == 0 or at >= bytes.len) continue;
            // Skip the rest of the parameters; only the first is wanted.
            while (at < bytes.len and (bytes[at] == ';' or (bytes[at] >= '0' and bytes[at] <= '9'))) : (at += 1) {}
            if (at < bytes.len and bytes[at] == final and value > 0) {
                return @intCast(@min(value - 1, std.math.maxInt(u16)));
            }
        }
        return 0;
    }

    /// One row, as the sequences that reproduce it.
    fn appendRow(
        self: *Screen,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        y: u16,
        cols: u16,
    ) !void {
        const start = self.gridRef(0, y) orelse return;
        const end = self.gridRef(cols - 1, y) orelse return;

        var opts = std.mem.zeroes(vt.GhosttyFormatterTerminalOptions);
        opts.size = @sizeOf(vt.GhosttyFormatterTerminalOptions);
        opts.emit = vt.GHOSTTY_FORMATTER_FORMAT_VT;
        // NOTHING BUT THE CELLS. The row is positioned by its caller and
        // the state around it is emitted once, not once per row — asking
        // for the extras here would repeat the whole palette on every
        // line of the screen.
        opts.unwrap = false;
        opts.trim = false;
        opts.extra.size = @sizeOf(vt.GhosttyFormatterTerminalExtra);
        opts.extra.screen.size = @sizeOf(vt.GhosttyFormatterScreenExtra);

        var sel = std.mem.zeroes(vt.GhosttySelection);
        sel.size = @sizeOf(vt.GhosttySelection);
        sel.start = start;
        sel.end = end;
        opts.selection = &sel;

        try self.appendFormatted(allocator, out, opts);
    }

    fn appendFormatted(
        self: *Screen,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        opts: vt.GhosttyFormatterTerminalOptions,
    ) !void {
        var formatter: vt.GhosttyFormatter = undefined;
        if (vt.ghostty_formatter_terminal_new(null, &formatter, self.term, opts) != vt.GHOSTTY_SUCCESS) {
            return error.ScreenUnavailable;
        }
        defer vt.ghostty_formatter_free(formatter);

        var buf: [*c]u8 = null;
        var len: usize = 0;
        if (vt.ghostty_formatter_format_alloc(formatter, null, &buf, &len) != vt.GHOSTTY_SUCCESS) {
            return error.ScreenUnavailable;
        }
        defer vt.ghostty_free(null, buf, len);
        try out.appendSlice(allocator, buf[0..len]);
    }

    /// A cell of the ACTIVE area — the rows the cursor can reach, which is
    /// what a repaint covers. Scrollback is the client's own; it kept
    /// what it was given and a repaint must not push it up.
    ///
    /// The reference is a snapshot and is void at the next mutation of
    /// the terminal, so it is made and used without one in between.
    fn gridRef(self: *Screen, x: u16, y: u16) ?vt.GhosttyGridRef {
        var point = std.mem.zeroes(vt.GhosttyPoint);
        point.tag = vt.GHOSTTY_POINT_TAG_ACTIVE;
        point.value.coordinate = .{ .x = x, .y = y };
        var ref = std.mem.zeroes(vt.GhosttyGridRef);
        ref.size = @sizeOf(vt.GhosttyGridRef);
        if (vt.ghostty_terminal_grid_ref(self.term, point, &ref) != vt.GHOSTTY_SUCCESS) return null;
        return ref;
    }
};

/// Recent output, and where the stream is.
///
/// A RING, addressed by ABSOLUTE STREAM OFFSET. The offset is what a
/// client presents on its way back, so it has to keep meaning the same
/// thing after the buffer has wrapped any number of times — which a
/// position into the buffer itself would not.
pub const Retained = struct {
    buf: []u8,
    /// Bytes ever written by the child. The position of the next one.
    total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Retained {
        return .{ .buf = try allocator.alloc(u8, @max(capacity, min_retention_bytes)) };
    }

    pub fn deinit(self: *Retained, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    /// The oldest offset still answerable.
    pub fn earliest(self: *const Retained) u64 {
        return if (self.total > self.buf.len) self.total - self.buf.len else 0;
    }

    pub fn has(self: *const Retained, offset: u64) bool {
        return offset >= self.earliest() and offset <= self.total;
    }

    pub fn append(self: *Retained, bytes: []const u8) void {
        // A write larger than the ring keeps only its tail: everything
        // before it is unreachable by definition, and pretending
        // otherwise would put stale bytes in front of fresh ones.
        const src = if (bytes.len > self.buf.len) bytes[bytes.len - self.buf.len ..] else bytes;
        var pos: usize = @intCast(self.total % self.buf.len);
        var written: usize = 0;
        while (written < src.len) {
            const room = self.buf.len - pos;
            const n = @min(room, src.len - written);
            @memcpy(self.buf[pos .. pos + n], src[written .. written + n]);
            written += n;
            pos = (pos + n) % self.buf.len;
        }
        self.total += bytes.len;
    }

    /// Copy out from an absolute offset. Returns 0 when the offset has
    /// fallen out of the window, which the caller must not confuse with
    /// "nothing new" — `has` answers that question.
    pub fn copyOut(self: *const Retained, from: u64, out: []u8) usize {
        if (!self.has(from)) return 0;
        const available: usize = @intCast(self.total - from);
        const n = @min(available, out.len);
        var pos: usize = @intCast(from % self.buf.len);
        var done: usize = 0;
        while (done < n) {
            const room = self.buf.len - pos;
            const chunk = @min(room, n - done);
            @memcpy(out[done .. done + chunk], self.buf[pos .. pos + chunk]);
            done += chunk;
            pos = (pos + chunk) % self.buf.len;
        }
        return n;
    }
};

/// What a newly attached client still needs doing for it.
pub const ClientEntry = struct {
    /// Where its backlog starts, when it presented a position that could
    /// be honoured.
    catch_up_from: ?u64 = null,
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const ChildExit = struct {
    /// False while the child is running. A client that loses its
    /// connection learns nothing about this; that is the point.
    exited: bool = false,
    /// True when a signal ended it, in which case `value` is the signal.
    by_signal: bool = false,
    value: u8 = 0,
};

/// Where a session's socket lives.
///
/// KEYED BY THE SESSION'S NAME, not by a process id: a client that has
/// restarted knows the name it started and nothing about the process
/// holding it ([[RFC-0014]] C-SCOPE, "recoverable").
///
/// BESIDE THE RECORD, IN A DIRECTORY THIS ACCOUNT OWNS. It lived in
/// `/tmp`, which the operating system is free to sweep and any user is
/// free to empty; a swept socket left the holder and its child running
/// with no way in. Under the account's own state directory the uid also
/// leaves the filename — two accounts cannot reach one path, so nothing
/// has to be disambiguated in it.
///
/// THE ABSOLUTE PATH, FOR EVERYTHING THAT IS NOT A SOCKET CALL — unlink,
/// chmod, a record, a message to a human. Those take PATH_MAX like any
/// other path, and bounding them at 104 was its own defect: `sys.unlink`
/// did, and silently removed nothing above it.
///
/// `bind` AND `connect` DO NOT USE THIS. They are bounded at 104 bytes by
/// the kernel and go through `socketCall`, which hands the kernel a
/// basename from inside the directory — its doc carries the measurement.
/// Nothing here checks a length, and that once cost eight call sites:
/// four propagated a raw error, two answered "not held", and `sessions`
/// did `catch continue`, dropping a session from the one surface that
/// could have found it.
pub fn socketPath(buf: []u8, agent_id: []const u8) ![]const u8 {
    var dir: [1024]u8 = undefined;
    const d = paths.sessionsDir(&dir) orelse return error.NoStateDirectory;
    return std.fmt.bufPrint(buf, "{s}/{s}.sock", .{ d, agent_id });
}

pub const SocketOp = enum { bind, connect };

/// BIND OR CONNECT A SESSION SOCKET AT `path`, whatever its length.
///
/// THE KERNEL BOUNDS WHAT IT IS HANDED, not where the socket lives.
/// `sun_path[104]` is an ABI constant in `<sys/un.h>` with no switch to
/// turn — measured: a 136-byte absolute path is refused, and the same
/// socket bound and connected under the name `local-1a2b.sock`. So a path
/// that does not fit is handed over as a BASENAME from inside its own
/// directory, which is fifteen bytes and cannot overflow.
///
/// THE SHORT PATH DOES NOT CHDIR AT ALL. `chdir` is process-global, so it
/// happens only where the bound forces it, and the directory is restored
/// through a FILE DESCRIPTOR — a path could have moved underneath us, a
/// descriptor cannot. Every caller is a short-lived CLI process or the
/// holder's own startup, and neither resolves a relative path on another
/// thread while this runs; macOS has no `bindat`/`connectat` to make that
/// unnecessary.
pub fn socketCall(path: []const u8, op: SocketOp) !sys.fd_t {
    if (sys.sockaddr_un.init(path)) |addr| {
        const fd = try sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0);
        errdefer sys.close(fd);
        switch (op) {
            .bind => try sys.bind(fd, &addr, addr.len()),
            .connect => try sys.connect(fd, &addr, addr.len()),
        }
        return fd;
    }

    const dir = std.fs.path.dirname(path) orelse return error.NameTooLong;
    const base = std.fs.path.basename(path);
    const addr = sys.sockaddr_un.init(base) orelse return error.NameTooLong;

    const here = try sys.openDirFd(".");
    defer sys.close(here);
    try sys.chdir(dir);
    defer sys.fchdir(here) catch {};

    const fd = try sys.socket(sys.AF.UNIX, sys.SOCK.STREAM, 0);
    errdefer sys.close(fd);
    switch (op) {
        .bind => try sys.bind(fd, &addr, addr.len()),
        .connect => try sys.connect(fd, &addr, addr.len()),
    }
    return fd;
}

/// WHAT THE CLAIM ON A NAME SAYS. Three answers, because there are three
/// states and collapsing any two of them is how this went wrong.
///
/// NOT `connect`. Asking the socket whether a session is there conflates a
/// live holder with a reachable one, and it can say NO about a live one:
/// with the backlog at four, the fifth simultaneous connect to a running
/// holder returns ECONNREFUSED on this platform — measured. A start guard
/// built on that reads a busy session as absent, and the holder that then
/// starts unlinks the running session's socket before binding its own.
pub const Claim = enum {
    /// A live holder is answering to this name.
    held,
    /// A record is there and nothing holds it: the holder is gone.
    free,
    /// No record. Nothing has ever claimed this name, or it was swept.
    absent,
};

/// WHETHER STARTING UNDER THIS NAME WOULD JOIN A SESSION RATHER THAN
/// START ONE ([[RFC-0014]] C-START).
///
/// Both halves. A start must not join a live session — and it must not be
/// refused by a name whose holder is gone, or a machine that lost power
/// would strand every name it had been using.
pub fn startWouldJoin(name: []const u8) bool {
    return claimState(name) == .held;
}

pub fn claimState(name: []const u8) Claim {
    var buf: [1024]u8 = undefined;
    // THE LOCK FILE, NOT THE RECORD. An flock binds to an inode, so a
    // claim taken on the file that also CARRIES the session's data is
    // released by anything that replaces that file — an atomic write, a
    // rename, a restore — and the live holder behind it then reads as a
    // tombstone. 49 sessions were swept out from under their holders that
    // way ([[WI-2026-09-03-009]]). Nothing writes the lock: it is created,
    // claimed, and from then on only opened to ask this question.
    const path = Record.lockPathFor(&buf, name) orelse return .absent;
    const fd = sys.openForClaim(path) orelse return .absent;
    defer sys.close(fd);
    return if (sys.tryClaim(fd)) .free else .held;
}

pub const Status = struct {
    name: []const u8,
    attached: bool,
    child_exited: bool,
    /// Where the session is standing, empty when the kernel would not
    /// say ([[RFC-0014]] C-PWD). Never a default: this answer is used as
    /// a destination for files, and a guess is worse than an admission.
    cwd: []const u8 = "",
    /// What its foreground process group is running ([[RFC-0014]]
    /// C-FOREGROUND). The holder states it and classifies nothing about
    /// it — whether that command is an agent is a judgement belonging to
    /// whoever recorded an expectation about it.
    command: []const u8 = "",
    /// WHERE THE SHELL ITSELF IS, which is not the same place
    /// ([[WI-2026-08-18-004]]). `cwd` above is the FOREGROUND group's, so
    /// a session running anything that has `cd`d reports that command's
    /// directory — `jenv rehash` runs from a great many `.zshrc` files
    /// and spends its life in `~/.jenv/shims`. The holder is the shell's
    /// own parent, so it can answer for the shell without guessing, and
    /// a reader that PLACES something wants this one.
    ///
    /// Empty when the kernel would not say, the same admission `cwd`
    /// makes.
    shell_cwd: []const u8 = "",

    /// WHETHER ANYBODY EVER TOOK ITS SEAT, and FOR HOW LONG NOBODY HAS.
    /// [[RFC-0014]] C-END requires enumeration to report both: they are
    /// what a human decides on when deciding whether to end a session.
    ever_attached: bool = false,
    unattached_ms: u64 = 0,
    /// What the attached client said it was ([[RFC-0014]] C-CLIENT-LABEL);
    /// empty when nobody is attached or the client said nothing.
    client_label: []const u8 = "",
    /// The human's name for the session ([[RFC-0014]] C-SESSION-NAME);
    /// empty when none was given.
    session_name: []const u8 = "",
};

/// The longest label or name the wire carries. Long enough for
/// "gui@a-hostname-of-some-length:123456" and a sentence-length name;
/// anything longer is cut, not refused.
pub const label_max: usize = 96;

/// A caller-provided home for the strings a status carries, so the
/// answer outlives the socket it came from.
pub const StatusBuffers = struct {
    cwd: [1024]u8 = undefined,
    command: [256]u8 = undefined,
    shell_cwd: [1024]u8 = undefined,
    client_label: [label_max]u8 = undefined,
    session_name: [label_max]u8 = undefined,
};


/// Ask a holder what it is doing, without taking its client's seat.
/// Null means nothing is answering on that path.
pub fn queryStatusInto(path: []const u8, into: *StatusBuffers) ?Status {
    const fd = socketCall(path, .connect) catch return null;
    defer sys.close(fd);
    // A holder that accepts and then says nothing would hang a listing of
    // every session on the host, so the question has a deadline.
    sys.setRecvTimeout(fd, 1000) catch {};
    writeFrame(fd, .status_request, &.{}) catch return null;
    var buf: [2048]u8 = undefined;
    const reply = (readFrame(fd, &buf) catch return null) orelse return null;
    if (reply.kind != .status or reply.payload.len < 2) return null;
    var out = Status{
        .name = "",
        .attached = reply.payload[0] == 1,
        .child_exited = reply.payload[1] == 1,
    };
    var at: usize = 2;
    if (reply.payload.len >= at + 2) {
        const cwd_len = std.mem.readInt(u16, reply.payload[at..][0..2], .little);
        at += 2;
        if (cwd_len > 0 and at + cwd_len <= reply.payload.len and cwd_len <= into.cwd.len) {
            @memcpy(into.cwd[0..cwd_len], reply.payload[at..][0..cwd_len]);
            out.cwd = into.cwd[0..cwd_len];
        }
        at += cwd_len;
    }
    if (reply.payload.len >= at + 2) {
        const cmd_len = std.mem.readInt(u16, reply.payload[at..][0..2], .little);
        at += 2;
        if (cmd_len > 0 and at + cmd_len <= reply.payload.len and cmd_len <= into.command.len) {
            @memcpy(into.command[0..cmd_len], reply.payload[at..][0..cmd_len]);
            out.command = into.command[0..cmd_len];
        }
        at += cmd_len;
    }
    if (reply.payload.len >= at + 2) {
        const shell_len = std.mem.readInt(u16, reply.payload[at..][0..2], .little);
        at += 2;
        if (shell_len > 0 and at + shell_len <= reply.payload.len and shell_len <= into.shell_cwd.len) {
            @memcpy(into.shell_cwd[0..shell_len], reply.payload[at..][0..shell_len]);
            out.shell_cwd = into.shell_cwd[0..shell_len];
        }
        at += shell_len;
    }
    // APPENDED, AND OPTIONAL TO READ. A holder from a build that predates
    // the policy answers a shorter status, and a client that demanded
    // these would read that as "not answering" rather than "older".
    if (reply.payload.len >= at + 1 + 8) {
        out.ever_attached = reply.payload[at] == 1;
        at += 1;
        out.unattached_ms = std.mem.readInt(u64, reply.payload[at..][0..8], .little);
        at += 8;
    }
    if (reply.payload.len >= at + 2) {
        const label_len = std.mem.readInt(u16, reply.payload[at..][0..2], .little);
        at += 2;
        if (label_len > 0 and at + label_len <= reply.payload.len and label_len <= into.client_label.len) {
            @memcpy(into.client_label[0..label_len], reply.payload[at..][0..label_len]);
            out.client_label = into.client_label[0..label_len];
        }
        at += label_len;
    }
    if (reply.payload.len >= at + 2) {
        const name_len = std.mem.readInt(u16, reply.payload[at..][0..2], .little);
        at += 2;
        if (name_len > 0 and at + name_len <= reply.payload.len and name_len <= into.session_name.len) {
            @memcpy(into.session_name[0..name_len], reply.payload[at..][0..name_len]);
            out.session_name = into.session_name[0..name_len];
        }
        at += name_len;
    }
    return out;
}

/// Give a session its name ([[RFC-0014]] C-SESSION-NAME). False when the
/// holder could not be reached or does not keep names.
pub fn requestName(path: []const u8, given: []const u8) bool {
    const fd = socketCall(path, .connect) catch return false;
    defer sys.close(fd);
    sys.setRecvTimeout(fd, 1000) catch {};
    writeFrame(fd, .set_name, given[0..@min(given.len, label_max)]) catch return false;
    var buf: [64]u8 = undefined;
    const reply = (readFrame(fd, &buf) catch return false) orelse return false;
    return reply.kind == .status;
}

/// Ask a holder to end. True when it accepted the request.
pub fn requestEnd(path: []const u8) bool {
    const fd = socketCall(path, .connect) catch return false;
    defer sys.close(fd);
    sys.setRecvTimeout(fd, 1000) catch {};
    writeFrame(fd, .end_request, &.{}) catch return false;
    var buf: [64]u8 = undefined;
    // THE ACK, NOT ANY FRAME. A holder that answered with something else
    // — a displaced notice, a version refusal — did not accept the end.
    const reply = (readFrame(fd, &buf) catch return false) orelse return false;
    return reply.kind == .status;
}

// ---------------------------------------------------------------------------
// The record ([[RFC-0014]] C-SCOPE, [[WI-2026-08-22-001]])
// ---------------------------------------------------------------------------

/// THE DIRECTORY HOLDING THE SOCKETS AND THE RECORDS, made so that only
/// its owner may enter it ([[RFC-0014]] C-ENTITLEMENT).
///
/// `createDirPath` takes the process umask — 022 on a stock machine — so
/// this was 0755 and every record in it 0644: any local account could
/// list the sessions, read each holder's name, pid and start time, and
/// reach the socket path. The clause forbids exactly that ("Enumeration
/// MUST NOT reveal the existence, name, or state of a holder belonging
/// to another account").
///
/// IT ALSO CLOSES THE BIND-THEN-CHMOD WINDOW. A socket carries the
/// umask's bits between `bind` and the `chmod` that follows it; with the
/// directory shut, no other account can reach the path in that window to
/// begin with.
fn makeSessionsDir(path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io_mod.get(), path) catch {};
    // Also corrects a directory an earlier run left open. A directory
    // that is not ours to re-mode — `/tmp` under a test, someone else's
    // tree — is left alone: this tightens our own state directory and
    // makes no claim about anywhere else.
    sys.chmod(path, 0o700) catch {};
}

/// A SESSION IS A RECORD; THE PROCESS IS WHAT IS CURRENTLY READING IT.
///
/// The inverse — a session that IS its process, findable only through a
/// socket in `/tmp` — makes reachability rest on a directory the operating
/// system may sweep and any user may empty. What is lost with that file is
/// not a doorknob: the holder and its child go on running with nothing
/// able to name them, so they can be neither listed nor ended.
///
/// A CLAIM, AND THE ONE FACT THE CLAIM MAKES TRUSTWORTHY. The file is
/// held open and `flock`ed by its holder for the session's whole life, so
/// the claim still being taken is the kernel saying that process is there
/// — and therefore that the pid written here is still ITS pid, rather
/// than a number something else may have inherited.
///
/// It carried a `started_at` too, described as one of "the two facts
/// nothing else can answer once the process is gone". Once the process is
/// gone neither answers anything, and in three months nothing ever read
/// it. Everything else about a live session — where it is standing, what
/// is running in it, how long nobody has watched it — is the holder's to
/// state ([[RFC-0014]] C-PWD, C-FOREGROUND, C-END), and a copy here would
/// be a second answer that drifts from the first.
///
/// METADATA, NEVER CONTENTS. [[RFC-0014]] C-CONFINEMENT forbids the holder
/// to write session contents — output, screen state, input — to persistent
/// storage, and this record does not carry any. C-PWD and C-FOREGROUND
/// establish that facts ABOUT the process are not contents. The line is
/// worth stating because the file is the obvious place for the next person
/// to put a line of scrollback.
pub const Record = struct {
    pid: i32,
    /// The human's name, when one was given ([[RFC-0014]] C-SESSION-NAME);
    /// read from the record so an unreachable holder is still listed by
    /// what it is called.
    name_buf: [label_max]u8 = undefined,
    name_len: u8 = 0,

    pub fn sessionName(self: *const Record) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Rewrite the record through the fd the holder holds open (the claim
    /// lives on it), now carrying the name. Quotes and backslashes are
    /// escaped; control characters are dropped rather than written into
    /// a file another process parses as JSON.
    /// BY NAME, NOT THROUGH THE CLAIM. The descriptor the holder keeps
    /// open is its lock now, and the lock is never written; the record is
    /// a separate file and is replaced whole.
    pub fn rewrite(name: []const u8, session_name: []const u8) void {
        var body: [64 + label_max * 2]u8 = undefined;
        var at: usize = 0;
        const head = std.fmt.bufPrint(body[0..], "{{\"pid\":{d},\"name\":\"", .{std.c.getpid()}) catch return;
        at += head.len;
        for (session_name) |c| {
            if (at + 2 >= body.len - 4) break;
            if (c == '"' or c == '\\') {
                body[at] = '\\';
                at += 1;
            } else if (c < 0x20) continue;
            body[at] = c;
            at += 1;
        }
        const tail = "\"}\n";
        @memcpy(body[at .. at + tail.len], tail);
        at += tail.len;
        var buf: [1024]u8 = undefined;
        const path = pathFor(&buf, name) orelse return;
        writeBody(path, body[0..at]);
    }

    pub fn pathFor(buf: []u8, name: []const u8) ?[]const u8 {
        var dir: [1024]u8 = undefined;
        const d = paths.sessionsDir(&dir) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ d, name }) catch null;
    }

    /// WHERE THE CLAIM LIVES, and it is deliberately not where the data
    /// lives ([[claimState]]). Ignored by every enumeration of this
    /// directory, which selects on `.json`.
    pub fn lockPathFor(buf: []u8, name: []const u8) ?[]const u8 {
        var dir: [1024]u8 = undefined;
        const d = paths.sessionsDir(&dir) orelse return null;
        return std.fmt.bufPrint(buf, "{s}/{s}.lock", .{ d, name }) catch null;
    }

    /// CLAIMED FIRST, THEN DESCRIBED. The returned descriptor is the
    /// holder's claim, and it must stay open for as long as the session
    /// does: the kernel releasing it is how anything else learns the
    /// holder is gone, whatever killed it ([[sweepEnded]]).
    ///
    /// THE CLAIM IS ON A FILE OF ITS OWN ([[claimState]]). It is created
    /// and locked and never written again — not truncated, not renamed,
    /// not replaced — because an flock lives on an inode and a claim
    /// sharing a file with data is released by every writer of that data.
    ///
    /// LOCK BEFORE RECORD, WHICH IS WHY THE ORDER IS THIS ORDER. Between
    /// the two there is a moment with a claim and no record, and that
    /// shape is inert: `sweepEnded` needs a record it can read before it
    /// will remove anything. The reverse order would leave a readable
    /// record with no claim beside it — indistinguishable from a
    /// tombstone, and swept as one.
    pub fn write(name: []const u8) ?sys.fd_t {
        var dir: [1024]u8 = undefined;
        if (paths.sessionsDir(&dir)) |d| makeSessionsDir(d);

        var lbuf: [1024]u8 = undefined;
        const lock_path = lockPathFor(&lbuf, name) orelse return null;
        // NOT TRUNCATED, EVER. A second holder taking a name a live one
        // already holds must reach the claim and be refused by it, and
        // must not disturb anything on the way.
        var lock = std.Io.Dir.cwd().createFile(io_mod.get(), lock_path, .{
            .truncate = false,
        }) catch return null;
        sys.chmod(lock_path, 0o600) catch {};
        const fd: sys.fd_t = @intCast(lock.handle);
        if (!sys.tryClaim(fd)) {
            lock.close(io_mod.get());
            return null;
        }

        // EVERY FAILURE FROM HERE HANDS THE CLAIM BACK. Returning null
        // with the lock still open would leave this process holding a
        // name it told its caller it had not taken — `held` for the rest
        // of its life, and so unstartable by anyone.
        var buf: [1024]u8 = undefined;
        const path = pathFor(&buf, name) orelse {
            lock.close(io_mod.get());
            return null;
        };
        var body: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&body, "{{\"pid\":{d}}}\n", .{std.c.getpid()}) catch {
            lock.close(io_mod.get());
            return null;
        };
        writeBody(path, text);
        // NOT CLOSED. Closing releases the claim, and the claim is the
        // point; the caller owns the descriptor from here.
        return fd;
    }

    /// The record's contents, replaced. OWNER ONLY, like the socket and
    /// the lock beside it: this names a session and the process holding
    /// it ([[RFC-0014]] C-ENTITLEMENT).
    fn writeBody(path: []const u8, text: []const u8) void {
        var file = std.Io.Dir.cwd().createFile(io_mod.get(), path, .{}) catch return;
        defer file.close(io_mod.get());
        sys.chmod(path, 0o600) catch {};
        var writer = file.writer(io_mod.get(), &.{});
        writer.interface.writeAll(text) catch {};
    }

    /// WHETHER THE PROCESS THAT WROTE THIS RECORD IS STILL THERE.
    ///
    /// THE CLAIM, NOT THE PID. This used to be `kill(pid, 0)`, which
    /// answers whether anything wears the number — so a holder that died
    /// and had its number handed to an unrelated process read as alive,
    /// which left its tombstone unsweepable AND made `synapty end`
    /// signal the stranger. A claim is bound to the open file, and the
    /// kernel releases it however its owner dies.
    pub fn ownerGone(name: []const u8) bool {
        return claimState(name) == .free;
    }

    /// THE CLAIM GOES WITH THE RECORD. A lock left behind is a name that
    /// reads as a tombstone forever — `free`, never `absent` — and a
    /// record left behind is the thing this whole file exists to sweep.
    pub fn remove(name: []const u8) void {
        var buf: [1024]u8 = undefined;
        if (pathFor(&buf, name)) |path| sys.unlink(path);
        var lbuf: [1024]u8 = undefined;
        if (lockPathFor(&lbuf, name)) |path| sys.unlink(path);
    }

    pub fn read(allocator: std.mem.Allocator, name: []const u8) ?Record {
        var buf: [1024]u8 = undefined;
        const path = pathFor(&buf, name) orelse return null;
        var file = std.Io.Dir.cwd().openFile(io_mod.get(), path, .{}) catch return null;
        defer file.close(io_mod.get());
        var body: [512]u8 = undefined;
        var reader = file.reader(io_mod.get(), &.{});
        const n = reader.interface.readSliceShort(&body) catch return null;
        if (n == 0) return null;
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            body[0..n],
            .{},
        ) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const pid = parsed.value.object.get("pid") orelse return null;
        if (pid != .integer) return null;
        var out: Record = .{ .pid = @intCast(pid.integer) };
        if (parsed.value.object.get("name")) |given| if (given == .string) {
            const kept: usize = @min(given.string.len, label_max);
            @memcpy(out.name_buf[0..kept], given.string[0..kept]);
            out.name_len = @intCast(kept);
        };
        return out;
    }

};

/// AN AGENT'S WINDOW IS CLOSED BY THE HUMAN, AND BY NOTHING ELSE.
///
/// [[RFC-0014]] C-END requires the reap policy to be STATED and
/// discoverable rather than left as the silence of no policy existing.
/// This is it, and it is declared in every listing.
///
/// A TIMER WOULD MEASURE THE WRONG THING: any threshold ends an agent
/// that is working and keeps a shell that is idle, on a schedule the
/// human never set. The session unattended longest is often the valuable
/// one. What the workbench owes instead is the means to FIND such a
/// session — whether anybody ever attached, and how long nobody has
/// (reported below) — and then to leave the decision where it belongs.
pub const never_reaped = "sessions are never ended except by you";

/// A TOMBSTONE IS NOT A SESSION.
///
/// [[RFC-0014]] C-END is about not ENDING a session: no timer, no
/// threshold, nothing but the human, because the session unattended
/// longest is often the valuable one. It says nothing about keeping the
/// RECORD of one that has already ended, and until now nothing removed
/// those. `stop` clears its own — a holder that was killed outright, or
/// one a reboot took with it, never reaches `stop` and leaves behind a
/// file naming a pid the kernel has never heard of.
///
/// Those files are not history. Nothing reads them but the listing that
/// prints them and the `end` that says the session was already gone;
/// neither offers anything a human can act on, and on the machine that
/// prompted this there were a hundred and fourteen of them burying the
/// one live session ([[WI-2026-08-29-008]]).
///
/// SWEPT ON THE HOLDER BEING GONE, NOT ON ITS PID BEING FREE. The first
/// form of this asked `kill(pid, 0)`, which is a question about a number:
/// a holder that died and had its number handed to an unrelated process
/// answered alive, and its tombstone could never be swept
/// ([[Record.ownerGone]], [[WI-2026-08-29-009]]).
///
/// THE SOCKET GOES WITH THE RECORD. It is the same fact one layer down —
/// a socket nothing is listening on, that no client can reach and no
/// `end` can use — and the machine that prompted this had one for every
/// tombstone. Only for a session already proved dead: a socket with no
/// record beside it is left alone, because a holder binds and listens
/// BEFORE it writes its record, so that shape is also what a session
/// still starting up looks like.
pub fn sweepEnded(allocator: std.mem.Allocator, name: []const u8) bool {
    if (Record.read(allocator, name) == null) return false;
    if (!Record.ownerGone(name)) return false;
    Record.remove(name);
    var buf: [1024]u8 = undefined;
    if (socketPath(&buf, name)) |path| sys.unlink(path) else |_| {}
    return true;
}

pub const Holder = struct {
    allocator: std.mem.Allocator,
    pty: sys.Pty,
    child_pid: i32 = -1,
    listener_fd: sys.fd_t,
    /// THE CLAIM ON THIS SESSION'S RECORD, held open for the holder's
    /// whole life. The kernel releases it however this process ends, and
    /// that release is how a listing on the other side of a reboot learns
    /// the session is gone ([[sweepEnded]]).
    record_fd: ?sys.fd_t = null,
    socket_path: []const u8,

    mutex: std.Io.Mutex = .init,
    /// The one attached client, if any ([[RFC-0014]] C-ONE-CLIENT).
    client: ?sys.fd_t = null,
    /// Bumped on every attach. A connection thread compares it before
    /// touching the child: a displaced client whose read was already in
    /// flight must not deliver that keystroke into the session it just
    /// lost ([[RFC-0014]] C-INPUT).
    generation: u64 = 0,

    /// Recent output, so a client that comes back can continue rather
    /// than restart ([[RFC-0014]] C-RESUME).
    retained: Retained = .{ .buf = &.{} },
    /// This holder's lifetime under its name. A position from another
    /// incarnation is meaningless here and is refused rather than
    /// resolved against unrelated bytes.
    incarnation: u64 = 0,
    /// What the screen looks like, for a client that arrives holding
    /// nothing ([[RFC-0014]] C-RESTORE).
    screen: ?Screen = null,
    /// While true the pump only retains; the catching-up client is being
    /// fed from the ring by its own thread, and a direct write would put
    /// new output in front of old.
    catching_up: bool = false,

    child: ChildExit = .{},

    /// WHETHER ANYBODY HAS EVER TAKEN THIS SESSION'S SEAT, which
    /// [[RFC-0014]] C-END requires enumeration to report.
    ever_attached: bool = false,
    /// Wall-clock milliseconds at which the last client left — or at
    /// which this holder started, for one nobody has attached to yet, so
    /// that "how long has nobody been here" has an answer from birth.
    unattached_since: i64 = 0,
    /// WHO IS IN THE SEAT ([[RFC-0014]] C-CLIENT-LABEL): what the attached
    /// client said it was in its hello, kept for the status reply and for
    /// the notice the next attach sends the client it displaces. Empty
    /// for a client that said nothing.
    client_label_buf: [label_max]u8 = undefined,
    client_label_len: u8 = 0,
    /// WRITES IN FLIGHT TO THE CLIENT FD ([[WI-2026-09-02-016]]). The pump
    /// reads `client` under the mutex and writes after releasing it; the
    /// departing client's loop used to close that fd meanwhile, and accept
    /// can hand the number to the next client — one session's output on
    /// another client's connection. Now a write is counted while it is
    /// out, and the close waits for the count to reach zero. The wait is
    /// bounded by the send timeout every write already carries.
    writes_in_flight: u32 = 0,
    writes_drained: std.Io.Condition = .init,
    /// Client threads, one per attach — reaped on accept, joined by stop()
    /// so none touches this holder after it has been torn down.
    client_threads: sys.ThreadReaper = sys.ThreadReaper.init(std.heap.page_allocator),
    /// WHAT THE HUMAN CALLS THIS SESSION ([[RFC-0014]] C-SESSION-NAME).
    /// Given by a client, kept here and in the record, never derived.
    name_buf: [label_max]u8 = undefined,
    name_len: u8 = 0,
    /// ATOMIC, for the same reason `ending` is: it is written by whoever
    /// calls stop() and read by three threads whose loops are otherwise
    /// free to cache it. A join against a thread that never observed the
    /// change does not return, and a holder that cannot finish stopping
    /// keeps answering — which is a session a human has ended and can
    /// still see.
    running: bool = false,
    /// A human asked for this session to be over ([[RFC-0014]] C-END).
    /// Distinct from `running`, which is how the threads are told to
    /// stop: this is the reason, and the caller reads it to know whether
    /// to kill the child.
    ///
    /// READ AND WRITTEN ATOMICALLY, like `running`. It is set on the
    /// accept thread and read by the thread that owns the holder's
    /// lifetime, and a plain load in that loop can be hoisted out of it —
    /// which is exactly what happened: `end` reported success, the reply
    /// went out, and the session ran on.
    ending: bool = false,

    threads: struct {
        pump: ?std.Thread = null,
        accept: ?std.Thread = null,
        /// Waits on the CHILD. Named for what it does: it was called
        /// `reap` for the `waitpid` sense of the word, which is not the
        /// sense [[RFC-0014]] C-END uses, and the collision is how a
        /// missing reap policy came to look like a present one.
        child_exit: ?std.Thread = null,
    } = .{},

    /// How long a client may fail to consume output before it is detached
    /// ([[RFC-0014]] C-STALLED-CLIENT). The clause's floor is ten seconds:
    /// below it, a busy client is disconnected for being busy.
    pub const stall_timeout_ms: u64 = 10_000;

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Holder {
        // The directory holding both the socket and the record is ours to
        // make; nothing else creates it on a fresh machine.
        if (std.fs.path.dirname(socket_path)) |d| makeSessionsDir(d);
        sys.unlink(socket_path);
        // THROUGH THE ONE OPERATION, so a deep configuration root binds
        // here exactly as it connects everywhere else.
        const fd = try socketCall(socket_path, .bind);
        errdefer sys.close(fd);
        // OWNER ONLY ([[RFC-0014]] C-ENTITLEMENT). This socket is a
        // terminal a human types into and an agent works in; on a shared
        // host, world access to it is world access to both. The same
        // reasoning already governs the pane IPC socket beside it.
        try sys.chmod(socket_path, 0o700);
        try sys.listen(fd, 4);
        return .{
            .allocator = allocator,
            .pty = undefined,
            .listener_fd = fd,
            .socket_path = socket_path,
            // THE CLOCK STARTS AT BIRTH for a session nobody has attached
            // to yet, so "how long has nobody been here" is answerable
            // before anybody ever has been.
            .unattached_since = sys.nowMillis(),
        };
    }

    /// Open the terminal, put the child on it, and start serving.
    pub fn start(
        self: *Holder,
        argv: []const [*:0]const u8,
        env: []const [*:0]const u8,
        ws: sys.winsize,
    ) !void {
        // TERM first, so a caller that has an opinion overrides it by
        // passing its own — later assignments win in the child.
        var env_with_term: [24][*:0]const u8 = undefined;
        if (env.len + 1 > env_with_term.len) return error.TooManyEnvironmentEntries;
        env_with_term[0] = "TERM=" ++ default_term;
        for (env, 0..) |e, i| env_with_term[i + 1] = e;
        const child_env = env_with_term[0 .. env.len + 1];
        self.retained = try Retained.init(self.allocator, min_retention_bytes);
        errdefer self.retained.deinit(self.allocator);
        // NOT A COUNTER. Two holders of one name never overlap in time,
        // but a CLIENT can be away across both — and a counter that
        // restarted at zero would make the second holder's offsets look
        // like the first's, which is the one mistake this value exists to
        // make impossible. It does not need to be unguessable, only
        // unrepeated: the same shape the peer-id suffix uses.
        self.incarnation = mintIncarnation();
        // A HOLDER WITHOUT A SCREEN IS STILL A HOLDER. If the terminal
        // library will not start, everything else here works and a cold
        // reattach is merely as blank as it was before this existed —
        // which is a degradation, not a session lost.
        self.screen = Screen.init(ws.ws_row, ws.ws_col) catch |err| blk: {
            log.err("no screen model: {s} — a cold reattach will be empty", .{@errorName(err)});
            break :blk null;
        };
        self.pty = try sys.openPty();
        errdefer self.pty.deinit();
        // NON-BLOCKING MASTER, polled. The pump has to be interruptible
        // for stop() to be able to join it, and closing a descriptor
        // another thread is blocked reading is not defined behaviour.
        try sys.setNonblocking(self.pty.master);
        self.child_pid = try sys.spawnOnPty(&self.pty, argv, child_env, ws);
        @atomicStore(bool, &self.running, true, .release);
        self.threads.pump = try std.Thread.spawn(.{}, pumpLoop, .{self});
        self.threads.accept = try std.Thread.spawn(.{}, acceptLoop, .{self});
        self.threads.child_exit = try std.Thread.spawn(.{}, childExitLoop, .{self});
        // WRITTEN ONCE THE CHILD IS ON THE TERMINAL, so a record never
        // names a session that failed to start.
        self.record_fd = Record.write(self.name());
    }

    /// This holder's session name, taken back out of the socket path it
    /// was built from — the name is what a client knows it by.
    pub fn name(self: *const Holder) []const u8 {
        const base = std.fs.path.basename(self.socket_path);
        return if (std.mem.endsWith(u8, base, ".sock"))
            base[0 .. base.len - 5]
        else
            base;
    }

    pub fn stop(self: *Holder) void {
        @atomicStore(bool, &self.running, false, .release);
        // Wake the accept: a blocked accept() ends when its listener does,
        // and nothing else is reading this descriptor.
        sys.close(self.listener_fd);
        if (self.threads.pump) |t| t.join();
        if (self.threads.accept) |t| t.join();
        if (self.threads.child_exit) |t| t.join();
        // THE CLIENT THREAD IS ENDED BEFORE THE HOLDER IS ([[WI-2026-09-02-016]]):
        // wake it by shutting its fd, then join it — it is the one that
        // closes the fd, after any write in flight has returned.
        self.mutex.lock(io_mod.get()) catch {};
        if (self.client) |fd| sys.shutdown(fd, sys.SHUT.RDWR);
        self.mutex.unlock(io_mod.get());
        self.client_threads.deinit();
        self.detachClient(null);
        self.pty.deinit();
        if (self.retained.buf.len > 0) self.retained.deinit(self.allocator);
        if (self.screen) |*sc| sc.deinit();
        sys.unlink(self.socket_path);
        // A SESSION THAT ENDED CLEANLY LEAVES NO RECORD. One left behind
        // by a crash is answered by the claim below being released, which
        // the kernel does whatever killed the process ([[sweepEnded]]).
        Record.remove(self.name());
        if (self.record_fd) |fd| {
            sys.close(fd);
            self.record_fd = null;
        }
    }

    /// Kill the child and wait for it. Ending, as opposed to detaching
    /// ([[RFC-0014]] C-DETACH).
    pub fn endChild(self: *Holder) void {
        if (self.child_pid > 0) {
            _ = std.c.kill(self.child_pid, @enumFromInt(9));
            _ = std.c.waitpid(self.child_pid, null, 0);
        }
    }

    pub fn hasClient(self: *Holder) bool {
        self.mutex.lock(io_mod.get()) catch return false;
        defer self.mutex.unlock(io_mod.get());
        return self.client != null;
    }

    pub fn isRunning(self: *const Holder) bool {
        return @atomicLoad(bool, &self.running, .acquire);
    }

    pub fn isEnding(self: *const Holder) bool {
        return @atomicLoad(bool, &self.ending, .acquire);
    }

    pub fn childState(self: *Holder) ChildExit {
        self.mutex.lock(io_mod.get()) catch return .{};
        defer self.mutex.unlock(io_mod.get());
        return self.child;
    }

    // -----------------------------------------------------------------
    // Threads
    // -----------------------------------------------------------------

    /// Child output -> the ring, and the attached client if there is one.
    ///
    /// WITH NOBODY ATTACHED THE BYTES ARE RETAINED, NOT DROPPED, and the
    /// ring is bounded: letting the pty fill and stall the child is the
    /// failure [[RFC-0014]] C-STALLED-CLIENT forbids for a slow client,
    /// and it would be worse arriving from an absent one.
    fn pumpLoop(self: *Holder) void {
        var buf: [8192]u8 = undefined;
        while (self.isRunning()) {
            const n = sys.read(self.pty.master, &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    _ = sleepMs(2);
                    continue;
                },
                // The child's side is gone; the reaper reports it.
                else => break,
            };
            if (n == 0) {
                _ = sleepMs(2);
                continue;
            }
            self.retainAndDeliver(buf[0..n]);
        }
    }

    /// Everything the child says goes into the ring, and then to the
    /// client — unless a client is catching up, in which case the ring is
    /// the only path and its own thread will reach these bytes in order.
    fn retainAndDeliver(self: *Holder, bytes: []const u8) void {
        self.mutex.lock(io_mod.get()) catch return;
        self.retained.append(bytes);
        if (self.screen) |*sc| sc.write(bytes);
        const busy = self.catching_up;
        const target = if (busy) null else self.beginWriteLocked();
        self.mutex.unlock(io_mod.get());
        const fd = target orelse return;
        defer self.endWrite();
        writeFrame(fd, .data, bytes) catch {
            self.detachClient(fd);
            sys.shutdown(fd, sys.SHUT.RDWR);
        };
    }

    /// Under the mutex: the client fd with a write counted against it, or
    /// null when nobody is attached.
    fn beginWriteLocked(self: *Holder) ?sys.fd_t {
        const fd = self.client orelse return null;
        self.writes_in_flight += 1;
        return fd;
    }

    fn endWrite(self: *Holder) void {
        self.mutex.lock(io_mod.get()) catch return;
        defer self.mutex.unlock(io_mod.get());
        self.writes_in_flight -= 1;
        if (self.writes_in_flight == 0) self.writes_drained.broadcast(io_mod.get());
    }

    /// THE ONE PLACE A CLIENT FD IS CLOSED: after every write that was
    /// out against it has returned, so the number cannot be reused under
    /// a writer ([[WI-2026-09-02-016]]).
    fn closeClientFd(self: *Holder, fd: sys.fd_t) void {
        self.mutex.lock(io_mod.get()) catch {
            sys.close(fd);
            return;
        };
        while (self.writes_in_flight > 0) {
            self.writes_drained.wait(io_mod.get(), &self.mutex) catch break;
        }
        sys.close(fd);
        self.mutex.unlock(io_mod.get());
    }

    fn acceptLoop(self: *Holder) void {
        while (self.isRunning()) {
            const fd = sys.accept(self.listener_fd) catch |err| switch (err) {
                error.WouldBlock, error.ConnectionAborted => continue,
                else => break,
            };
            // WHO IS ASKING ([[RFC-0014]] C-ENTITLEMENT: "A holder MUST
            // serve only the local account that owns it", and "The holder
            // is responsible for its own checks"). Asked of the kernel,
            // which cannot be raced by a permission bit or inherited by a
            // descriptor. A session is a terminal a human types into and
            // an agent works in; on a shared host, serving anyone else is
            // handing both over.
            const peer = sys.peerUid(fd) catch {
                sys.close(fd);
                continue;
            };
            if (peer != sys.selfUid()) {
                log.warn("refused a connection from uid {d}", .{peer});
                sys.close(fd);
                continue;
            }
            self.handshake(fd) catch {
                sys.close(fd);
                continue;
            };
        }
    }

    /// One connection, from its first frame onward.
    ///
    /// THE FIRST FRAME DECIDES WHAT THE CONNECTION IS. A question about
    /// the session must not cost the human using it their seat, so a
    /// status query is answered and closed without ever reaching the
    /// client slot ([[RFC-0014]] C-ONE-CLIENT).
    fn handshake(self: *Holder, fd: sys.fd_t) !void {
        var buf: [4096]u8 = undefined;
        sys.setRecvTimeout(fd, first_frame_ms) catch {};
        const frame = (try readFrame(fd, &buf)) orelse return error.Closed;
        sys.setRecvTimeout(fd, 0) catch {};
        switch (frame.kind) {
            .status_request => {
                self.replyStatus(fd) catch {};
                sys.close(fd);
                return;
            },
            .end_request => {
                @atomicStore(bool, &self.ending, true, .release);
                writeFrame(fd, .status, &.{ 0, 1 }) catch {};
                sys.close(fd);
                return;
            },
            .set_name => {
                self.setName(frame.payload);
                const state = self.childState();
                writeFrame(fd, .status, &.{ if (self.hasClient()) 1 else 0, if (state.exited) 1 else 0 }) catch {};
                sys.close(fd);
                return;
            },
            .hello => {},
            else => return error.Closed,
        }
        if (frame.payload.len < 5) return error.Closed;
        // SKEW IS VISIBLE, NEVER SILENT ([[RFC-0014]] C-VERSION). The
        // refusal names both versions and reaches the client as a frame;
        // enumerating and ending a holder are answered above, BEFORE this,
        // because the clause requires them to work across a mismatch.
        if (frame.payload[0] != protocol_version) {
            writeFrame(fd, .version_mismatch, &.{ protocol_version, frame.payload[0] }) catch {};
            sys.close(fd);
            return;
        }
        const rows = std.mem.readInt(u16, frame.payload[1..3], .little);
        const cols = std.mem.readInt(u16, frame.payload[3..5], .little);

        // A position is optional, and its absence is not the same as a
        // position that cannot be honoured — the client is told which.
        var answer: ResumeAnswer = .fresh;
        var from: u64 = 0;
        if (frame.payload.len >= 21) {
            const inc = std.mem.readInt(u64, frame.payload[5..13], .little);
            const off = std.mem.readInt(u64, frame.payload[13..21], .little);
            // AN ALL-ZERO POSITION IS NO POSITION. A client with nothing
            // to resume from but a label to give still has to reach byte
            // 21, and incarnations are minted non-zero so this cannot be
            // a real one.
            if (inc != 0 or off != 0) answer = self.judgePosition(inc, off, &from);
        }
        // THE LABEL, if the client gave one ([[RFC-0014]] C-CLIENT-LABEL):
        // one length byte, then the bytes. Optional and trailing, so a
        // hello without it is the hello this holder always accepted.
        var label: []const u8 = &.{};
        if (frame.payload.len >= 22) {
            const len: usize = frame.payload[21];
            if (frame.payload.len >= 22 + len) label = frame.payload[22 .. 22 + len];
        }

        // A CLIENT THAT CANNOT KEEP UP IS DETACHED, NEVER OBEYED
        // ([[RFC-0014]] C-STALLED-CLIENT). The timeout is on the socket so
        // that a write into a half-open connection cannot block the pump
        // — which is the child — for as long as a dead peer takes to
        // notice it is dead.
        sys.setSendTimeout(fd, stall_timeout_ms) catch {};

        const start_at = if (answer == .resumed) from else self.streamPosition();
        var welcome: [26]u8 = undefined;
        welcome[0] = protocol_version;
        welcome[1] = @intFromEnum(answer);
        std.mem.writeInt(u64, welcome[2..10], self.incarnation, .little);
        std.mem.writeInt(u64, welcome[10..18], start_at, .little);
        std.mem.writeInt(u64, welcome[18..26], @intCast(self.retained.buf.len), .little);
        try writeFrame(fd, .welcome, &welcome);

        const gen = self.attach(fd, answer == .resumed, label);

        // THE SIZE WAITS FOR THE BACKLOG ([[RFC-0014]] C-RESUME). Bytes
        // written for the geometry the child had are delivered in it; a
        // resize applied first would wrap and mis-address every one of
        // them. A fresh client has no backlog, so its size applies now —
        // and BEFORE the restoration is produced, so the description it
        // receives is in the geometry it asked for (C-RESTORE).
        if (answer != .resumed) {
            sys.setWinsize(&self.pty, .{ .ws_row = rows, .ws_col = cols }) catch {};
            self.resizeScreen(rows, cols);
            self.sendRestoration(fd, rows, cols) catch {};
        }

        _ = self.client_threads.reap();
        self.client_threads.spawn(clientLoop, .{ self, fd, gen, ClientEntry{
            .catch_up_from = if (answer == .resumed) from else null,
            .rows = rows,
            .cols = cols,
        } }) catch {
            self.detachClient(fd);
            self.closeClientFd(fd);
            return error.Closed;
        };
    }

    /// Ten seconds for a first frame ([[WI-2026-09-02-016]]): every real
    /// client sends its hello, status request or end request at once, and
    /// the query side already sets deadlines — the accept side did not,
    /// so one silent connection parked status, end and attach for the
    /// session's life.
    const first_frame_ms: u64 = 10_000;

    /// Two flags — attached, exited — then three length-prefixed strings:
    /// the foreground group's working directory, its command, and the
    /// SHELL's own working directory; then ever_attached and
    /// unattached_ms, and the client label and session name
    /// ([[RFC-0014]] C-CLIENT-LABEL, C-SESSION-NAME).
    ///
    /// BOTH DIRECTORIES, BECAUSE THEY ANSWER DIFFERENT QUESTIONS
    /// ([[WI-2026-08-18-004]]). The foreground group's is what the human
    /// is looking at — an editor three levels down still has one. The
    /// child's is where the shell is standing, and it is the one a reader
    /// that OPENS something must use: a session running anything that has
    /// `cd`d reports that command's directory as the foreground one, and
    /// a pane placed from that lands in a build script's scratch space.
    ///
    /// Both, rather than a choice made here, because the holder is not
    /// the party that knows which question is being asked. It costs one
    /// more read of a pid it already has.
    fn replyStatus(self: *Holder, fd: sys.fd_t) !void {
        const state = self.childState();
        var cwd_buf: [1024]u8 = undefined;
        var cmd_buf: [256]u8 = undefined;
        var shell_cwd_buf: [1024]u8 = undefined;
        var scratch_cmd: [256]u8 = undefined;
        var info = sys.ProcInfo{ .cwd = "", .command = "" };
        var shell = sys.ProcInfo{ .cwd = "", .command = "" };
        if (!state.exited) {
            const pgrp = sys.foregroundGroup(&self.pty);
            if (pgrp > 0) info = sys.procInfo(pgrp, &cwd_buf, &cmd_buf);
            // THE CHILD IS THE SHELL, and the holder spawned it — so this
            // needs no walk and no guess about which process is which.
            if (self.child_pid > 0) shell = sys.procInfo(self.child_pid, &shell_cwd_buf, &scratch_cmd);
        }
        var payload: [2 + 2 + 1024 + 2 + 256 + 2 + 1024 + 1 + 8 + 2 + label_max + 2 + label_max]u8 = undefined;
        payload[0] = if (self.hasClient()) 1 else 0;
        payload[1] = if (state.exited) 1 else 0;
        var at: usize = 2;
        std.mem.writeInt(u16, payload[at..][0..2], @intCast(info.cwd.len), .little);
        at += 2;
        @memcpy(payload[at..][0..info.cwd.len], info.cwd);
        at += info.cwd.len;
        std.mem.writeInt(u16, payload[at..][0..2], @intCast(info.command.len), .little);
        at += 2;
        @memcpy(payload[at..][0..info.command.len], info.command);
        at += info.command.len;
        std.mem.writeInt(u16, payload[at..][0..2], @intCast(shell.cwd.len), .little);
        at += 2;
        @memcpy(payload[at..][0..shell.cwd.len], shell.cwd);
        at += shell.cwd.len;
        self.mutex.lock(io_mod.get()) catch {};
        const ever = self.ever_attached;
        self.mutex.unlock(io_mod.get());
        payload[at] = if (ever) 1 else 0;
        at += 1;
        std.mem.writeInt(u64, payload[at..][0..8], self.unattachedFor(), .little);
        at += 8;
        // WHO, AND WHAT IT IS CALLED ([[RFC-0014]] C-CLIENT-LABEL,
        // C-SESSION-NAME) — trailing, so an older reader stops before
        // them and loses nothing it knew how to read.
        self.mutex.lock(io_mod.get()) catch {};
        const label_len: usize = self.client_label_len;
        const name_len: usize = self.name_len;
        std.mem.writeInt(u16, payload[at..][0..2], @intCast(label_len), .little);
        at += 2;
        @memcpy(payload[at..][0..label_len], self.client_label_buf[0..label_len]);
        at += label_len;
        std.mem.writeInt(u16, payload[at..][0..2], @intCast(name_len), .little);
        at += 2;
        @memcpy(payload[at..][0..name_len], self.name_buf[0..name_len]);
        at += name_len;
        self.mutex.unlock(io_mod.get());
        try writeFrame(fd, .status, payload[0..at]);
    }

    /// Keep the name and write it beside the record, so `sessions` lists
    /// it even when this holder cannot be reached ([[RFC-0014]]
    /// C-SESSION-NAME). The last one given wins.
    fn setName(self: *Holder, given: []const u8) void {
        const kept: usize = @min(given.len, label_max);
        self.mutex.lock(io_mod.get()) catch return;
        @memcpy(self.name_buf[0..kept], given[0..kept]);
        self.name_len = @intCast(kept);
        self.mutex.unlock(io_mod.get());
        // Guarded on the claim: a holder that never took one has no
        // session to describe.
        if (self.record_fd != null) Record.rewrite(self.name(), given[0..kept]);
    }

    fn resizeScreen(self: *Holder, rows: u16, cols: u16) void {
        self.mutex.lock(io_mod.get()) catch return;
        defer self.mutex.unlock(io_mod.get());
        if (self.screen) |*sc| sc.resize(rows, cols);
    }

    /// Hand a client that holds nothing the screen as it stands.
    ///
    /// BEFORE ANY LIVE OUTPUT, and marked as its own kind of frame: a
    /// client has to be able to render this without treating it as work
    /// that just happened ([[RFC-0014]] C-RESTORE).
    fn sendRestoration(self: *Holder, fd: sys.fd_t, rows: u16, cols: u16) !void {
        self.mutex.lock(io_mod.get()) catch return;
        const has_screen = self.screen != null;
        var which: u8 = 0;
        var cur = Screen.Cursor{ .x = 0, .y = 0, .visible = true };
        var body: ?[]u8 = null;
        if (has_screen) {
            // IN THE GEOMETRY THE CLIENT ASKED FOR, CHECKED RATHER THAN
            // ASSUMED ([[RFC-0014]] C-RESTORE). The resize that precedes
            // this can fail — the lock it needs may not be taken, and the
            // terminal library's own answer is not read — and a paint of
            // the wrong shape is not a smaller mistake than no paint: its
            // rows beyond the old height are never addressed, so a client
            // taller than the model is handed a description of a screen
            // it does not have. Silently. This is the one place that can
            // still tell.
            const have = self.screen.?.size();
            if (have.rows != rows or have.cols != cols) {
                self.screen.?.resize(rows, cols);
                const now = self.screen.?.size();
                if (now.rows != rows or now.cols != cols) {
                    log.err("restoration geometry is {d}x{d}, client asked for {d}x{d} — the paint will describe a screen the client does not have", .{ now.rows, now.cols, rows, cols });
                }
            }
            which = self.screen.?.activeScreen();
            cur = self.screen.?.cursor();
            body = self.screen.?.repaint(self.allocator) catch null;
        }
        self.mutex.unlock(io_mod.get());
        const vt_bytes = body orelse return;
        defer self.allocator.free(vt_bytes);

        const header = 10;
        const payload = try self.allocator.alloc(u8, header + vt_bytes.len);
        defer self.allocator.free(payload);
        payload[0] = which;
        std.mem.writeInt(u16, payload[1..3], rows, .little);
        std.mem.writeInt(u16, payload[3..5], cols, .little);
        std.mem.writeInt(u16, payload[5..7], cur.y, .little);
        std.mem.writeInt(u16, payload[7..9], cur.x, .little);
        payload[9] = if (cur.visible) 1 else 0;
        @memcpy(payload[header..], vt_bytes);
        try writeFrame(fd, .restore, payload);
    }

    /// What can be done with the position a client presented.
    fn judgePosition(self: *Holder, incarnation: u64, offset: u64, from: *u64) ResumeAnswer {
        self.mutex.lock(io_mod.get()) catch return .unavailable;
        defer self.mutex.unlock(io_mod.get());
        // A POSITION FROM ANOTHER LIFETIME IS NOT OLD, IT IS FOREIGN.
        // Resolving it against this holder's stream would produce bytes
        // from an unrelated session rendered as the continuation of the
        // human's own.
        if (incarnation != self.incarnation) return .unavailable;
        if (!self.retained.has(offset)) return .unavailable;
        from.* = offset;
        return .resumed;
    }

    fn streamPosition(self: *Holder) u64 {
        self.mutex.lock(io_mod.get()) catch return 0;
        defer self.mutex.unlock(io_mod.get());
        return self.retained.total;
    }

    /// Client input -> the child, for as long as this client is the one.
    fn clientLoop(self: *Holder, fd: sys.fd_t, gen: u64, entry: ClientEntry) void {
        if (entry.catch_up_from) |from| {
            self.catchUp(fd, gen, from);
            // The backlog was written in the geometry it was produced in;
            // the client's own size applies now, once
            // ([[RFC-0014]] C-RESUME, C-SIZE).
            if (self.isCurrent(gen)) {
                sys.setWinsize(&self.pty, .{ .ws_row = entry.rows, .ws_col = entry.cols }) catch {};
                self.resizeScreen(entry.rows, entry.cols);
            }
        }
        var buf: [8192]u8 = undefined;
        while (self.isRunning()) {
            const frame = (readFrame(fd, &buf) catch break) orelse break;
            // DISPLACED CLIENTS DO NOT TYPE. A frame already in flight
            // when this client lost the session belongs to a human who
            // was looking at a window that is no longer the session's.
            if (!self.isCurrent(gen)) break;
            switch (frame.kind) {
                .input => sys.writeAll(self.pty.master, frame.payload) catch break,
                .resize => {
                    if (frame.payload.len < 4) continue;
                    const rows = std.mem.readInt(u16, frame.payload[0..2], .little);
                    const cols = std.mem.readInt(u16, frame.payload[2..4], .little);
                    sys.setWinsize(&self.pty, .{ .ws_row = rows, .ws_col = cols }) catch {};
                    // The model follows the terminal it models, or the
                    // next cold attach describes a shape the child has
                    // not been in for hours.
                    self.resizeScreen(rows, cols);
                },
                else => {},
            }
        }
        // Detaching is what losing a connection means; the child is not
        // told and is not stopped ([[RFC-0014]] C-DETACH).
        self.detachClient(fd);
        self.closeClientFd(fd);
    }

    /// Feed a returning client everything it missed, then let the pump
    /// take over.
    ///
    /// THE LOCK IS NOT HELD ACROSS THE WRITE. A megabyte into a socket
    /// while the pump waits to append is the child stalled behind its own
    /// audience, which is the failure [[RFC-0014]] C-STALLED-CLIENT
    /// forbids arriving from a slow client and would be worse arriving
    /// from a returning one.
    fn catchUp(self: *Holder, fd: sys.fd_t, gen: u64, from: u64) void {
        var at = from;
        var buf: [16384]u8 = undefined;
        while (self.isCurrent(gen)) {
            self.mutex.lock(io_mod.get()) catch return;
            if (!self.retained.has(at)) {
                // THE CHILD OUTRAN THE CATCH-UP. Said, never silent: the
                // client's scrollback has a hole and it is the only party
                // that can render that honestly.
                const live = self.retained.total;
                self.catching_up = false;
                self.mutex.unlock(io_mod.get());
                var payload: [8]u8 = undefined;
                std.mem.writeInt(u64, &payload, live, .little);
                writeFrame(fd, .gap, &payload) catch {};
                return;
            }
            const n = self.retained.copyOut(at, &buf);
            if (n == 0) {
                // Caught up. Clearing the flag under the SAME lock that
                // guards the ring is what makes the handover seamless:
                // the next byte the child writes goes straight out, and
                // none can slip between these two facts.
                self.catching_up = false;
                self.mutex.unlock(io_mod.get());
                return;
            }
            self.mutex.unlock(io_mod.get());
            writeFrame(fd, .data, buf[0..n]) catch {
                self.detachClient(fd);
                sys.shutdown(fd, sys.SHUT.RDWR);
                self.mutex.lock(io_mod.get()) catch return;
                self.catching_up = false;
                self.mutex.unlock(io_mod.get());
                return;
            };
            at += n;
        }
    }

    /// HOW LONG NOBODY HAS BEEN HERE, in milliseconds — zero while a
    /// client is attached, which is the answer [[RFC-0014]] C-END wants
    /// reported alongside whether anybody ever was.
    fn unattachedFor(self: *Holder) u64 {
        self.mutex.lock(io_mod.get()) catch return 0;
        defer self.mutex.unlock(io_mod.get());
        if (self.client != null) return 0;
        const since = self.unattached_since;
        if (since == 0) return 0;
        const elapsed = sys.nowMillis() - since;
        return if (elapsed > 0) @intCast(elapsed) else 0;
    }

    fn childExitLoop(self: *Holder) void {
        var status: c_int = 0;
        while (self.isRunning()) {
            const r = std.c.waitpid(self.child_pid, &status, 1); // WNOHANG
            if (r == self.child_pid) {
                var payload: [2]u8 = undefined;
                self.mutex.lock(io_mod.get()) catch return;
                self.child.exited = true;
                // The low seven bits carry a signal; a zero there means
                // the next byte up is an ordinary exit code.
                const sig: u8 = @intCast(status & 0x7f);
                if (sig != 0) {
                    self.child.by_signal = true;
                    self.child.value = sig;
                } else {
                    self.child.by_signal = false;
                    self.child.value = @intCast((status >> 8) & 0xff);
                }
                payload[0] = if (self.child.by_signal) 1 else 0;
                payload[1] = self.child.value;
                self.mutex.unlock(io_mod.get());
                self.deliver(.exit, &payload);
                return;
            }
            _ = sleepMs(10);
        }
    }

    // -----------------------------------------------------------------
    // Client slot
    // -----------------------------------------------------------------

    /// Take the session, telling whoever had it that they lost it.
    fn attach(self: *Holder, fd: sys.fd_t, catching_up: bool, label: []const u8) u64 {
        self.mutex.lock(io_mod.get()) catch return 0;
        const previous = self.client;
        // The displaced notice below is a write to `previous`, counted like
        // every other so its fd is not closed under it
        // ([[WI-2026-09-02-016]], [[WI-2026-09-02-033]]).
        if (previous != null) self.writes_in_flight += 1;
        self.ever_attached = true;
        self.client = fd;
        self.catching_up = catching_up;
        self.generation += 1;
        const gen = self.generation;
        const kept: usize = @min(label.len, label_max);
        @memcpy(self.client_label_buf[0..kept], label[0..kept]);
        self.client_label_len = @intCast(kept);
        self.mutex.unlock(io_mod.get());

        if (previous) |old| {
            // SAID, NOT INFERRED ([[RFC-0014]] C-ONE-CLIENT). A client
            // that is simply cut off cannot tell displacement from a
            // network fault, and the two call for opposite behaviour.
            // TOLD BY WHOM ([[RFC-0014]] C-ONE-CLIENT, C-CLIENT-LABEL):
            // the notice carries the newcomer's label, empty if it gave
            // none, so the displaced side's human reads "taken by the
            // CLI on deskmac" and not merely "taken".
            writeFrame(old, .displaced, label[0..kept]) catch {};
            sys.shutdown(old, sys.SHUT.RDWR);
            self.endWrite();
        }
        return gen;
    }

    fn isCurrent(self: *Holder, gen: u64) bool {
        self.mutex.lock(io_mod.get()) catch return false;
        defer self.mutex.unlock(io_mod.get());
        return self.generation == gen;
    }

    /// Clear the slot if `fd` still holds it. Passing null clears
    /// whatever is there.
    fn detachClient(self: *Holder, fd: ?sys.fd_t) void {
        self.mutex.lock(io_mod.get()) catch return;
        defer self.mutex.unlock(io_mod.get());
        if (self.client) |current| {
            if (fd == null or current == fd.?) {
                self.client = null;
                // THE CLOCK THE POLICY READS STARTS HERE, not at the next
                // time somebody asks. A holder that computed "how long
                // unattended" from the moment of the question would
                // answer zero to every question.
                self.unattached_since = sys.nowMillis();
            }
        }
    }

    fn deliver(self: *Holder, kind: Frame, payload: []const u8) void {
        self.mutex.lock(io_mod.get()) catch return;
        const counted = self.beginWriteLocked();
        self.mutex.unlock(io_mod.get());
        const target = counted orelse return;
        defer self.endWrite();
        writeFrame(target, kind, payload) catch {
            // A write that fails or times out is a client that is gone or
            // wedged. Either way the session is no longer being watched,
            // and the child must not wait for it.
            self.detachClient(target);
            sys.shutdown(target, sys.SHUT.RDWR);
        };
    }
};

fn mintIncarnation() u64 {
    var seed: u64 = @bitCast(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());
    seed ^= @as(u64, @intCast(std.c.getpid())) *% 0x9E3779B97F4A7C15;
    var prng = std.Random.DefaultPrng.init(seed);
    // NEVER ZERO: an all-zero position in a hello means "no position"
    // ([[RFC-0014]] C-CLIENT-LABEL), so zero is not an incarnation.
    return prng.random().int(u64) | 1;
}

fn sleepMs(ms: u64) bool {
    io_mod.get().sleep(std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests ([[WI-2026-08-17-003]])
//
// Every one of these drives the holder through the socket, as a client
// does. Nothing reaches into its internals to make an assertion that a
// real client could not make for itself.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A GITHUB RUNNER IS SLOWER THAN ANY MACHINE THIS WAS WRITTEN ON, and the
/// tests below pace themselves with bounds and fixed pauses that a fast
/// machine never notices. On Actions every one of them is stretched
/// fivefold; a passing run on a fast machine is not slowed at all by the
/// bounds and only slightly by the pauses ([[WI-2026-09-02-038]]).
fn testSlack() u64 {
    return if (sys.getenv("GITHUB_ACTIONS") != null) 5 else 1;
}

const TestClient = struct {
    fd: sys.fd_t,
    /// What the client knows about the stream — exactly what a real one
    /// keeps, so the tests cannot cheat by reading the holder's own.
    incarnation: u64 = 0,
    position: u64 = 0,
    answer: ResumeAnswer = .fresh,
    retention: u64 = 0,

    fn connect(path: []const u8, rows: u16, cols: u16) !TestClient {
        return connectFrom(path, rows, cols, null, 0);
    }

    fn connectResuming(path: []const u8, rows: u16, cols: u16, prev: *const TestClient) !TestClient {
        return connectFrom(path, rows, cols, prev.incarnation, prev.position);
    }

    /// A hello that says who it is: zero position, then the label.
    fn connectLabelled(path: []const u8, rows: u16, cols: u16, label: []const u8) !TestClient {
        var tries: usize = 0;
        const fd = while (true) : (tries += 1) {
            break socketCall(path, .connect) catch |err| {
                if (tries > 200) return err;
                _ = sleepMs(5);
                continue;
            };
        } else unreachable;
        errdefer sys.close(fd);
        var hello: [22 + label_max]u8 = [_]u8{0} ** (22 + label_max);
        hello[0] = protocol_version;
        std.mem.writeInt(u16, hello[1..3], rows, .little);
        std.mem.writeInt(u16, hello[3..5], cols, .little);
        hello[21] = @intCast(label.len);
        @memcpy(hello[22 .. 22 + label.len], label);
        try writeFrame(fd, .hello, hello[0 .. 22 + label.len]);
        var buf: [64]u8 = undefined;
        const welcome = (try readFrame(fd, &buf)) orelse return error.Closed;
        if (welcome.kind != .welcome or welcome.payload.len < 26) return error.Closed;
        return .{
            .fd = fd,
            .answer = @enumFromInt(welcome.payload[1]),
            .incarnation = std.mem.readInt(u64, welcome.payload[2..10], .little),
            .position = std.mem.readInt(u64, welcome.payload[10..18], .little),
            .retention = std.mem.readInt(u64, welcome.payload[18..26], .little),
        };
    }

    fn connectFrom(path: []const u8, rows: u16, cols: u16, incarnation: ?u64, position: u64) !TestClient {
        // The listener may not have reached accept() yet.
        var tries: usize = 0;
        const fd = while (true) : (tries += 1) {
            break socketCall(path, .connect) catch |err| {
                if (tries > 200) return err;
                _ = sleepMs(5);
                continue;
            };
        } else unreachable;
        errdefer sys.close(fd);
        var hello: [21]u8 = undefined;
        hello[0] = protocol_version;
        std.mem.writeInt(u16, hello[1..3], rows, .little);
        std.mem.writeInt(u16, hello[3..5], cols, .little);
        var hello_len: usize = 5;
        if (incarnation) |inc| {
            std.mem.writeInt(u64, hello[5..13], inc, .little);
            std.mem.writeInt(u64, hello[13..21], position, .little);
            hello_len = 21;
        }
        try writeFrame(fd, .hello, hello[0..hello_len]);
        var buf: [64]u8 = undefined;
        const welcome = (try readFrame(fd, &buf)) orelse return error.Closed;
        if (welcome.kind != .welcome or welcome.payload.len < 26) return error.Closed;
        return .{
            .fd = fd,
            .answer = @enumFromInt(welcome.payload[1]),
            .incarnation = std.mem.readInt(u64, welcome.payload[2..10], .little),
            .position = std.mem.readInt(u64, welcome.payload[10..18], .little),
            .retention = std.mem.readInt(u64, welcome.payload[18..26], .little),
        };
    }

    fn close(self: *TestClient) void {
        sys.close(self.fd);
    }

    fn send(self: *TestClient, text: []const u8) !void {
        try writeFrame(self.fd, .input, text);
    }

    fn resize(self: *TestClient, rows: u16, cols: u16) !void {
        var p: [4]u8 = undefined;
        std.mem.writeInt(u16, p[0..2], rows, .little);
        std.mem.writeInt(u16, p[2..4], cols, .little);
        try writeFrame(self.fd, .resize, &p);
    }

    /// Collect DATA until `needle` shows up, or the deadline passes.
    /// Returns everything seen, so a failure can say what did arrive.
    fn expect(self: *TestClient, out: []u8, needle: []const u8, ms: u64) ![]const u8 {
        sys.setRecvTimeout(self.fd, 200) catch {};
        var total: usize = 0;
        var waited: u64 = 0;
        var buf: [8192]u8 = undefined;
        while (waited < ms * testSlack()) {
            const frame = readFrame(self.fd, &buf) catch {
                waited += 200;
                continue;
            } orelse break;
            if (frame.kind == .data) {
                // A CLIENT'S POSITION IS ITS OWN ARITHMETIC: what it had,
                // plus what it has been given. Nothing tells it this
                // number ([[RFC-0014]] C-RESUME).
                self.position += frame.payload.len;
                const room = @min(frame.payload.len, out.len - total);
                @memcpy(out[total .. total + room], frame.payload[0..room]);
                total += room;
                if (std.mem.indexOf(u8, out[0..total], needle) != null) return out[0..total];
            }
        }
        return out[0..total];
    }

    /// The restoration this client was given, if any: which screen, its
    /// dimensions, and the sequences that reproduce it.
    fn awaitRestoration(self: *TestClient, out: []u8, ms: u64) !struct {
        which: u8,
        rows: u16,
        cols: u16,
        cursor_row: u16,
        cursor_col: u16,
        cursor_visible: bool,
        body: []const u8,
    } {
        sys.setRecvTimeout(self.fd, 200) catch {};
        var waited: u64 = 0;
        while (waited < ms) {
            const frame = readFrame(self.fd, out) catch {
                waited += 200;
                continue;
            } orelse return error.Closed;
            if (frame.kind == .restore) {
                if (frame.payload.len < 10) return error.Closed;
                return .{
                    .which = frame.payload[0],
                    .rows = std.mem.readInt(u16, frame.payload[1..3], .little),
                    .cols = std.mem.readInt(u16, frame.payload[3..5], .little),
                    .cursor_row = std.mem.readInt(u16, frame.payload[5..7], .little),
                    .cursor_col = std.mem.readInt(u16, frame.payload[7..9], .little),
                    .cursor_visible = frame.payload[9] == 1,
                    .body = frame.payload[10..],
                };
            }
        }
        return error.NotSeen;
    }

    /// Wait for one frame of a given kind.
    fn expectFrame(self: *TestClient, kind: Frame, payload_out: []u8, ms: u64) !usize {
        sys.setRecvTimeout(self.fd, 200) catch {};
        var waited: u64 = 0;
        var buf: [8192]u8 = undefined;
        while (waited < ms * testSlack()) {
            const frame = readFrame(self.fd, &buf) catch {
                waited += 200;
                continue;
            } orelse return error.Closed;
            if (frame.kind == kind) {
                const n = @min(frame.payload.len, payload_out.len);
                @memcpy(payload_out[0..n], frame.payload[0..n]);
                return n;
            }
        }
        return error.NotSeen;
    }
};

fn testSocketPath(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/tmp/synapty-holder-{s}-{d}.sock", .{ name, std.c.getpid() });
}

/// A shell that answers every line, so a test can prove a keystroke
/// arrived rather than merely that the terminal echoed it.
const echo_shell: []const [*:0]const u8 = &.{ "/bin/sh", "-c", "while read l; do printf 'GOT[%s]\\n' \"$l\"; done" };

test "RFC-0014: a session socket opens at a path longer than the kernel's bound" {
    // `sun_path[104]` IS AN ABI CONSTANT with no switch to turn, and this
    // application's own UI harness produces a longer path than that: the
    // test runner is containerised, so its temporary directory is 63
    // bytes before anything of ours, and every terminal pane in that
    // harness died with a Zig stack trace printed into it — while the
    // suite went on passing, because nothing there asserts on terminal
    // CONTENT.
    //
    // WHAT THE KERNEL BOUNDS IS THE STRING IT IS HANDED, not where the
    // socket lives. A path that does not fit is handed over as a BASENAME
    // from inside its own directory. This drives the whole thing: the
    // bound is real, then bind, connect, and a byte through the pair.
    const root = "/tmp/synapty-deep-" ++ ("x" ** 60);
    const deep = root ++ "/machine/sessions";
    makeSessionsDir(deep);
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), root) catch {};

    var buf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/local-1a2b.sock", .{deep});
    try std.testing.expect(path.len >= sys.max_unix_path);
    // Handed whole, the kernel refuses it — which is the defect's cause.
    try std.testing.expect(sys.sockaddr_un.init(path) == null);

    sys.unlink(path);
    const listener = try socketCall(path, .bind);
    defer sys.close(listener);
    try sys.listen(listener, 4);

    const client = try socketCall(path, .connect);
    defer sys.close(client);

    // AND THE WORKING DIRECTORY IS BACK. `chdir` is process-global, so a
    // call that left it moved would send every later relative path in
    // this process somewhere else.
    var cwd_buf: [1024]u8 = undefined;
    const now = try sys.getcwd(&cwd_buf);
    try std.testing.expect(!std.mem.startsWith(u8, now, root));
}

test "output from the child reaches the attached client" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "out");
    var h = try Holder.init(testing.allocator, path);
    // THE CHILD SPEAKS ONLY WHEN SPOKEN TO. A fresh client is attached at
    // the stream's CURRENT position and is shown anything earlier as a
    // restoration, not as data ([[RFC-0014]] C-RESUME, C-RESTORE) — so a
    // child that printed the moment it started raced the connect, and on
    // a slow runner the line was on the screen before there was a client
    // to stream it to. Gated on a keystroke, the output is caused by the
    // attached client and can only arrive as data.
    try h.start(&.{ "/bin/sh", "-c", "read go; printf 'HELLO_FROM_CHILD\\n'; sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    try c.send("\r");
    var out: [4096]u8 = undefined;
    const seen = try c.expect(&out, "HELLO_FROM_CHILD", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "HELLO_FROM_CHILD") != null);
}

test "a client's keystrokes reach the child" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "in");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    _ = sleepMs(200 * testSlack());
    try c.send("ping\r");
    var out: [4096]u8 = undefined;
    const seen = try c.expect(&out, "GOT[ping]", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[ping]") != null);
}

test "the child outlives the client, and the next client finds it running" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "outlive");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    _ = sleepMs(200 * testSlack());
    try first.send("before\r");
    var out: [4096]u8 = undefined;
    _ = try first.expect(&out, "GOT[before]", 3000);
    first.close();

    // Nobody attached. The child must still be here.
    _ = sleepMs(300 * testSlack());
    try testing.expect(!h.childState().exited);

    var second = try TestClient.connect(path, 24, 80);
    defer second.close();
    _ = sleepMs(200 * testSlack());
    try second.send("after\r");
    var out2: [4096]u8 = undefined;
    const seen = try second.expect(&out2, "GOT[after]", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[after]") != null);
    try testing.expect(!h.childState().exited);
}

test "a second client displaces the first, and the first is told so" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "displace");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    defer first.close();
    _ = sleepMs(100 * testSlack());
    var second = try TestClient.connect(path, 24, 80);
    defer second.close();

    var payload: [8]u8 = undefined;
    _ = try first.expectFrame(.displaced, &payload, 3000);

    // And the session is the second client's: it, not the first, sees
    // what the child says.
    _ = sleepMs(200 * testSlack());
    try second.send("mine\r");
    var out: [4096]u8 = undefined;
    const seen = try second.expect(&out, "GOT[mine]", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[mine]") != null);
}

test "the displaced client is told who took the seat, and status says who sits in it (RFC-0014 C-CLIENT-LABEL)" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "labelled");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connectLabelled(path, 24, 80, "gui@deskmac:41");
    defer first.close();
    _ = sleepMs(100 * testSlack());
    try testing.expectEqual(ResumeAnswer.fresh, first.answer);

    var scratch: StatusBuffers = .{};
    const seated = queryStatusInto(path, &scratch) orelse return error.NoStatus;
    try testing.expect(seated.attached);
    try testing.expectEqualStrings("gui@deskmac:41", seated.client_label);

    var second = try TestClient.connectLabelled(path, 24, 80, "cli@laptop:77");
    defer second.close();
    var payload: [128]u8 = undefined;
    const said = try first.expectFrame(.displaced, &payload, 3000);
    try testing.expectEqualStrings("cli@laptop:77", payload[0..said]);

    var scratch2: StatusBuffers = .{};
    const now = queryStatusInto(path, &scratch2) orelse return error.NoStatus;
    try testing.expectEqualStrings("cli@laptop:77", now.client_label);
}

test "an unlabelled hello still attaches and is reported as unlabelled" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "unlabelled");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }
    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    _ = sleepMs(100 * testSlack());
    var scratch: StatusBuffers = .{};
    const s = queryStatusInto(path, &scratch) orelse return error.NoStatus;
    try testing.expect(s.attached);
    try testing.expectEqualStrings("", s.client_label);
}

test "a name given is kept and reported in status (RFC-0014 C-SESSION-NAME)" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "named");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }
    try testing.expect(requestName(path, "the deploy one"));
    var scratch: StatusBuffers = .{};
    const s = queryStatusInto(path, &scratch) orelse return error.NoStatus;
    try testing.expectEqualStrings("the deploy one", s.session_name);
    try testing.expect(!s.attached);
    try testing.expect(requestName(path, "renamed \"twice\""));
    var scratch2: StatusBuffers = .{};
    const again = queryStatusInto(path, &scratch2) orelse return error.NoStatus;
    try testing.expectEqualStrings("renamed \"twice\"", again.session_name);
}

test "a displaced client's input does not reach the child" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "ghost-input");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    defer first.close();
    _ = sleepMs(100 * testSlack());
    var second = try TestClient.connect(path, 24, 80);
    defer second.close();
    _ = sleepMs(200 * testSlack());

    // The displaced client types. Its bytes must go nowhere.
    first.send("ghost\r") catch {};
    _ = sleepMs(400 * testSlack());
    // Then the live client types, and sees only its own line answered.
    try second.send("live\r");
    var out: [8192]u8 = undefined;
    const seen = try second.expect(&out, "GOT[live]", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[live]") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[ghost]") == null);
}

test "the attached client sets the size, and detaching does not change it" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "size");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "while read l; do stty size; done" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    _ = sleepMs(200 * testSlack());
    try c.resize(43, 117);
    _ = sleepMs(100 * testSlack());
    try c.send("\r");
    var out: [4096]u8 = undefined;
    const seen = try c.expect(&out, "43 117", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "43 117") != null);
    c.close();

    // Nobody attached: the size the child has is the size it was left
    // with ([[RFC-0014]] C-SIZE).
    _ = sleepMs(300 * testSlack());
    const ws = try sys.getWinsize(&h.pty);
    try testing.expectEqual(@as(u16, 43), ws.ws_row);
    try testing.expectEqual(@as(u16, 117), ws.ws_col);
}

test "the child's exit is reported with its code" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "exit-code");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 0.2; exit 7" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer h.stop();

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    var payload: [8]u8 = undefined;
    const n = try c.expectFrame(.exit, &payload, 5000);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0), payload[0]); // not a signal
    try testing.expectEqual(@as(u8, 7), payload[1]);

    const state = h.childState();
    try testing.expect(state.exited);
    try testing.expect(!state.by_signal);
    try testing.expectEqual(@as(u8, 7), state.value);
}

test "a child killed by a signal is reported as killed, not as an exit code" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "exit-signal");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer h.stop();

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    _ = sleepMs(200 * testSlack());
    _ = std.c.kill(h.child_pid, @enumFromInt(9));

    var payload: [8]u8 = undefined;
    const n = try c.expectFrame(.exit, &payload, 5000);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 1), payload[0]); // by signal
    try testing.expectEqual(@as(u8, 9), payload[1]);
}

test "the session socket is owner-only" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "perm");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    // No bits for group or other ([[RFC-0014]] C-ENTITLEMENT).
    const mode = try sys.fileMode(path);
    try testing.expectEqual(@as(u16, 0), mode & 0o077);
}

test "the directory holding sessions is owner-only, and so is a record" {
    // ITS OWN ROOT, because the test's subject is the state directory
    // and the human's is not a fixture.
    var root: [128]u8 = undefined;
    const r = try std.fmt.bufPrint(&root, "/tmp/synapty-perm-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io_mod.get(), r) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), r) catch {};
    paths.root_override = r;
    defer paths.root_override = null;

    const name = "perm-record";
    const held = Record.write(name);
    defer if (held) |fd| sys.close(fd);
    defer Record.remove(name);

    var dbuf: [1024]u8 = undefined;
    const dir = paths.sessionsDir(&dbuf) orelse return error.NoStateDirectory;
    // A DIRECTORY ANY ACCOUNT MAY ENTER is a listing of every session
    // this human is running: the names, the pids, how long each has been
    // up. That is the existence, name and state C-ENTITLEMENT forbids
    // revealing, and it was 0755 because nothing said otherwise.
    try testing.expectEqual(@as(u16, 0), (try sys.fileMode(dir)) & 0o077);

    var rbuf: [1024]u8 = undefined;
    const rec = Record.pathFor(&rbuf, name) orelse return error.NoStateDirectory;
    try testing.expectEqual(@as(u16, 0), (try sys.fileMode(rec)) & 0o077);
}

test "a record whose process is gone is swept, not kept" {
    var root: [128]u8 = undefined;
    const r = try std.fmt.bufPrint(&root, "/tmp/synapty-tomb-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io_mod.get(), r) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), r) catch {};
    paths.root_override = r;
    defer paths.root_override = null;

    // A LIVE ONE IS LEFT ALONE. This is the whole of [[RFC-0014]] C-END:
    // whatever else a listing does, it does not end a session.
    const claim = Record.write("still-here");
    defer if (claim) |fd| sys.close(fd);
    defer Record.remove("still-here");
    try testing.expect(claim != null);
    try testing.expect(!sweepEnded(testing.allocator, "still-here"));
    try testing.expect(Record.read(testing.allocator, "still-here") != null);

    // A PID IS A NUMBER, NOT AN IDENTITY. This record names a process
    // that is unquestionably running — this one — and yet its holder is
    // gone, which is exactly what a reused pid looks like. `kill(pid, 0)`
    // cannot tell the two apart; the claim its owner held can.
    try writeRecordForTest("pid-reused", std.c.getpid());
    try testing.expect(sweepEnded(testing.allocator, "pid-reused"));
    try testing.expect(Record.read(testing.allocator, "pid-reused") == null);

    // AND A TOMBSTONE GOES. The pid is one no machine has running, so the
    // kernel answers ESRCH — the same answer it gives for a holder that
    // was killed and for one a reboot took with it.
    try writeRecordForTest("long-gone", 0x7FFF_FFFF);
    var sbuf: [1024]u8 = undefined;
    const sock = try socketPath(&sbuf, "long-gone");
    (try std.Io.Dir.cwd().createFile(io_mod.get(), sock, .{})).close(io_mod.get());
    try testing.expect(sweepEnded(testing.allocator, "long-gone"));
    try testing.expect(Record.read(testing.allocator, "long-gone") == null);
    // THE SOCKET GOES WITH IT: nothing is listening on it, so it is a
    // path no client can reach and no `end` can use.
    try testing.expectError(error.FileNotFound,
        std.Io.Dir.cwd().openFile(io_mod.get(), sock, .{}));

    // Sweeping what is already swept is not an error, and is not a sweep.
    try testing.expect(!sweepEnded(testing.allocator, "long-gone"));

    // A SECOND HOLDER TAKING A LIVE NAME IS REFUSED, AND LEAVES THE
    // RECORD IT COULD NOT CLAIM EXACTLY AS IT FOUND IT.
    try testing.expect(Record.write("still-here") == null);
    const after = Record.read(testing.allocator, "still-here");
    try testing.expect(after != null);
    try testing.expectEqual(std.c.getpid(), after.?.pid);
    try testing.expect(!sweepEnded(testing.allocator, "still-here"));

    // A FILE THAT IS NOT A RECORD IS NOT A TOMBSTONE. Nothing here can
    // say its process is gone, so nothing here may delete it.
    var pbuf: [1024]u8 = undefined;
    const path = Record.pathFor(&pbuf, "not-json") orelse return error.NoStateDirectory;
    var file = try std.Io.Dir.cwd().createFile(io_mod.get(), path, .{});
    var w = file.writer(io_mod.get(), &.{});
    try w.interface.writeAll("half a wr");
    file.close(io_mod.get());
    try testing.expect(!sweepEnded(testing.allocator, "not-json"));
    var probe = try std.Io.Dir.cwd().openFile(io_mod.get(), path, .{});
    probe.close(io_mod.get());
}

test "a record replaced under a live holder is not a tombstone" {
    var root: [128]u8 = undefined;
    const r = try std.fmt.bufPrint(&root, "/tmp/synapty-inode-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io_mod.get(), r) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), r) catch {};
    paths.root_override = r;
    defer paths.root_override = null;

    const claim = Record.write("swapped");
    defer if (claim) |fd| sys.close(fd);
    defer Record.remove("swapped");
    try testing.expect(claim != null);
    try testing.expectEqual(Claim.held, claimState("swapped"));

    // WHAT AN ATOMIC WRITE DOES, and a rename, and a restore from a
    // backup: same bytes at the same path, a different inode. An flock
    // binds to the inode, so a claim left on the record file itself is
    // released by a write nobody thought of as destructive — and 49 live
    // sessions were swept out from under their holders that way
    // ([[WI-2026-09-03-009]]).
    {
        var pbuf: [1024]u8 = undefined;
        const path = Record.pathFor(&pbuf, "swapped").?;
        var tbuf: [1030]u8 = undefined;
        const temp = try std.fmt.bufPrintZ(&tbuf, "{s}.new", .{path});
        var body: [512]u8 = undefined;
        const n = blk: {
            var f = try std.Io.Dir.cwd().openFile(io_mod.get(), path, .{});
            defer f.close(io_mod.get());
            var rd = f.reader(io_mod.get(), &.{});
            break :blk rd.interface.readSliceShort(&body) catch 0;
        };
        {
            var f = try std.Io.Dir.cwd().createFile(io_mod.get(), temp, .{});
            defer f.close(io_mod.get());
            try f.writeStreamingAll(io_mod.get(), body[0..n]);
        }
        var oz: [1025]u8 = undefined;
        const pathz = try std.fmt.bufPrintZ(&oz, "{s}", .{path});
        try testing.expectEqual(@as(c_int, 0), std.c.rename(temp.ptr, pathz.ptr));
    }

    // The holder never moved, so neither did the answer.
    try testing.expectEqual(Claim.held, claimState("swapped"));
    try testing.expect(startWouldJoin("swapped"));
    try testing.expect(!sweepEnded(testing.allocator, "swapped"));
    try testing.expect(Record.read(testing.allocator, "swapped") != null);
}

/// A record naming a pid of the test's choosing. `Record.write` names the
/// process that calls it, which is by definition alive.
fn writeRecordForTest(name: []const u8, pid: i32) !void {
    var dir: [1024]u8 = undefined;
    if (paths.sessionsDir(&dir)) |d| makeSessionsDir(d);
    var buf: [1024]u8 = undefined;
    const path = Record.pathFor(&buf, name) orelse return error.NoStateDirectory;
    var body: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&body, "{{\"pid\":{d}}}\n", .{pid});
    {
        var file = try std.Io.Dir.cwd().createFile(io_mod.get(), path, .{});
        defer file.close(io_mod.get());
        var writer = file.writer(io_mod.get(), &.{});
        try writer.interface.writeAll(text);
    }
    // AND THE LOCK BESIDE IT, UNCLAIMED, because that is what a holder
    // that died leaves: both files there and nothing holding either. A
    // record with no lock is a different thing — a session still starting
    // — and reads `absent` rather than `free` ([[Record.write]]).
    var lbuf: [1024]u8 = undefined;
    const lock_path = Record.lockPathFor(&lbuf, name) orelse return error.NoStateDirectory;
    var lock = try std.Io.Dir.cwd().createFile(io_mod.get(), lock_path, .{});
    lock.close(io_mod.get());
}

test "the holder answers only its own account" {
    // WHAT CAN BE PUT TO A TEST AS ONE ACCOUNT: that the holder asks the
    // kernel at all, and that the answer it gets for its own client is
    // the uid it runs as. Refusing another account cannot be exercised
    // without being two accounts, and a test that pretended otherwise
    // would be checking its own stub.
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "peer");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    try testing.expectEqual(sys.selfUid(), try sys.peerUid(c.fd));
}

// ---------------------------------------------------------------------------
// Resumption ([[WI-2026-08-17-006]])
// ---------------------------------------------------------------------------

test "the ring answers by absolute offset, across a wrap" {
    var r = try Retained.init(testing.allocator, min_retention_bytes);
    defer r.deinit(testing.allocator);

    r.append("hello ");
    r.append("world");
    try testing.expectEqual(@as(u64, 11), r.total);
    var out: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), r.copyOut(6, &out));
    try testing.expectEqualStrings("world", out[0..5]);
    try testing.expectEqual(@as(usize, 11), r.copyOut(0, &out));

    // Push past the end so the buffer wraps; offsets keep meaning the
    // same thing, which a position into the buffer would not.
    const filler = try testing.allocator.alloc(u8, min_retention_bytes);
    defer testing.allocator.free(filler);
    @memset(filler, 'x');
    r.append(filler);
    try testing.expect(!r.has(0));
    try testing.expect(r.has(r.total));
    try testing.expectEqual(@as(usize, 0), r.copyOut(0, &out));
    try testing.expectEqual(@as(u64, min_retention_bytes + 11), r.total);
    try testing.expectEqual(@as(usize, 4), r.copyOut(r.total - 4, out[0..4]));
    try testing.expectEqualStrings("xxxx", out[0..4]);
}

test "a returning client is given exactly what it missed" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "resume");
    var h = try Holder.init(testing.allocator, path);
    // A shell that answers on demand, so the test decides exactly what is
    // produced while nobody is watching.
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    try testing.expectEqual(ResumeAnswer.fresh, first.answer);
    try testing.expect(first.retention >= min_retention_bytes);
    _ = sleepMs(200 * testSlack());
    try first.send("one\r");
    var out: [8192]u8 = undefined;
    _ = try first.expect(&out, "GOT[one]", 3000);
    const away_at = first.position;
    first.close();

    // The child keeps working with nobody attached. Typed through the
    // terminal itself, because there is no client to type it.
    _ = sleepMs(100 * testSlack());
    try sys.writeAll(h.pty.master, "two\r");
    _ = sleepMs(400 * testSlack());

    var second = try TestClient.connectResuming(path, 24, 80, &.{
        .fd = -1,
        .incarnation = first.incarnation,
        .position = away_at,
    });
    defer second.close();
    try testing.expectEqual(ResumeAnswer.resumed, second.answer);
    try testing.expectEqual(away_at, second.position);

    var out2: [8192]u8 = undefined;
    const seen = try second.expect(&out2, "GOT[two]", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[two]") != null);
    // AND NOTHING IT ALREADY HAD. The first client's line must not be
    // replayed into a scrollback that still holds it.
    try testing.expect(std.mem.indexOf(u8, seen, "GOT[one]") == null);
}

test "a position from another incarnation is refused, not resolved" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "foreign");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    _ = sleepMs(200 * testSlack());
    try c.send("here\r");
    var out: [8192]u8 = undefined;
    _ = try c.expect(&out, "GOT[here]", 3000);
    const position = c.position;
    const wrong_incarnation = c.incarnation ^ 0xdead_beef;
    c.close();

    var stranger = try TestClient.connectFrom(path, 24, 80, wrong_incarnation, position);
    defer stranger.close();
    try testing.expectEqual(ResumeAnswer.unavailable, stranger.answer);
    // Told where it actually is, rather than left believing the offset it
    // asked for.
    try testing.expect(stranger.position >= position);
}

test "a position older than what is retained is refused" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "expired");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var probe = try TestClient.connect(path, 24, 80);
    const incarnation = probe.incarnation;
    probe.close();

    // Push the window past an offset that was valid a moment ago.
    var filler: [4096]u8 = undefined;
    @memset(&filler, 'z');
    var pushed: usize = 0;
    while (pushed < min_retention_bytes + filler.len) : (pushed += filler.len) {
        h.mutex.lock(io_mod.get()) catch break;
        h.retained.append(&filler);
        h.mutex.unlock(io_mod.get());
    }

    var late = try TestClient.connectFrom(path, 24, 80, incarnation, 0);
    defer late.close();
    try testing.expectEqual(ResumeAnswer.unavailable, late.answer);
}

test "a resumed client is resized only after its backlog has been delivered" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "resize-order");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    const incarnation = first.incarnation;
    const away_at = first.position;
    first.close();

    // A BACKLOG BIG ENOUGH TO STILL BE ARRIVING. The assertion below is
    // made while the catch-up is in flight, and one frame's worth would
    // be delivered before a test could look.
    _ = sleepMs(100 * testSlack());
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 'b');
    var pushed: usize = 0;
    while (pushed < 512 * 1024) : (pushed += chunk.len) {
        h.mutex.lock(io_mod.get()) catch break;
        h.retained.append(&chunk);
        h.mutex.unlock(io_mod.get());
    }

    var second = try TestClient.connectFrom(path, 51, 131, incarnation, away_at);
    defer second.close();
    try testing.expectEqual(ResumeAnswer.resumed, second.answer);

    // The first backlog frame has arrived, so the client is plainly
    // attached and being served — and the child is STILL the size those
    // bytes were written at ([[RFC-0014]] C-RESUME).
    var one: [32768]u8 = undefined;
    sys.setRecvTimeout(second.fd, 2000) catch {};
    const frame = (try readFrame(second.fd, &one)) orelse return error.Closed;
    try testing.expectEqual(Frame.data, frame.kind);
    second.position += frame.payload.len;
    const during = try sys.getWinsize(&h.pty);
    try testing.expectEqual(@as(u16, 24), during.ws_row);
    try testing.expectEqual(@as(u16, 80), during.ws_col);

    // Drain the rest of the backlog. A client that stops reading is a
    // client being detached ([[RFC-0014]] C-STALLED-CLIENT), so the test
    // has to behave like one that is keeping up.
    const target = h.streamPosition();
    var frames: usize = 0;
    while (second.position < target and frames < 1000) : (frames += 1) {
        const f = (readFrame(second.fd, &one) catch break) orelse break;
        if (f.kind == .data) second.position += f.payload.len;
    }
    try testing.expect(second.position >= target);

    // Only now does the size the client asked for apply.
    var waited: u64 = 0;
    while (waited < 3000) : (waited += 50) {
        const now = try sys.getWinsize(&h.pty);
        if (now.ws_row == 51 and now.ws_col == 131) break;
        _ = sleepMs(50 * testSlack());
    }
    const after = try sys.getWinsize(&h.pty);
    try testing.expectEqual(@as(u16, 51), after.ws_row);
    try testing.expectEqual(@as(u16, 131), after.ws_col);
}

test "a catch-up the child outruns ends in a stated gap" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "gap");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var probe = try TestClient.connect(path, 24, 80);
    const incarnation = probe.incarnation;
    probe.close();
    _ = sleepMs(100 * testSlack());

    // Fill the window, so a resume from zero has a real backlog to walk.
    var chunk: [8192]u8 = undefined;
    @memset(&chunk, 'a');
    var pushed: usize = 0;
    while (pushed < min_retention_bytes) : (pushed += chunk.len) {
        h.mutex.lock(io_mod.get()) catch break;
        h.retained.append(&chunk);
        h.mutex.unlock(io_mod.get());
    }

    var late = try TestClient.connectFrom(path, 24, 80, incarnation, h.retained.earliest());
    defer late.close();
    try testing.expectEqual(ResumeAnswer.resumed, late.answer);

    // OVERRUN IT WHILE IT WALKS. A memcpy outruns a socket, which is the
    // point: the child can produce faster than a client consumes, and the
    // window it is being read from moves out from under it.
    var overrun: usize = 0;
    while (overrun < 4 * min_retention_bytes) : (overrun += chunk.len) {
        h.mutex.lock(io_mod.get()) catch break;
        h.retained.append(&chunk);
        h.mutex.unlock(io_mod.get());
    }

    // SAID, NOT SILENT ([[RFC-0014]] C-RESUME): the client is told where
    // live output resumes, so it can render the hole honestly rather than
    // joining two ends of a stream that are not adjacent.
    var payload: [16]u8 = undefined;
    const n = try late.expectFrame(.gap, &payload, 5000);
    try testing.expectEqual(@as(usize, 8), n);
    const live_at = std.mem.readInt(u64, payload[0..8], .little);
    try testing.expect(live_at > 0);
}

test "the terminal library is linked and answers" {
    var term: vt.GhosttyTerminal = undefined;
    try testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_new(null, &term, 80, 24));
    defer vt.ghostty_terminal_free(term);
}

// ---------------------------------------------------------------------------
// A restoration is a full-screen repaint ([[WI-2026-08-17-013]])
// ---------------------------------------------------------------------------

/// What a row of a screen SAYS — the only thing a repaint can be judged
/// against, because the sequences that produce it are not unique and the
/// rendering is.
fn rowText(screen: *Screen, buf: []u8, y: u16) ![]const u8 {
    const dim = screen.size();
    const start = screen.gridRef(0, y) orelse return error.ScreenUnavailable;
    const end = screen.gridRef(dim.cols - 1, y) orelse return error.ScreenUnavailable;

    var sel = std.mem.zeroes(vt.GhosttySelection);
    sel.size = @sizeOf(vt.GhosttySelection);
    sel.start = start;
    sel.end = end;

    var opts = std.mem.zeroes(vt.GhosttyTerminalSelectionFormatOptions);
    opts.size = @sizeOf(vt.GhosttyTerminalSelectionFormatOptions);
    opts.emit = vt.GHOSTTY_FORMATTER_FORMAT_PLAIN;
    opts.unwrap = false;
    opts.trim = true;
    opts.selection = &sel;

    var written: usize = 0;
    const result = vt.ghostty_terminal_selection_format_buf(
        screen.term,
        opts,
        buf.ptr,
        buf.len,
        &written,
    );
    if (result != vt.GHOSTTY_SUCCESS) return error.ScreenUnavailable;
    return buf[0..written];
}

/// Paint a repaint onto a terminal that is not where the session is —
/// which is the whole point: a client that has just cleared its screen
/// has its cursor at home, one that has not been cleared has it anywhere.
fn paintOnto(target: *Screen, body: []const u8, begin_at: []const u8) void {
    target.write(begin_at);
    target.write(body);
}

test "a repaint puts a row where the session has it, wherever the paint began" {
    var session = try Screen.init(24, 80);
    defer session.deinit();
    // Row ten, and nothing above it. A DESCRIPTION of this screen's
    // content is "hello" and nine blank lines are not in it; painted from
    // wherever the cursor happened to be, it lands at the top.
    session.write("\x1b[10;1Hhello");

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    // Three clients, three different places for the paint to begin: one
    // freshly cleared, one with the cursor left in the middle, one that
    // has been scrolled to the bottom by earlier work.
    for ([_][]const u8{ "", "\x1b[7;30H", "\x1b[24;1Hleftover" }) |began| {
        var client = try Screen.init(24, 80);
        defer client.deinit();
        paintOnto(&client, body, began);

        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("hello", try rowText(&client, &buf, 9));
        try testing.expectEqualStrings("", try rowText(&client, &buf, 0));
        // AND THE ROW THE PAINT BEGAN ON IS NOT SPARED. A repaint that
        // only writes the rows it has content for leaves the rest of the
        // pane showing the connection that died.
        try testing.expectEqualStrings("", try rowText(&client, &buf, 23));
    }
}

test "a repaint carries the cursor to where the session has it" {
    var session = try Screen.init(24, 80);
    defer session.deinit();
    session.write("\x1b[12;40Hxy");

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(24, 80);
    defer client.deinit();
    paintOnto(&client, body, "\x1b[3;3H");

    const cur = client.cursor();
    try testing.expectEqual(session.cursor().y, cur.y);
    try testing.expectEqual(session.cursor().x, cur.x);
    try testing.expect(cur.visible);
}

test "a repaint reproduces every row of the screen, not only the ones with something on them" {
    var session = try Screen.init(10, 40);
    defer session.deinit();
    session.write("\x1b[1;1Htop\x1b[5;1Hmiddle\x1b[10;1Hbottom");

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(10, 40);
    defer client.deinit();
    // The pane is not empty when the restoration arrives; it holds what
    // the connection that dropped left on it.
    paintOnto(&client, body, "\x1b[1;1Hstale\x1b[2;1Hstale\x1b[3;1Hstale");

    var buf: [256]u8 = undefined;
    var y: u16 = 0;
    while (y < 10) : (y += 1) {
        const expected: []const u8 = switch (y) {
            0 => "top",
            4 => "middle",
            9 => "bottom",
            else => "",
        };
        try testing.expectEqualStrings(expected, try rowText(&client, &buf, y));
    }
}

test "a repaint keeps a wrapped line on the two rows the session wraps it onto" {
    var session = try Screen.init(6, 10);
    defer session.deinit();
    // Twelve characters in ten columns: the session wraps them, and a
    // description that unwraps or re-wraps them puts the tail somewhere
    // the human did not leave it.
    session.write("abcdefghijkl");

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(6, 10);
    defer client.deinit();
    paintOnto(&client, body, "");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefghij", try rowText(&client, &buf, 0));
    try testing.expectEqualStrings("kl", try rowText(&client, &buf, 1));
}

test "a repaint of the alternate screen is painted onto the alternate screen" {
    var session = try Screen.init(12, 40);
    defer session.deinit();
    session.write("primary\x1b[?1049h\x1b[3;1Hfullscreen");
    try testing.expectEqual(@as(u8, 1), session.activeScreen());

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(12, 40);
    defer client.deinit();
    paintOnto(&client, body, "");

    // THE MODES COME BEFORE THE CELLS for this reason: entering the
    // alternate screen clears it, so a paint that preceded the switch
    // would be thrown away by it.
    try testing.expectEqual(@as(u8, 1), client.activeScreen());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("fullscreen", try rowText(&client, &buf, 2));
}

test "a repaint of a screen in origin mode still addresses rows absolutely" {
    var session = try Screen.init(12, 40);
    defer session.deinit();
    // A SCROLLING REGION AND ORIGIN MODE, WHICH IS THE PAIR THAT BITES.
    // Under them a CUP is measured from the region rather than from the
    // screen, and the modes a restoration re-establishes include origin
    // mode — so a paint that trusted CUP after them would put every row
    // three lower than the session has it.
    session.write("\x1b[4;10r\x1b[?6h\x1b[1;1Hinside");
    try testing.expect(session.mode(Screen.origin_mode));

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(12, 40);
    defer client.deinit();
    paintOnto(&client, body, "");

    var buf: [128]u8 = undefined;
    // Row four of the screen, which is row one of the region.
    try testing.expectEqualStrings("inside", try rowText(&client, &buf, 3));
    try testing.expectEqualStrings("", try rowText(&client, &buf, 0));
    // And the mode the child set is still the mode the client is in.
    try testing.expect(client.mode(Screen.origin_mode));
}

test "a repaint in origin mode puts the cursor where the session has it, not where the region starts" {
    var session = try Screen.init(24, 80);
    defer session.deinit();
    // THE PAIR THAT MISPLACED IT ([[WI-2026-08-17-014]]): a region that
    // does not start at the top, and origin mode, under which the CUP
    // that places the cursor is measured from the region. Restored
    // without converting, the cursor landed region.top rows low — seen on
    // a real reattach before it was fixed.
    session.write("\x1b[5;20r\x1b[?6h\x1b[3;22Hx");
    const want = session.cursor();
    // Row five is the region's first, so region-relative row three is
    // screen row seven: the eighth column of it after the character.
    try testing.expectEqual(@as(u16, 6), want.y);

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(24, 80);
    defer client.deinit();
    paintOnto(&client, body, "");

    const got = client.cursor();
    try testing.expectEqual(want.y, got.y);
    try testing.expectEqual(want.x, got.x);
    // And the mode is still on, so what the child sends next is read the
    // way the child means it.
    try testing.expect(client.mode(Screen.origin_mode));
}

test "a region that is the whole screen is stated by saying nothing" {
    var session = try Screen.init(24, 80);
    defer session.deinit();
    session.write("\x1b[?6h\x1b[7;9Hy");
    const want = session.cursor();

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(24, 80);
    defer client.deinit();
    paintOnto(&client, body, "");

    // Origin mode with no region of its own: nothing to subtract, and
    // subtracting anything would be the same defect the other way round.
    const got = client.cursor();
    try testing.expectEqual(want.y, got.y);
    try testing.expectEqual(want.x, got.x);
}

test "a repaint clears a scrolling region the session does not have" {
    var session = try Screen.init(8, 20);
    defer session.deinit();
    session.write("top\r\nnext");

    const body = try session.repaint(testing.allocator);
    defer testing.allocator.free(body);

    var client = try Screen.init(8, 20);
    defer client.deinit();
    // THE PANE IS NOT A FRESH TERMINAL. It is whatever the connection
    // that died left, and a full-screen program leaves a scrolling
    // region behind it. A session that has none says nothing about the
    // region — so unless the paint clears it, the pane keeps scrolling
    // inside three rows for the rest of its life.
    paintOnto(&client, body, "\x1b[1;3r");

    // Asked behaviourally, because a region is not something a screen
    // will state: at the bottom of that stale region, a linefeed would
    // scroll the rows above it away.
    client.write("\x1b[3;1H\n");

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("top", try rowText(&client, &buf, 0));
    try testing.expectEqualStrings("next", try rowText(&client, &buf, 1));
}

test "a restoration larger than the client's buffer is delivered, not refused" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "big-restore");
    var h = try Holder.init(testing.allocator, path);
    try h.start(
        &.{ "/bin/sh", "-c", "printf 'wide'; sleep 30" },
        &.{},
        .{ .ws_row = 60, .ws_col = 200 },
    );
    defer {
        h.endChild();
        h.stop();
    }
    _ = sleepMs(400 * testSlack());

    var cold = try TestClient.connect(path, 60, 200);
    defer cold.close();

    // A BUFFER OF THE SIZE A CALLER ACTUALLY HAS. A repaint of a pane
    // this size carries a palette and sixty positioned rows, so the
    // reattach that fails is the one on the biggest window — which is
    // the window the human is most likely to be working in.
    var small: [4096]u8 = undefined;
    sys.setRecvTimeout(cold.fd, 200) catch {};
    var waited: u64 = 0;
    while (waited < 5000) {
        const frame = (readFrameAlloc(testing.allocator, cold.fd, &small) catch {
            waited += 200;
            continue;
        }) orelse break;
        defer frame.deinit(testing.allocator);
        if (frame.kind != .restore) continue;
        try testing.expect(frame.payload.len > small.len);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "wide") != null);
        return;
    }
    return error.NotSeen;
}

// ---------------------------------------------------------------------------
// The screen a cold client is given ([[WI-2026-08-17-007]])
// ---------------------------------------------------------------------------

test "a client that holds nothing is given the screen, not an empty terminal" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "restore");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    // Somebody works in the session, and leaves.
    var first = try TestClient.connect(path, 24, 80);
    _ = sleepMs(200 * testSlack());
    try first.send("remembered\r");
    var out: [8192]u8 = undefined;
    _ = try first.expect(&out, "GOT[remembered]", 3000);
    first.close();
    _ = sleepMs(200 * testSlack());

    // A client with nothing — a restarted workbench — attaches.
    var cold = try TestClient.connect(path, 24, 80);
    defer cold.close();
    try testing.expectEqual(ResumeAnswer.fresh, cold.answer);

    var rbuf: [65536]u8 = undefined;
    const restoration = try cold.awaitRestoration(&rbuf, 3000);
    try testing.expectEqual(@as(u16, 24), restoration.rows);
    try testing.expectEqual(@as(u16, 80), restoration.cols);
    try testing.expectEqual(@as(u8, 0), restoration.which); // primary screen
    // WHAT WAS ON THE SCREEN IS IN IT. Before this, a cold attach saw an
    // empty terminal and the human's work was on a machine they could
    // reach and could not see.
    try testing.expect(std.mem.indexOf(u8, restoration.body, "GOT[remembered]") != null);
}

test "the restoration says which screen it describes" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "altscreen");
    var h = try Holder.init(testing.allocator, path);
    // A full-screen program takes the alternate buffer. The CHILD emits
    // it, because that is where a screen change comes from — writing the
    // sequence into the master would be the human typing it, which is a
    // different thing entirely.
    try h.start(
        &.{ "/bin/sh", "-c", "printf '\\033[?1049h'; sleep 30" },
        &.{},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer {
        h.endChild();
        h.stop();
    }
    _ = sleepMs(400 * testSlack());

    var cold = try TestClient.connect(path, 24, 80);
    defer cold.close();
    var rbuf: [65536]u8 = undefined;
    const restoration = try cold.awaitRestoration(&rbuf, 3000);
    try testing.expectEqual(@as(u8, 1), restoration.which);
}

test "a restoration is produced in the geometry the client asked for" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "restore-size");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var cold = try TestClient.connect(path, 44, 121);
    defer cold.close();
    var rbuf: [65536]u8 = undefined;
    const restoration = try cold.awaitRestoration(&rbuf, 3000);
    try testing.expectEqual(@as(u16, 44), restoration.rows);
    try testing.expectEqual(@as(u16, 121), restoration.cols);
}

test "a resuming client is not sent a restoration" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "no-double");
    var h = try Holder.init(testing.allocator, path);
    try h.start(echo_shell, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    var first = try TestClient.connect(path, 24, 80);
    _ = sleepMs(200 * testSlack());
    try first.send("one\r");
    var out: [8192]u8 = undefined;
    _ = try first.expect(&out, "GOT[one]", 3000);
    const away_at = first.position;
    const incarnation = first.incarnation;
    first.close();

    _ = sleepMs(100 * testSlack());
    try sys.writeAll(h.pty.master, "two\r");
    _ = sleepMs(300 * testSlack());

    var back = try TestClient.connectFrom(path, 24, 80, incarnation, away_at);
    defer back.close();
    try testing.expectEqual(ResumeAnswer.resumed, back.answer);
    // IT ALREADY HAS THE SCREEN — it never lost it. A restoration here
    // would repaint over a scrollback that is already correct.
    var rbuf: [65536]u8 = undefined;
    try testing.expectError(error.NotSeen, back.awaitRestoration(&rbuf, 800));
}

test "the child is told what terminal it has" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "term");
    var h = try Holder.init(testing.allocator, path);
    // NOTHING UPSTREAM HAS A TERM TO PASS DOWN: the transport carries
    // frames, not a terminal. A child that came up without one turned its
    // own colour off, which is how this was found ([[RFC-0014]]
    // C-TERMINAL-TYPE).
    try h.start(
        &.{ "/bin/sh", "-c", "printf 'TERM=[%s]' \"$TERM\"; sleep 5" },
        &.{},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    var out: [4096]u8 = undefined;
    const seen = try c.expect(&out, "TERM=[", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "TERM=[" ++ default_term ++ "]") != null);
}

test "a caller's own terminal type wins over the default" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "term-override");
    var h = try Holder.init(testing.allocator, path);
    try h.start(
        &.{ "/bin/sh", "-c", "printf 'TERM=[%s]' \"$TERM\"; sleep 5" },
        &.{"TERM=xterm-ghostty"},
        .{ .ws_row = 24, .ws_col = 80 },
    );
    defer {
        h.endChild();
        h.stop();
    }

    var c = try TestClient.connect(path, 24, 80);
    defer c.close();
    var out: [4096]u8 = undefined;
    const seen = try c.expect(&out, "TERM=[", 3000);
    try testing.expect(std.mem.indexOf(u8, seen, "TERM=[xterm-ghostty]") != null);
}

test "the restoration says where the cursor is" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "cursor");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "printf 'ab'; sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }
    _ = sleepMs(400 * testSlack());

    var cold = try TestClient.connect(path, 24, 80);
    defer cold.close();
    var rbuf: [65536]u8 = undefined;
    const restoration = try cold.awaitRestoration(&rbuf, 3000);
    // TWO CHARACTERS WRITTEN, so the cursor is in the third column of the
    // first row. Left to the paint it would end wherever the last cell
    // was, which on a mostly empty screen is the right-hand edge — a
    // prompt on one side and a cursor two hundred columns away.
    try testing.expectEqual(@as(u16, 0), restoration.cursor_row);
    try testing.expectEqual(@as(u16, 2), restoration.cursor_col);
    try testing.expect(restoration.cursor_visible);
}

test "a screen keeps its text when a client attaches at a different size" {
    // WHAT A REATTACH DOES ([[RFC-0014]] C-SIZE, C-RESTORE): the client's
    // dimensions are applied and THEN the restoration is produced. A
    // reattach from a differently-shaped window is the ordinary case —
    // the same session seen from a laptop and from a large display — so
    // the resize must carry the screen rather than clear it.
    var screen = try Screen.init(24, 80);
    defer screen.deinit();
    screen.write("KEEP_ME_ACROSS_RESIZE\r\n");

    screen.resize(54, 197);

    // AND IN THE GEOMETRY THE CLIENT ASKED FOR ([[RFC-0014]] C-RESTORE).
    // A paint of the old shape describes a screen the client does not
    // have: its rows beyond the old height are never addressed, so
    // whatever the pane had there stays, and everything the child drew
    // below that line was never in the model to begin with.
    const dim = screen.size();
    try testing.expectEqual(@as(u16, 54), dim.rows);
    try testing.expectEqual(@as(u16, 197), dim.cols);

    const paint = try screen.repaint(testing.allocator);
    defer testing.allocator.free(paint);
    try testing.expect(std.mem.indexOf(u8, paint, "KEEP_ME_ACROSS_RESIZE") != null);
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[54;1H") != null);
}

test "a screen keeps its text when a client attaches at a smaller size" {
    var screen = try Screen.init(54, 197);
    defer screen.deinit();
    screen.write("KEEP_ME_SHRINKING\r\n");

    screen.resize(24, 80);

    const paint = try screen.repaint(testing.allocator);
    defer testing.allocator.free(paint);
    try testing.expect(std.mem.indexOf(u8, paint, "KEEP_ME_SHRINKING") != null);
}

test "a restoration is produced in the client's geometry even if the model is behind" {
    // The resize that precedes a restoration can fail to take, and until
    // this check the paint went out in whatever shape the model happened
    // to be — describing rows the client does not have and leaving the
    // rest of its screen untouched. A client taller than the model was
    // handed a blank pane and no way to tell why.
    var screen = try Screen.init(24, 80);
    defer screen.deinit();
    screen.write("BEHIND_THE_CLIENT\r\n");

    // What sendRestoration does before painting.
    const want_rows: u16 = 54;
    const have = screen.size();
    if (have.rows != want_rows) screen.resize(want_rows, 197);

    const paint = try screen.repaint(testing.allocator);
    defer testing.allocator.free(paint);
    try testing.expect(std.mem.indexOf(u8, paint, "\x1b[54;1H") != null);
    try testing.expect(std.mem.indexOf(u8, paint, "BEHIND_THE_CLIENT") != null);
}

test "a client that speaks another protocol is refused by name, not hung up on" {
    // [[RFC-0014]] C-VERSION: the refusal MUST be surfaced as a version
    // mismatch NAMING BOTH VERSIONS. The holder used to close the socket,
    // so the human met an unexplained disconnection ([[WI-2026-08-28-024]]).
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "skew");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    const fd = try socketCall(path, .connect);
    defer sys.close(fd);
    const theirs: u8 = protocol_version +% 7;
    var hello: [5]u8 = undefined;
    hello[0] = theirs;
    std.mem.writeInt(u16, hello[1..3], 24, .little);
    std.mem.writeInt(u16, hello[3..5], 80, .little);
    try writeFrame(fd, .hello, &hello);

    var buf: [64]u8 = undefined;
    const reply = (try readFrame(fd, &buf)) orelse return error.Closed;
    try testing.expectEqual(Frame.version_mismatch, reply.kind);
    // BOTH VERSIONS, in the order a reader needs them: what this holder
    // speaks, then what the client announced.
    try testing.expectEqual(@as(usize, 2), reply.payload.len);
    try testing.expectEqual(protocol_version, reply.payload[0]);
    try testing.expectEqual(theirs, reply.payload[1]);
}

test "a mismatched holder can still be enumerated and ended" {
    // [[RFC-0014]] C-VERSION: "Enumerating and ending holders MUST remain
    // possible across a version mismatch. Whatever surface provides them
    // is therefore not part of the versioned session protocol." Otherwise
    // a running session becomes unreachable AND unclearable, which is the
    // cost the clause names.
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "skewend");
    var h = try Holder.init(testing.allocator, path);
    try h.start(&.{ "/bin/sh", "-c", "sleep 30" }, &.{}, .{ .ws_row = 24, .ws_col = 80 });
    defer {
        h.endChild();
        h.stop();
    }

    // A client that cannot attach at all still gets an answer to both.
    try testing.expect(claimState(h.name()) == .held);

    var scratch: StatusBuffers = .{};
    try testing.expect(queryStatusInto(path, &scratch) != null);

    // Ending works across the mismatch too, which is the half that
    // keeps a session from being unreachable AND unclearable.
    try testing.expect(requestEnd(path));
}

test "a client refuses a holder that answers in another protocol" {
    // THE OTHER DIRECTION, and the dangerous one: a holder OUTLIVES the
    // deploy that replaced its binary, so the client is the older side
    // whenever a second machine has deployed and this one has not. Every
    // client used to read payload[1] onward without ever looking at
    // payload[0], which is reading best-effort — what C-VERSION forbids
    // by name.
    var welcome: [26]u8 = undefined;
    welcome[0] = protocol_version +% 3;
    welcome[1] = @intFromEnum(ResumeAnswer.fresh);
    std.mem.writeInt(u64, welcome[2..10], 1, .little);
    std.mem.writeInt(u64, welcome[10..18], 0, .little);
    std.mem.writeInt(u64, welcome[18..26], 0, .little);

    var fds: [2]i32 = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.Unexpected;
    defer sys.close(fds[0]);
    defer sys.close(fds[1]);
    try writeFrame(fds[1], .welcome, &welcome);

    var buf: [64]u8 = undefined;
    var theirs: u8 = 0;
    const result = readWelcome(fds[0], &buf, &theirs);
    try testing.expectError(error.VersionMismatch, result);
    try testing.expectEqual(protocol_version +% 3, theirs);
}

test "a start is refused by the claim, not by whether the socket answers" {
    // THE GUARD [[RFC-0014]] C-START PUTS ON A START ("a start must not
    // join"). It asked `connect`, which says NO about a live holder whose
    // backlog is full — and the start it then admitted unlinks the running
    // session's socket before binding its own ([[WI-2026-08-30-004]]).
    var root: [128]u8 = undefined;
    const r = try std.fmt.bufPrint(&root, "/tmp/synapty-claimstate-{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().createDirPath(io_mod.get(), r) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_mod.get(), r) catch {};
    paths.root_override = r;
    defer paths.root_override = null;

    // A name nothing has ever claimed is free to start under.
    try testing.expectEqual(Claim.absent, claimState("never-used"));

    // One a holder is holding is not.
    const held = Record.write("in-use");
    defer if (held) |fd| sys.close(fd);
    defer Record.remove("in-use");
    try testing.expect(held != null);
    try testing.expectEqual(Claim.held, claimState("in-use"));

    // AND THE THREE STATES ARE THREE. A record whose holder is gone is
    // `free` and not `held`: refusing a start there would strand the name
    // against a session that no longer exists.
    try writeRecordForTest("was-used", 0x7FFF_FFFF);
    try testing.expectEqual(Claim.free, claimState("was-used"));

    // WHICH IS THE WHOLE POINT, said about the question the guard asks.
    try testing.expect(!startWouldJoin("never-used"));
    try testing.expect(startWouldJoin("in-use"));
    try testing.expect(!startWouldJoin("was-used"));
}

fn slowWriter(h: *Holder, started: *std.atomic.Value(bool), release: *std.atomic.Value(bool), ended: *std.atomic.Value(bool)) void {
    h.mutex.lock(io_mod.get()) catch return;
    _ = h.beginWriteLocked();
    h.mutex.unlock(io_mod.get());
    started.store(true, .release);
    while (!release.load(.acquire)) std.atomic.spinLoopHint();
    h.endWrite();
    ended.store(true, .release);
}

fn closer(h: *Holder, fd: sys.fd_t, flag: *std.atomic.Value(bool)) void {
    h.closeClientFd(fd);
    flag.store(true, .release);
}

test "a client fd is not closed while a write to it is in flight (WI-2026-09-02-016)" {
    var pbuf: [128]u8 = undefined;
    const path = try testSocketPath(&pbuf, "fdlife");
    var h = try Holder.init(testing.allocator, path);
    defer {
        h.endChild();
        h.stop();
    }
    var pair: [2]sys.fd_t = undefined;
    try testing.expect(std.c.socketpair(sys.AF.UNIX, sys.SOCK.STREAM, 0, &pair) == 0);
    defer sys.close(pair[1]);
    h.mutex.lock(io_mod.get()) catch unreachable;
    h.client = pair[0];
    h.mutex.unlock(io_mod.get());

    var started = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var ended = std.atomic.Value(bool).init(false);
    const writer = try std.Thread.spawn(.{}, slowWriter, .{ &h, &started, &release, &ended });
    while (!started.load(.acquire)) std.atomic.spinLoopHint();

    var closed = std.atomic.Value(bool).init(false);
    const closing = try std.Thread.spawn(.{}, closer, .{ &h, pair[0], &closed });
    _ = sleepMs(50 * testSlack());
    try testing.expect(!closed.load(.acquire));
    release.store(true, .release);
    writer.join();
    closing.join();
    try testing.expect(ended.load(.acquire));
    try testing.expect(closed.load(.acquire));
    h.mutex.lock(io_mod.get()) catch unreachable;
    h.client = null;
    h.mutex.unlock(io_mod.get());
}
