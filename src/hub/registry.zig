const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const mem = std.mem;
const json = std.json;
const protocol = @import("protocol");
const Allocator = mem.Allocator;
const Connection = @import("connection.zig").Connection;
const log = @import("diag").scoped(.hub);

// ---------------------------------------------------------------------------
// Routing Table
// ---------------------------------------------------------------------------

/// Which connection currently answers to which name.
///
/// THE TABLE OWNS ITS KEYS ([[WI-2026-08-17-005]]). It did not, and the
/// borrowed slices came from the CONNECTION that registered them — so a
/// connection could leave while the table still held its memory as a key.
/// That is exactly what a duplicate registration produces: the second
/// connection takes the entry's value and the FIRST connection's slice
/// stays as its key, because inserting over an existing key keeps the old
/// one. When the displaced connection was then released, every later
/// lookup compared against freed memory, and the hub aborted — one per
/// machine, so that is every agent on the box.
///
/// The registry beside this one already duplicated its keys; this is the
/// same rule applied where it was missing rather than a new idea.
pub const RoutingTable = struct {
    map: std.StringHashMap(*Connection),
    mutex: std.Io.Mutex,

    pub fn init(allocator: Allocator) RoutingTable {
        return .{
            .map = std.StringHashMap(*Connection).init(allocator),
            .mutex = .init,
        };
    }

    pub fn deinit(self: *RoutingTable) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.map.allocator.free(k.*);
        self.map.deinit();
    }

    /// Remove an entry and free the name it was keyed by. Callers must
    /// hold the mutex.
    pub fn removeOwnedLocked(self: *RoutingTable, agent_id: []const u8) bool {
        if (self.map.fetchRemove(agent_id)) |kv| {
            self.map.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// Insert or replace, taking a copy of the name. Callers must hold
    /// the mutex.
    ///
    /// A REPLACEMENT KEEPS THE EXISTING KEY, which is what made the old
    /// borrowed-key version wrong rather than merely fragile: inserting
    /// over a name does not adopt the new caller's slice, so the table
    /// went on pointing at the first registrant's memory long after that
    /// connection had gone.
    pub fn putOwnedLocked(self: *RoutingTable, agent_id: []const u8, conn: *Connection) !?*Connection {
        const gop = try self.map.getOrPut(agent_id);
        if (gop.found_existing) {
            const previous = gop.value_ptr.*;
            gop.value_ptr.* = conn;
            return previous;
        }
        gop.key_ptr.* = self.map.allocator.dupe(u8, agent_id) catch |err| {
            _ = self.map.remove(agent_id);
            return err;
        };
        gop.value_ptr.* = conn;
        return null;
    }

    pub fn register(self: *RoutingTable, agent_id: []const u8, conn: *Connection) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (try self.putOwnedLocked(agent_id, conn)) |old| {
            // Duplicate registration (WI-2026-08-08-016): the new
            // connection atomically replaces the old one. Interrupt the
            // old stream's blocked read (EOF, fd NOT closed) so its reader
            // exits and its teardown closes the fd after the writer joined
            // — closing the fd here would race a concurrent writer and
            // could reuse the number for a new connection's socket
            // (WI-2026-08-08-029).
            log.warn("duplicate registration for {s} — replacing previous connection", .{agent_id});
            old.interruptStream();
        } else {
            log.info("registered agent: {s}", .{agent_id});
        }
    }

    pub fn lookup(self: *const RoutingTable, agent_id: []const u8) ?*Connection {
        // Callers must hold mutex before calling.
        return self.map.get(agent_id);
    }

    /// Lookup and retain a connection. Caller must call conn.release() when done.
    /// Safe against concurrent unregister — the routing table mutex serializes
    /// retain vs unregister, so the pointer is guaranteed alive until release.
    pub fn lookupAndRetain(self: *RoutingTable, agent_id: []const u8) ?*Connection {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const conn = self.map.get(agent_id) orelse return null;
        conn.retain();
        return conn;
    }

    /// Return a heap-allocated slice of duped agent ID strings.
    /// Caller owns both the slice and each string — free strings first, then slice.
    pub fn agentIds(self: *RoutingTable, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const count = self.map.count();
        const slice = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        errdefer {
            for (slice[0..i]) |s| allocator.free(s);
            allocator.free(slice);
        }
        var it = self.map.keyIterator();
        while (it.next()) |key| : (i += 1) {
            slice[i] = try allocator.dupe(u8, key.*);
        }
        return slice;
    }
};

// ---------------------------------------------------------------------------
// Agent Registry — per [[RFC-0003]] (agent identity)
// ---------------------------------------------------------------------------

pub const AgentInfo = struct {
    tool: ?[]const u8 = null,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// RFC-0008 C-IDENTITY: harness-native session identity (validated
    /// at derivation, stored as reported). Distinct from `session`
    /// (free-text description).
    resume_ref: ?[]const u8 = null,
    /// MERGED presence state per [[RFC-0004:C-VOCABULARY]]. This map is a
    /// materialized view of the hub event log — never a second source of
    /// truth (C-EVENT-LOG). Never-signaled agents are honestly `unknown`.
    status: protocol.Status = .unknown,
};

/// Result of applying one presence signal (RFC-0004 C-PRECEDENCE).
pub const SignalResult = struct {
    accepted: bool,
    changed: bool,
    old: protocol.Status,
    new: protocol.Status,
};

pub const AgentRegistry = struct {
    map: std.StringHashMap(AgentInfo),
    mutex: std.Io.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) AgentRegistry {
        return .{
            .map = std.StringHashMap(AgentInfo).init(allocator),
            .mutex = .init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.freeInfo(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Dupe key and info strings into owned storage, replacing any previous entry.
    pub fn update(self: *AgentRegistry, agent_id: []const u8, info: AgentInfo) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        var owned = AgentInfo{};
        // Partial-failure cleanup: frees exactly what was allocated — the
        // previous code leaked partially-duped strings (WI-2026-08-08-028).
        errdefer self.freeInfo(owned);
        if (info.tool) |t| owned.tool = try self.allocator.dupe(u8, t);
        if (info.project) |p| owned.project = try self.allocator.dupe(u8, p);
        if (info.session) |s| owned.session = try self.allocator.dupe(u8, s);
        if (info.resume_ref) |r| owned.resume_ref = try self.allocator.dupe(u8, r);
        // A metadata update NEVER touches the merged status — status moves
        // only through applySignal (RFC-0004 C-PRECEDENCE); re-registering
        // must not silently wipe a "waiting" flag (C-OWNERSHIP).
        if (self.map.get(agent_id)) |prev_info| {
            owned.status = prev_info.status;
        }
        // getOrPut, NOT fetchPut: fetchPut keeps the ORIGINAL key storage
        // in the map while returning it as prev — the old free(prev.key)
        // left the map keyed by freed memory, so any RE-registered agent
        // became unreachable (latent use-after-free, surfaced by the
        // WI-2026-08-09-022 status tests).
        const gop = try self.map.getOrPut(agent_id);
        if (gop.found_existing) {
            self.freeInfo(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, agent_id) catch |err| {
                self.map.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = owned;
        log.info("agent metadata updated: {s} tool={s}", .{ agent_id, info.tool orelse "-" });
    }

    /// Apply one presence signal through the RFC-0004 C-PRECEDENCE
    /// acceptance rules against the CURRENT merged status. Creates a
    /// status-only record for agents that never sent metadata. Rejected
    /// signals leave the map untouched (accepted=false).
    pub fn applySignal(self: *AgentRegistry, agent_id: []const u8, class: protocol.SignalClass, new: protocol.Status) !SignalResult {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const current: protocol.Status = if (self.map.get(agent_id)) |i| i.status else .unknown;
        if (!protocol.acceptSignal(current, class, new)) {
            return .{ .accepted = false, .changed = false, .old = current, .new = current };
        }
        if (self.map.getPtr(agent_id)) |info| {
            info.status = new;
        } else {
            const owned_key = try self.allocator.dupe(u8, agent_id);
            errdefer self.allocator.free(owned_key);
            try self.map.put(owned_key, AgentInfo{ .status = new });
        }
        if (current != new) {
            log.info("agent status: {s} {s} -> {s} ({s})", .{ agent_id, current.toString(), new.toString(), class.toString() });
        }
        return .{ .accepted = true, .changed = current != new, .old = current, .new = new };
    }

    pub fn remove(self: *AgentRegistry, agent_id: []const u8) void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.map.fetchRemove(agent_id)) |kv| {
            self.allocator.free(kv.key);
            self.freeInfo(kv.value);
        }
    }

    /// Return a snapshot of agent info with duped strings (caller-owned).
    /// Safe to use after the mutex is released — no borrowed pointers.
    pub fn get(self: *AgentRegistry, agent_id: []const u8, alloc: Allocator) ?AgentInfo {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const info = self.map.get(agent_id) orelse return null;
        return AgentInfo{
            .tool = if (info.tool) |t| alloc.dupe(u8, t) catch null else null,
            .project = if (info.project) |p| alloc.dupe(u8, p) catch null else null,
            .session = if (info.session) |s| alloc.dupe(u8, s) catch null else null,
            .status = info.status,
            // RFC-0006 C-RESUME-PLAN: the workbench composes resume
            // incantations from this. Omitting it here silently emptied
            // it from BOTH list_agents and the subscription SNAPSHOT
            // (buildAgentsArray reads it off this struct), so a workbench
            // that reconnected lost every resume plan until each agent
            // happened to re-register. The event stream carried it
            // correctly the whole time, which is why nothing looked broken.
            .resume_ref = if (info.resume_ref) |r| alloc.dupe(u8, r) catch null else null,
        };
    }

    pub fn freeInfo(self: *AgentRegistry, info: AgentInfo) void {
        if (info.tool) |t| self.allocator.free(t);
        if (info.project) |p| self.allocator.free(p);
        if (info.session) |s| self.allocator.free(s);
        if (info.resume_ref) |r| self.allocator.free(r);
    }
};

// ---------------------------------------------------------------------------
// Channel Registry — per [[RFC-0003:C-A2A-REDUCTION]] (legacy group-chat surface)
// ---------------------------------------------------------------------------

pub const Channel = struct {
    name: []const u8,
    description: []const u8,
    members: std.StringHashMap(void),
    created_by: []const u8,
    created_at: i64,
};

pub const ChannelRegistry = struct {
    map: std.StringHashMap(Channel),
    mutex: std.Io.Mutex,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ChannelRegistry {
        return .{
            .map = std.StringHashMap(Channel).init(allocator),
            .mutex = .init,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChannelRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.freeChannelStrings(entry.key_ptr.*, entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn create(self: *ChannelRegistry, name: []const u8, description: []const u8, creator: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        if (self.map.contains(name)) return error.ChannelExists;
        // Dupe all strings — channel data outlives the creating connection.
        // Single cleanup block frees every partial allocation when any dupe
        // or insert fails (WI-2026-08-08-028).
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_desc = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_desc);
        const owned_creator = try self.allocator.dupe(u8, creator);
        errdefer self.allocator.free(owned_creator);
        const member_key = try self.allocator.dupe(u8, creator);
        errdefer self.allocator.free(member_key);
        var members = std.StringHashMap(void).init(self.allocator);
        errdefer members.deinit();
        try members.put(member_key, {});
        try self.map.put(owned_name, .{
            .name = owned_name,
            .description = owned_desc,
            .members = members,
            .created_by = owned_creator,
            .created_at = std.Io.Timestamp.now(io_mod.get(), .real).toSeconds(),
        });
        log.info("channel created: {s} by {s}", .{ name, creator });
    }

    pub fn addMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        const owned_id = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_id);
        try ch.members.put(owned_id, {});
    }

    pub fn removeMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.getPtr(name) orelse return error.ChannelNotFound;
        if (ch.members.fetchRemove(agent_id)) |kv| {
            self.allocator.free(kv.key);
        }
        if (ch.members.count() == 0) {
            if (self.map.fetchRemove(name)) |kv| {
                self.freeChannelStrings(kv.key, kv.value);
            }
            log.info("channel garbage-collected: {s}", .{name});
        }
    }

    /// Free all owned strings of a channel entry.
    pub fn freeChannelStrings(self: *ChannelRegistry, key: []const u8, ch: Channel) void {
        // Free remaining member keys.
        var copy = ch;
        var member_it = copy.members.keyIterator();
        while (member_it.next()) |k| self.allocator.free(k.*);
        copy.members.deinit();
        // key == ch.name (same pointer from create), free once.
        self.allocator.free(key);
        self.allocator.free(ch.description);
        self.allocator.free(ch.created_by);
    }

    pub fn isMember(self: *ChannelRegistry, name: []const u8, agent_id: []const u8) bool {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.get(name) orelse return false;
        return ch.members.contains(agent_id);
    }

    /// Return duped member ID strings. Caller owns both slice and each string.
    pub fn getMembers(self: *ChannelRegistry, name: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const ch = self.map.get(name) orelse return error.ChannelNotFound;
        const count = ch.members.count();
        const slice = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        errdefer {
            for (slice[0..i]) |s| allocator.free(s);
            allocator.free(slice);
        }
        var it = ch.members.keyIterator();
        while (it.next()) |key| : (i += 1) {
            slice[i] = try allocator.dupe(u8, key.*);
        }
        return slice;
    }

    /// Remove an agent from all channels, returning channel names it was in.
    pub fn removeFromAll(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        var affected = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.members.fetchRemove(agent_id)) |kv| {
                self.allocator.free(kv.key);
                // Dupe into caller's allocator so the name survives GC below.
                try affected.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        // Garbage-collect empty channels (deferred to avoid mutation during iteration).
        for (affected.items) |ch_name| {
            if (self.map.getPtr(ch_name)) |ch| {
                if (ch.members.count() == 0) {
                    if (self.map.fetchRemove(ch_name)) |kv| {
                        self.freeChannelStrings(kv.key, kv.value);
                    }
                }
            }
        }
        return affected.toOwnedSlice(allocator);
    }

    /// List channels an agent is a member of. Returns duped channel names.
    pub fn channelsFor(self: *ChannelRegistry, agent_id: []const u8, allocator: Allocator) ![][]const u8 {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        var result = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.members.contains(agent_id)) {
                try result.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Message Log — per [[RFC-0003]] (hub state)
// ---------------------------------------------------------------------------

pub const LogEntry = struct {
    from: []const u8,
    to: []const u8,
    channel: ?[]const u8,
    text: []const u8,
    ts: i64,
};

pub const MessageLog = struct {
    entries: std.ArrayList(LogEntry),
    mutex: std.Io.Mutex,
    max_entries: usize,

    pub fn init(max_entries: usize) MessageLog {
        return .{
            .entries = std.ArrayList(LogEntry).empty,
            .mutex = .init,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *MessageLog, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            freeLogEntry(allocator, entry);
        }
        self.entries.deinit(allocator);
    }

    pub fn freeLogEntry(allocator: Allocator, entry: LogEntry) void {
        allocator.free(entry.from);
        allocator.free(entry.to);
        if (entry.channel) |ch| allocator.free(ch);
        allocator.free(entry.text);
    }

    /// Append a log entry, duping all strings so the entry outlives the caller's arena.
    pub fn append(self: *MessageLog, allocator: Allocator, entry: LogEntry) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        // Each dupe is released if a later step fails — the shape
        // MailStore.append already has ([[WI-2026-09-02-014]]).
        const from = try allocator.dupe(u8, entry.from);
        errdefer allocator.free(from);
        const to = try allocator.dupe(u8, entry.to);
        errdefer allocator.free(to);
        const channel = if (entry.channel) |ch| try allocator.dupe(u8, ch) else null;
        errdefer if (channel) |ch| allocator.free(ch);
        const text = try allocator.dupe(u8, entry.text);
        errdefer allocator.free(text);
        const owned = LogEntry{ .from = from, .to = to, .channel = channel, .text = text, .ts = entry.ts };
        try self.entries.append(allocator, owned);
        // FIFO eviction.
        if (self.entries.items.len > self.max_entries) {
            const evicted = self.entries.orderedRemove(0);
            freeLogEntry(allocator, evicted);
        }
    }
};

// ---------------------------------------------------------------------------
// Activity Log — RFC-0003 C-HUB-ROLE: tool-request activity stream
// (replaces the chat-history role of MessageLog; MessageLog stays for
// the deprecated dm compat surface)
// ---------------------------------------------------------------------------

pub const ActivityEntry = struct {
    ts: i64,
    /// Requesting agent id (real agents; cli-tmp-* for one-shot tools).
    agent: []const u8,
    /// Tool name, e.g. "task.claim".
    tool: []const u8,
    /// Short human-readable detail, e.g. "claim #12".
    detail: []const u8,
};

pub const ActivityLog = struct {
    entries: std.ArrayList(ActivityEntry),
    mutex: std.Io.Mutex,
    max_entries: usize,

    pub fn init(max_entries: usize) ActivityLog {
        return .{
            .entries = std.ArrayList(ActivityEntry).empty,
            .mutex = .init,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *ActivityLog, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.agent);
            allocator.free(entry.tool);
            allocator.free(entry.detail);
        }
        self.entries.deinit(allocator);
    }

    /// Append an entry, duping strings into `allocator` (caller picks the
    /// long-lived allocator, e.g. HubState.allocator).
    pub fn append(self: *ActivityLog, allocator: Allocator, entry: ActivityEntry) !void {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        const agent = try allocator.dupe(u8, entry.agent);
        errdefer allocator.free(agent);
        const tool = try allocator.dupe(u8, entry.tool);
        errdefer allocator.free(tool);
        const detail = try allocator.dupe(u8, entry.detail);
        errdefer allocator.free(detail);
        const owned = ActivityEntry{ .ts = entry.ts, .agent = agent, .tool = tool, .detail = detail };
        try self.entries.append(allocator, owned);
        if (self.entries.items.len > self.max_entries) {
            const evicted = self.entries.orderedRemove(0);
            allocator.free(evicted.agent);
            allocator.free(evicted.tool);
            allocator.free(evicted.detail);
        }
    }

    /// Copy the newest `limit` entries as JSON (caller allocates via arena).
    /// agent/tool/detail are duped into `arena` while the mutex is still
    /// held: a concurrent append past max_entries evicts and FREES the
    /// log's own strings, so returning borrowed slices would leave the
    /// caller serializing freed memory (WI-2026-08-08-003).
    pub fn toJson(self: *ActivityLog, arena: Allocator, limit: usize) !json.Value {
        self.mutex.lock(io_mod.get()) catch unreachable;
        defer self.mutex.unlock(io_mod.get());
        var arr = json.Array.init(arena);
        const start = if (self.entries.items.len > limit) self.entries.items.len - limit else 0;
        for (self.entries.items[start..]) |entry| {
            var obj = json.ObjectMap.empty;
            try obj.put(arena, "ts", .{ .integer = entry.ts });
            try obj.put(arena, "agent", .{ .string = try arena.dupe(u8, entry.agent) });
            try obj.put(arena, "tool", .{ .string = try arena.dupe(u8, entry.tool) });
            try obj.put(arena, "detail", .{ .string = try arena.dupe(u8, entry.detail) });
            try arr.append(.{ .object = obj });
        }
        return .{ .array = arr };
    }
};

// ---------------------------------------------------------------------------
// Hub State — combines all registries
// ---------------------------------------------------------------------------

pub const events = @import("events.zig");
const federation = @import("federation.zig");
pub const DeliveryOutcome = federation.DeliveryOutcome;

/// A live relay link. `dialed_port` is 0 for a link this hub ACCEPTED
/// rather than dialed: the peer reached us, so there is no local port
/// that reaches it and a workbench cannot re-establish it from this side.
pub const PeerLink = struct {
    conn: *Connection,
    dialed_port: u16 = 0,
    /// The version this link settled on, and what the peer declared it
    /// provides ([[RFC-0010]] C-CAPABILITIES). Retained for the life of
    /// the link because two things depend on it: nothing may invoke a
    /// behaviour the peer did not declare, and a human has to be able to
    /// see what a peer cannot do rather than watch it look broken.
    version: u16 = federation.protocol_min,
    caps: federation.CapabilitySet = .{},
};

/// A forwarded tool request awaiting the workbench's receipt. The
/// timestamp is what lets an abandoned park be released instead of
/// pinning its requester's connection until the hub exits.
pub const PendingTool = struct {
    conn: *Connection,
    parked_ms: i64,
};

/// What a send actually did.
///
/// `hosted` is INTERNAL. It answers "was the recipient connected when this
/// landed", which is a different question from "what happened to the
/// message" — and it does not go on the wire: that is presence, and
/// presence has its own surface with its own acceptance rules
/// ([[RFC-0009]] C-DELIVERY's wire shape is `{status, reason?}`).
pub const Delivery = struct {
    outcome: DeliveryOutcome,
    hosted: bool = false,
    /// Set when this message was WRITTEN to a peer link and its answer has
    /// not arrived. The caller waits on it and only then knows whether the
    /// outcome is `forwarded`, `refused` or `spooled` ([[RFC-0009]]
    /// C-DELIVERY). Owned by the pending table; `awaitForward` frees it.
    forward_id: ?[]const u8 = null,
};
const state_store = @import("state_store.zig");

/// RFC-0008 C-MAILBOX: hub-side message queues keyed by agent identity.
/// Bounded per queue (drop-oldest, logged); pane-class queues are
/// disposed at teardown (pane ids never re-home). NOT internally locked
/// — every access happens under HubState.presence_mutex.
pub const MailStore = struct {
    pub const max_per_queue = 256;
    map: std.StringHashMap(std.ArrayList([]const u8)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MailStore {
        return .{
            .map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MailStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |m| self.allocator.free(m);
            e.value_ptr.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Queue one raw message line (duped). Drop-oldest when full, with a
    /// trace (C-MAILBOX: silent truncation is not allowed).
    pub fn append(self: *MailStore, id: []const u8, raw: []const u8) !void {
        const list: *std.ArrayList([]const u8) = blk: {
            if (self.map.getPtr(id)) |l| break :blk l;
            const key = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(key);
            try self.map.put(key, .empty);
            break :blk self.map.getPtr(id).?;
        };
        if (list.items.len >= max_per_queue) {
            const oldest = list.orderedRemove(0);
            self.allocator.free(oldest);
            log.err("mailbox for {s} full — DROPPED the oldest message, which a sender was already told was queued", .{id});
        }
        const copy = try self.allocator.dupe(u8, raw);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    pub fn count(self: *const MailStore, id: []const u8) usize {
        return if (self.map.getPtr(id)) |l| l.items.len else 0;
    }

    /// Drain into `arena`-owned copies; store-owned originals are freed.
    pub fn drainInto(self: *MailStore, arena: Allocator, id: []const u8) ![]const []const u8 {
        const list = self.map.getPtr(id) orelse return &.{};
        const out = try arena.alloc([]const u8, list.items.len);
        for (list.items, 0..) |m, i| {
            out[i] = try arena.dupe(u8, m);
            self.allocator.free(m);
        }
        list.clearRetainingCapacity();
        return out;
    }

    /// Move all of `from`'s mail to `to` (identity upgrade merge —
    /// same pane, same occupant). Ownership moves; bounds enforced.
    pub fn merge(self: *MailStore, from: []const u8, to: []const u8) !void {
        if (std.mem.eql(u8, from, to)) return;
        const src = self.map.getPtr(from) orelse return;
        if (src.items.len == 0) return;
        const dest: *std.ArrayList([]const u8) = blk: {
            if (self.map.getPtr(to)) |l| break :blk l;
            const key = try self.allocator.dupe(u8, to);
            errdefer self.allocator.free(key);
            try self.map.put(key, .empty);
            break :blk self.map.getPtr(to).?;
        };
        // Re-fetch src: the dest put may have rehashed the map.
        const src2 = self.map.getPtr(from).?;
        for (src2.items) |m| {
            if (dest.items.len >= max_per_queue) {
                const oldest = dest.orderedRemove(0);
                self.allocator.free(oldest);
                log.err("mailbox for {s} full during merge — DROPPED the oldest message, which a sender was already told was queued", .{to});
            }
            try dest.append(self.allocator, m);
        }
        src2.clearRetainingCapacity();
        self.dispose(from);
    }

    /// Drop a queue and everything in it (teardown disposal).
    pub fn dispose(self: *MailStore, id: []const u8) void {
        if (self.map.fetchRemove(id)) |kv| {
            for (kv.value.items) |m| self.allocator.free(m);
            var v = kv.value;
            v.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }
};

pub const HubState = struct {
    routing_table: RoutingTable,
    agent_registry: AgentRegistry,
    channel_registry: ChannelRegistry,
    message_log: MessageLog,
    /// Tool-request activity stream (RFC-0003 C-HUB-ROLE).
    activity_log: ActivityLog,
    /// Hub event log per [[RFC-0004:C-EVENT-LOG]] — the source of truth
    /// for presence. Guarded by presence_mutex, NOT internally locked.
    event_log: events.EventLog,
    /// RFC-0008 hub-side mailbox. Guarded by presence_mutex.
    mailbox: MailStore,
    /// Durable ids ever bound this hub life (RFC-0008: known-target
    /// checks + mailbox disposal class). Guarded by presence_mutex.
    durable_ids: std.StringHashMap(void),
    /// RFC-0005 C-WAKE-TRIGGER: outstanding wake candidates — identity ->
    /// the registration generation the candidate was born under. Presence
    /// of a key means "candidate emitted, not yet resolved"; it is what
    /// makes emission edge-triggered (level stays silent). Keys owned.
    /// Guarded by presence_mutex.
    wake_pending: std.StringHashMap(u64),
    /// Registration generations per [[RFC-0004]] C-WAIT: agent_id -> seq of
    /// the agent_registered event that CREATED the registration. Keys owned.
    /// Guarded by presence_mutex.
    generations: std.StringHashMap(u64),
    /// [[RFC-0009]] peer directory: identities OTHER hubs host. Tombstoned
    /// on link drop, never discarded. Guarded by presence_mutex.
    directory: federation.Directory,
    /// [[RFC-0009]] C-DELIVERY forwarding spool, per peer. Guarded by
    /// presence_mutex.
    spool: federation.Spool,
    /// Forwards this hub has already ACCEPTED from a peer, so a retry
    /// after a lost ack is acknowledged rather than queued twice
    /// ([[RFC-0009]] C-DELIVERY). Guarded by presence_mutex.
    forward_seen: federation.ForwardSeen,
    /// Mints forward ids. The startup stamp is what keeps a restart from
    /// repeating an id the peer still remembers.
    forward_seq: u64 = 0,
    startup_ms: i64 = 0,
    /// Forwards written to a link and not yet answered. A hub holds its
    /// copy until the acknowledgement arrives ([[RFC-0009]] C-DELIVERY),
    /// so `forwarded` means the peer took it rather than that a socket
    /// accepted the bytes. Keys owned; guarded by `forward_mutex`, which
    /// is taken alone — never with presence_mutex held, so a five-second
    /// wait cannot freeze the hub.
    pending_forwards: std.StringHashMap(ForwardAnswer),
    forward_mutex: std.Io.Mutex,
    /// The last peer id seen at each dialed endpoint. THE ENDPOINT IS THE
    /// CONTINUITY, not the id: a machine that was rebuilt legitimately
    /// mints a new name, and "same place, new name" is how this hub knows
    /// to drop everything keyed on the old one ([[RFC-0010]]
    /// C-PEER-IDENTITY). Keys owned. Guarded by presence_mutex.
    endpoint_ids: std.AutoHashMap(u16, []const u8),
    /// Live relay links: peer id -> connection + the loopback port it was
    /// dialed on. The PORT is kept because a restarting workbench has to
    /// learn which peers this hub already has and where they are — the hub
    /// outlives the workbench by design ([[ADR-0008]] supervision), so
    /// "I just started, therefore there are no peers" is a false
    /// assumption, and acting on it leaves the workbench with no peer
    /// subscription and no port assignment while the hub is federated.
    peer_links: std.StringHashMap(PeerLink),
    /// Credential-bound tool requests awaiting the workbench's receipt:
    /// request id -> the RETAINED requester connection. Retained because
    /// the answer arrives on a different thread, after this handler has
    /// returned — the same asynchrony exec already has, but exec answers
    /// through the event log while a tool_response must reach ONE agent.
    /// Guarded by presence_mutex.
    pending_tools: std.StringHashMap(PendingTool),
    /// This hub's own peer id (C-BOUNDARIES). null = federation disabled,
    /// which is every hub before a peer link is configured — and the
    /// state in which every rule below degrades to the single-hub one.
    peer_id: ?[]const u8 = null,
    /// [[ADR-0008]] supervision hook (null in tests and in service
    /// mode): a workbench's supervisor link attaches here so a reclaim
    /// can cancel a pending grace shutdown.
    supervision: ?*@import("service.zig").Supervision = null,
    /// Durable-state file path ([[ADR-0008]] stage 2). null = ephemeral
    /// (tests, and any hub whose operator has not asked for durability).
    /// When set, every change to the state that carries a PROMISE —
    /// queued mail and the durable-identity set — is written before the
    /// promise is acknowledged.
    state_path: ?[]const u8 = null,
    /// The OUTER presence lock. Every mutation that both changes presence
    /// state AND appends an event holds this for the whole composite op —
    /// that is what makes the C-EVENT-LOG write-time invariant true
    /// ("visible change ⟺ logged event", registry as materialized view).
    /// LOCK ORDER: presence_mutex -> routing_table.mutex ->
    /// channel_registry.mutex ->
    /// agent_registry.mutex -> Connection.mutex. No path takes the reverse.
    presence_mutex: std.Io.Mutex,
    allocator: Allocator,
    /// All heap-allocated connections — freed in deinit after all threads join.
    /// Connections outlive their reader/writer threads to prevent use-after-free
    /// when a cross-agent enqueue races with disconnect cleanup.
    all_connections: std.ArrayList(*Connection),
    all_connections_mutex: std.Io.Mutex,
    /// Dial threads, tracked so deinit can join them rather than let one
    /// wake against freed state ([[WI-2026-09-02-015]]); their peer
    /// connections are in all_connections and are shut before the join.
    dial_threads: sys.ThreadReaper,

    /// A CONNECTION WHOSE LAST REFERENCE IS GONE, taken out of the list
    /// that tracks it and freed.
    ///
    /// ONE FUNCTION, because it was two with identical bodies — one for
    /// connections this hub accepted and one for connections it dialled —
    /// and this is the refcount-hits-zero path. A change made to one and
    /// not the other is a leaked connection or a use-after-free, and
    /// nothing about the pair would have failed to compile
    /// ([[WI-2026-08-28-016]]).
    ///
    /// Shaped as a `*anyopaque` callback because that is what
    /// [[Connection]] holds; the pointer is always a `*HubState`.
    pub fn releaseConnection(ctx: *anyopaque, conn: *Connection) void {
        const io = io_mod.get();
        const self: *HubState = @ptrCast(@alignCast(ctx));
        self.all_connections_mutex.lock(io) catch unreachable;
        for (self.all_connections.items, 0..) |c, idx| {
            if (c == conn) {
                _ = self.all_connections.swapRemove(idx);
                break;
            }
        }
        self.all_connections_mutex.unlock(io);
        conn.closeStream();
        conn.deinit();
        conn.allocator.destroy(conn);
    }

    /// Register `agent_id` on `conn`, assign or carry forward its
    /// generation, and append the agent_registered event — atomically
    /// under presence_mutex. A fresh registration's generation IS the seq
    /// of the event this call appends; a live re-register keeps the
    /// existing generation (RFC-0004 C-WAIT).
    pub fn registerAgentTracked(self: *HubState, agent_id: []const u8, conn: *Connection) !u64 {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        try self.routing_table.register(agent_id, conn);
        if (self.generations.get(agent_id)) |gen| {
            _ = self.event_log.append(.{ .kind = .agent_registered, .agent = agent_id, .generation = gen }) catch 0;
            return gen;
        }
        // Fresh registration: the creating event's seq is the generation.
        const gen = self.event_log.next_seq;
        const owned_key = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(owned_key);
        try self.generations.put(owned_key, gen);
        _ = self.event_log.append(.{ .kind = .agent_registered, .agent = agent_id, .generation = gen }) catch 0;
        // RFC-0005 C-WAKE-TRIGGER fresh-edge rule: registering an identity
        // whose mailbox is non-empty counts as an empty→non-empty edge.
        if (self.mailbox.count(agent_id) > 0) self.wakeCandidateLocked(agent_id, gen);
        // [[RFC-0009]] C-DIRECTORY: advertise on change, so peers learn
        // about this identity without polling.
        self.broadcastDirectoryLocked(agent_id, true);
        return gen;
    }

    // -- RFC-0005 wake candidates ------------------------------------------

    /// Record a wake candidate for `agent` under `gen` and append the
    /// wake_candidate event (C-WAKE-TRIGGER). No-op while a candidate is
    /// already outstanding — that is the edge/level distinction: further
    /// mail into a non-empty mailbox emits nothing. Caller holds
    /// presence_mutex.
    fn wakeCandidateLocked(self: *HubState, agent: []const u8, gen: u64) void {
        if (self.wake_pending.contains(agent)) return;
        const key = self.allocator.dupe(u8, agent) catch return;
        self.wake_pending.put(key, gen) catch {
            self.allocator.free(key);
            return;
        };
        _ = self.event_log.append(.{ .kind = .wake_candidate, .agent = agent, .generation = gen }) catch 0;
    }

    /// Cancel the outstanding candidate if one exists and append
    /// wake_cancelled carrying the candidate's birth generation
    /// (C-WAKE-TRIGGER: self-read to empty, unregister, or generation
    /// change). Caller holds presence_mutex.
    fn wakeCancelLocked(self: *HubState, agent: []const u8) void {
        const kv = self.wake_pending.fetchRemove(agent) orelse return;
        self.allocator.free(kv.key);
        _ = self.event_log.append(.{ .kind = .wake_cancelled, .agent = agent, .generation = kv.value }) catch 0;
    }

    pub const WakeOutcome = enum { delivered, stalled };

    /// RFC-0005 C-WAKE-ACK: record a workbench-reported wake receipt on
    /// the event log. Delivered resolves the outstanding candidate (the
    /// woken agent owns draining its mailbox now); stalled keeps it —
    /// mail is still waiting, and retry-once-then-badge is the
    /// workbench's discipline, not the hub's.
    pub fn recordWakeReport(self: *HubState, agent: []const u8, generation: ?u64, outcome: WakeOutcome) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const gen = generation orelse (self.wake_pending.get(agent) orelse 0);
        const kind: events.EventKind = switch (outcome) {
            .delivered => .wake_delivered,
            .stalled => .wake_stalled,
        };
        _ = self.event_log.append(.{ .kind = kind, .agent = agent, .generation = gen }) catch 0;
        if (outcome == .delivered) {
            if (self.wake_pending.fetchRemove(agent)) |kv| self.allocator.free(kv.key);
        }
    }

    pub const BindOutcome = enum {
        /// Fresh durable binding (identity upgrade on this connection).
        bound,
        /// The durable id moved here from another live connection.
        rehomed,
        /// This connection already holds the id — metadata refresh only.
        refreshed,
        /// True fragment collision (same derived id, different
        /// resume_ref): binding REFUSED, caller keeps the pane identity
        /// (RFC-0008 C-IDENTITY).
        collision,
    };

    /// RFC-0008 C-REHOME: bind a durable identity to `conn`. Handles the
    /// same-connection identity UPGRADE (ends the pane-id registration
    /// with a synthesized unregister) and the cross-connection RE-HOME
    /// (displaces the previous holder back to its fallback pane identity,
    /// notified over its own connection). All mutations + events atomic
    /// under presence_mutex (write-time invariant).
    pub fn bindDurableIdTracked(
        self: *HubState,
        conn: *Connection,
        durable_id: []const u8,
        resume_ref: []const u8,
    ) !BindOutcome {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());

        // Collision guard: the id is already bound to a DIFFERENT full
        // resume_ref — refuse; the later claimant keeps its pane id.
        if (self.agent_registry.map.get(durable_id)) |existing| {
            if (existing.resume_ref) |held_ref| {
                if (!std.mem.eql(u8, held_ref, resume_ref)) {
                    log.warn("durable id collision on {s} — rejecting to fallback", .{durable_id});
                    // THE CASE C-IDENTITY NAMES EXPLICITLY: a true
                    // fragment collision, different resume_ref and same
                    // first eight characters. Evented under the id the
                    // agent will keep answering to.
                    _ = self.event_log.append(.{
                        .kind = .identity_rejected,
                        .agent = durable_id,
                        .reason = "fragment_collision",
                    }) catch 0;
                    return .collision;
                }
            }
        }

        // Current holder (if any), WITHOUT retaining: we hold the
        // presence mutex, so bindings cannot move under us.
        const old_holder: ?*Connection = blk: {
            self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
            defer self.routing_table.mutex.unlock(io_mod.get());
            break :blk self.routing_table.map.get(durable_id);
        };
        if (old_holder == conn) return .refreshed;

        // 1. End THIS connection's current binding (identity upgrade of
        //    its pane id). Events append before the old slice is freed.
        var prev_buf: [128]u8 = undefined;
        var prev_id: ?[]const u8 = null;
        {
            conn.mutex.lock(io_mod.get()) catch unreachable;
            defer conn.mutex.unlock(io_mod.get());
            if (conn.bound_id) |b| {
                if (b.len <= prev_buf.len and !std.mem.eql(u8, b, durable_id)) {
                    @memcpy(prev_buf[0..b.len], b);
                    prev_id = prev_buf[0..b.len];
                }
            }
        }
        if (prev_id) |prev| {
            {
                self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
                defer self.routing_table.mutex.unlock(io_mod.get());
                if (self.routing_table.map.get(prev)) |holder| {
                    if (holder == conn) _ = self.routing_table.removeOwnedLocked(prev);
                }
                self.agent_registry.remove(prev);
            }
            const prev_gen: ?u64 = if (self.generations.fetchRemove(prev)) |kv| pg: {
                self.allocator.free(kv.key);
                break :pg kv.value;
            } else null;
            _ = self.event_log.append(.{ .kind = .agent_unregistered, .agent = prev, .generation = prev_gen }) catch 0;
            // RFC-0005: the pane id's generation ended — its candidate
            // dies with it (no inherited wake debt).
            self.wakeCancelLocked(prev);
            // C-REHOME: mail addressed to the pane identity belongs to
            // the occupant now claiming its durable identity — merge.
            self.mailbox.merge(prev, durable_id) catch |err| {
                log.err("mailbox merge {s}->{s} failed: {any} — mail queued under the old identity will never reach the agent", .{ prev, durable_id, err });
            };
        }

        // 2. Displace the previous holder (re-home).
        var outcome: BindOutcome = .bound;
        if (old_holder) |old| {
            outcome = .rehomed;
            // End the durable id's old generation.
            const old_gen: ?u64 = if (self.generations.fetchRemove(durable_id)) |kv| og: {
                self.allocator.free(kv.key);
                break :og kv.value;
            } else null;
            _ = self.event_log.append(.{ .kind = .agent_unregistered, .agent = durable_id, .generation = old_gen }) catch 0;
            // RFC-0005: generation change cancels the durable id's
            // outstanding candidate (the fresh-edge rule below may
            // immediately mint a new one under the new generation).
            self.wakeCancelLocked(durable_id);
            // Revert the old connection to its fallback pane identity
            // with a fresh generation, and notify it.
            const fallback_owned: ?[]const u8 = fb: {
                old.mutex.lock(io_mod.get()) catch unreachable;
                defer old.mutex.unlock(io_mod.get());
                break :fb old.fallback_id;
            };
            if (fallback_owned) |fallback| {
                const reverted = old.rebindTo(fallback) catch fallback;
                {
                    self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
                    defer self.routing_table.mutex.unlock(io_mod.get());
                    _ = self.routing_table.putOwnedLocked(reverted, old) catch {};
                }
                const fgen = self.event_log.next_seq;
                const fkey = self.allocator.dupe(u8, reverted) catch null;
                if (fkey) |k| self.generations.put(k, fgen) catch self.allocator.free(k);
                _ = self.event_log.append(.{ .kind = .agent_registered, .agent = reverted, .generation = fgen }) catch 0;
                _ = self.event_log.append(.{ .kind = .identity_displaced, .agent = durable_id, .peer = reverted }) catch 0;
                // AND THE PEERS ARE TOLD, because this is a local bind
                // like any other ([[RFC-0009]] C-DIRECTORY owes an
                // incremental update "when an identity is bound or ends
                // locally"). The pane id was withdrawn from every peer at
                // this connection's OWN earlier upgrade, so without this
                // it is hosted here and known nowhere: the displaced
                // agent's cross-machine mail is refused `origin_refused`
                // — the far side requires a directory entry for a stamped
                // source — and a peer addressing it is answered
                // `unknown`.
                //
                // THREE PLACES IN THIS FILE BIND AN IDENTITY LOCALLY and
                // each owes this: `registerAgentTracked`, the upgrade
                // below, and here. Two of them were fixed one at a time,
                // each after a review pointed at that branch; the rule is
                // the function's, not the branch's, and a fourth bind
                // added later owes it too.
                self.broadcastDirectoryLocked(reverted, true);
                // Displacement notice over the old connection (RFC-0008
                // C-REHOME: surfaces must stay truthful).
                var notice_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer notice_arena.deinit();
                old.enqueueEnvelope(notice_arena.allocator(), .{
                    .@"type" = "identity_displaced",
                    .id = "hub-displace",
                    .source = "hub",
                    .target = reverted,
                    .payload = .null,
                }) catch {};
            }
        }

        // 3. Bind the durable id to this connection. The routing table
        //    takes its own copy of the name: this used to borrow the
        //    connection's bound_id on the reasoning that a rebind always
        //    removes the entry first, which is true of a rebind and not
        //    of a connection that simply goes away while another one
        //    holds its former entry ([[WI-2026-08-17-005]]).
        const owned = try conn.rebindTo(durable_id);
        {
            self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
            defer self.routing_table.mutex.unlock(io_mod.get());
            _ = try self.routing_table.putOwnedLocked(owned, conn);
        }
        const gen = self.event_log.next_seq;
        const gkey = try self.allocator.dupe(u8, durable_id);
        self.generations.put(gkey, gen) catch |err| {
            self.allocator.free(gkey);
            return err;
        };
        _ = self.event_log.append(.{ .kind = .agent_registered, .agent = durable_id, .generation = gen }) catch 0;
        if (prev_id) |prev| {
            _ = self.event_log.append(.{ .kind = .identity_upgraded, .agent = durable_id, .peer = prev }) catch 0;
        }
        if (!self.durable_ids.contains(durable_id)) {
            const dkey = try self.allocator.dupe(u8, durable_id);
            self.durable_ids.put(dkey, {}) catch self.allocator.free(dkey);
        }
        // THE PEERS HAVE TO BE TOLD, BOTH HALVES ([[RFC-0009]]
        // C-DIRECTORY: "afterwards an incremental update when an identity
        // is bound or ends locally"). This function does both — the pane
        // id ends here and the durable id is bound here — and it sent
        // neither, because the only two callers of the broadcast were
        // `registerAgentTracked` and `unregisterAgent`, and the upgrade
        // path goes through neither: it removes the pane id from the
        // routing table directly rather than through `unregisterAgent`.
        //
        // IT IS THE ORDINARY PATH, NOT AN EDGE. Every agent registering
        // with a `resume_ref` arrives here, and a link is normally
        // already up — the human connects the host, then opens panes. So
        // a peer's directory kept a pane id this hub no longer hosts and
        // never learnt the durable id: a send to the durable name was
        // answered `unknown`, which tells the human they typo'd the name
        // of an agent standing right there; mail FROM it was refused
        // `origin_refused`, because the far side requires a directory
        // entry for a stamped source; and its relayed presence was
        // declined for the same reason. Only tearing the link down and
        // letting `advertiseAllTo` replace the view repaired it, which is
        // why this stayed invisible: the bind-before-link-up order works.
        if (prev_id) |prev| self.broadcastDirectoryLocked(prev, false);
        self.broadcastDirectoryLocked(durable_id, true);
        // The identity set and any merged mail are both promises.
        self.persistLocked();
        // Mail waiting for this identity (offline queueing or an upgrade
        // merge): nudge the new home so a parked recv --wait wakes, and
        // mint a wake candidate — RFC-0005 C-WAKE-TRIGGER's fresh-edge
        // rule: registration/re-home with a non-empty mailbox counts as
        // an empty→non-empty edge under the NEW generation.
        if (self.mailbox.count(durable_id) > 0) {
            var nudge_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer nudge_arena.deinit();
            conn.enqueueEnvelope(nudge_arena.allocator(), .{
                .@"type" = "mail_nudge",
                .id = "hub-nudge",
                .source = "hub",
                .target = durable_id,
                .payload = .null,
            }) catch {};
            self.wakeCandidateLocked(durable_id, gen);
        }
        return outcome;
    }

    /// Update agent metadata and append the covering agent_registered
    /// event (existing generation) — a live re-register's metadata change
    /// is visible in list_agents, so the invariant requires the event
    /// (RFC-0004 C-EVENT-LOG).
    pub fn updateAgentTracked(self: *HubState, agent_id: []const u8, info: AgentInfo) !void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        try self.agent_registry.update(agent_id, info);
        const gen = self.generations.get(agent_id) orelse 0;
        _ = self.event_log.append(.{
            .kind = .agent_registered,
            .agent = agent_id,
            .generation = gen,
            .tool = info.tool,
            .project = info.project,
            .session = info.session,
            .resume_ref = info.resume_ref,
        }) catch 0;
    }

    /// Apply one presence signal through the acceptance rules and append
    /// the status_changed event when the merged status actually moved.
    pub fn applyStatusSignal(self: *HubState, agent_id: []const u8, class: protocol.SignalClass, new: protocol.Status) !SignalResult {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        // Phantom guard (WI-2026-08-11-019): signals for ids that hold no
        // live registration are refused — applySignal would otherwise
        // resurrect a registry entry for an unregistered id (invisible in
        // list_agents but real memory and a lie in the merge state).
        if (!self.generations.contains(agent_id)) {
            return .{ .accepted = false, .changed = false, .old = .unknown, .new = .unknown };
        }
        const result = try self.agent_registry.applySignal(agent_id, class, new);
        if (result.accepted and result.changed) {
            _ = self.event_log.append(.{
                .kind = .agent_status_changed,
                .agent = agent_id,
                .old_state = result.old,
                .new_state = result.new,
                .class = class,
            }) catch 0;
            // [[RFC-0009]] C-PRESENCE: the HOSTING hub owns the conclusion,
            // so the moment a merged status actually moves is the moment
            // peers learn about it. Emitted from inside the same critical
            // section that appends the event, for the same reason the event
            // is: a visible change and its announcement must not be
            // separable. On CHANGE only — a timer would relay a conclusion
            // the peer already holds, and RFC-0004's whole point is that
            // presence is edge-driven rather than polled.
            self.relayPresenceLocked(agent_id, result.new);
        }
        return result;
    }

    /// Tell every peer about one local identity's merged status. Caller
    /// holds presence_mutex.
    fn relayPresenceLocked(self: *HubState, agent_id: []const u8, status: protocol.Status) void {
        if (self.peer_links.count() == 0) return;
        const me = self.peer_id orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Qualified exactly as the directory advertised it (C-IDENTITY-SCOPE):
        // the receiver keys its directory on that form, so an unqualified
        // fallback id here would land on nothing and the status would be
        // silently dropped.
        const wire_id = federation.qualify(a, agent_id, me) catch return;
        var payload = json.ObjectMap.empty;
        payload.put(a, "state", .{ .string = status.toString() }) catch return;
        var it = self.peer_links.valueIterator();
        while (it.next()) |link| {
            // NEVER invoke a behaviour the peer did not declare. Sending
            // to a peer that cannot receive it is not harmless: it makes
            // the local side believe presence is flowing, which is the
            // confusion this whole negotiation exists to end.
            if (!link.caps.has(.presence_relay)) continue;
            link.conn.enqueueEnvelope(a, .{
                .@"type" = "relay_presence",
                .id = "relay-presence",
                .source = me,
                .target = wire_id,
                .payload = .{ .object = payload },
            }) catch {};
        }
    }

    /// Send the CURRENT status of every local identity to one peer. Called
    /// once on link-up so a fresh link starts consistent instead of
    /// learning only about identities that happen to change afterwards —
    /// the same reason advertiseAllTo exists for the directory. Without
    /// it, an agent that reached `waiting` before the link came up would
    /// sit at `unknown` on the peer until it moved again, which for a
    /// waiting agent may be never.
    pub fn relayPresenceAllTo(self: *HubState, conn: *Connection, peer_caps: federation.CapabilitySet) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (!peer_caps.has(.presence_relay)) return;
        const me = self.peer_id orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const ids = self.routing_table.agentIds(a) catch return;
        for (ids) |id| {
            const info = self.agent_registry.get(id, a) orelse continue;
            if (info.status == .unknown) continue; // nothing to say yet
            const wire_id = federation.qualify(a, id, me) catch continue;
            var payload = json.ObjectMap.empty;
            payload.put(a, "state", .{ .string = info.status.toString() }) catch continue;
            conn.enqueueEnvelope(a, .{
                .@"type" = "relay_presence",
                .id = "relay-presence-all",
                .source = me,
                .target = wire_id,
                .payload = .{ .object = payload },
            }) catch {};
        }
    }

    /// Does THIS hub host the identity? One definition, used both by
    /// delivery (which must never forward a local identity's mail to a
    /// peer) and by the C-BOUNDARIES checks (which must never let a peer
    /// speak for one). Caller holds presence_mutex.
    pub fn hostsLocallyLocked(self: *HubState, identity: []const u8) bool {
        if (self.generations.contains(identity)) return true;
        if (self.durable_ids.contains(identity)) return true;
        if (self.mailbox.count(identity) > 0) return true;
        self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
        defer self.routing_table.mutex.unlock(io_mod.get());
        return self.routing_table.map.contains(identity);
    }

    /// Record a forward this hub is about to accept, or say why not.
    /// Takes presence_mutex, like every other store here.
    pub fn admitForward(self: *HubState, peer: []const u8, forward_id: []const u8) federation.ForwardSeen.Admit {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        _ = self.forward_seen.expire(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());
        return self.forward_seen.admit(peer, forward_id, std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds()) catch .at_capacity;
    }

    /// How a peer answered a forward, or that it has not yet.
    pub const ForwardAnswer = union(enum) {
        waiting,
        acked,
        /// The peer's own reason code, owned by this map.
        nacked: []const u8,
    };

    /// What the sender learned before its patience ran out.
    pub const ForwardVerdict = union(enum) {
        acked,
        nacked: []const u8,
        /// Nobody answered inside the bound. C-DELIVERY: silence is an
        /// UNKNOWN OUTCOME and is never read as success or refusal.
        silence,
    };

    fn registerForward(self: *HubState, forward_id: []const u8) void {
        const owned = self.allocator.dupe(u8, forward_id) catch return;
        self.forward_mutex.lock(io_mod.get()) catch unreachable;
        defer self.forward_mutex.unlock(io_mod.get());
        self.pending_forwards.put(owned, .waiting) catch self.allocator.free(owned);
    }

    /// A peer answered. Called from the relay reader thread.
    pub fn completeForward(self: *HubState, forward_id: []const u8, ok: bool, reason: []const u8) void {
        self.forward_mutex.lock(io_mod.get()) catch unreachable;
        defer self.forward_mutex.unlock(io_mod.get());
        const e = self.pending_forwards.getEntry(forward_id) orelse return;
        if (e.value_ptr.* != .waiting) return;
        if (ok) {
            e.value_ptr.* = .acked;
        } else {
            const owned = self.allocator.dupe(u8, reason) catch "unavailable";
            e.value_ptr.* = .{ .nacked = owned };
        }
    }

    /// Wait for the peer's answer, or for the bound to elapse.
    ///
    /// POLLED RATHER THAN PARKED ON A CONDITION, because this waits
    /// WITHOUT presence_mutex and a condition would need a second lock
    /// order to reason about for the sake of a five-second wait that
    /// almost always ends in milliseconds. The reason string is copied
    /// into the caller's arena and the entry goes.
    pub fn awaitForward(self: *HubState, arena: Allocator, forward_id: []const u8, bound_ms: i64) ForwardVerdict {
        const io = io_mod.get();
        const deadline = std.Io.Timestamp.now(io, .real).toMilliseconds() + bound_ms;
        while (true) {
            {
                self.forward_mutex.lock(io) catch unreachable;
                defer self.forward_mutex.unlock(io);
                if (self.pending_forwards.getEntry(forward_id)) |e| {
                    switch (e.value_ptr.*) {
                        .waiting => {},
                        .acked => {
                            self.dropPendingLocked(forward_id);
                            return .acked;
                        },
                        .nacked => |r| {
                            const copy = arena.dupe(u8, r) catch "unavailable";
                            self.allocator.free(r);
                            self.dropPendingLocked(forward_id);
                            return .{ .nacked = copy };
                        },
                    }
                } else return .silence;
            }
            if (std.Io.Timestamp.now(io, .real).toMilliseconds() >= deadline) break;
            io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch break;
        }
        self.forward_mutex.lock(io) catch unreachable;
        defer self.forward_mutex.unlock(io);
        self.dropPendingLocked(forward_id);
        return .silence;
    }

    /// Caller holds forward_mutex.
    fn dropPendingLocked(self: *HubState, forward_id: []const u8) void {
        if (self.pending_forwards.fetchRemove(forward_id)) |kv| self.allocator.free(kv.key);
    }

    /// C-BOUNDARIES: "A relay peer speaks for the identities IT HOSTS and
    /// no others." Both halves of the refusal, in one place:
    ///   - an identity this hub hosts locally, and
    ///   - an identity a DIFFERENT peer has advertised.
    /// A peer claiming either is malfunctioning or hostile, and the clause
    /// says the frame is not routable in both cases.
    pub fn peerMaySpeakFor(self: *HubState, peer: []const u8, identity: []const u8) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (self.hostsLocallyLocked(identity)) return false;
        // THE ADVERTISEMENT IS WHAT ADMITS AN IDENTITY ([[RFC-0009]]
        // C-BOUNDARIES). A missing entry used to fall through to `true`,
        // which made this a residual — not ours, not another peer's — so
        // a source NOBODY had ever claimed passed it, and a local agent
        // saw mail from a `from` no hub in the fleet resolves. The
        // presence path refuses the same evidence for the same reason.
        const entry = self.directory.lookup(identity) orelse return false;
        return mem.eql(u8, entry.peer, peer);
    }

    /// WHERE THE MESSAGE CAME FROM, because it decides whether this hub
    /// may send it onward ([[RFC-0009]] C-DELIVERY: "a relayed message is
    /// never re-forwarded"). An enum rather than a bool so every call
    /// site says which it is.
    pub const Origin = enum { submitted, relayed };

    /// RFC-0008 C-MAILBOX + [[RFC-0009]] C-DELIVERY: deliver locally what is
    /// local, forward to the hosting peer what is not, spool what cannot be
    /// forwarded yet.
    ///
    /// THIS RETURNS AN ENUM AND NOT A BOOL, deliberately. The pre-federation
    /// code computed one `known` boolean and raised error.UnknownTarget when
    /// it was false; folding peer knowledge into that boolean is the obvious
    /// move and is wrong, because a bool cannot say "some peer is
    /// unreachable, so I cannot tell" — and reporting that case as `unknown`
    /// turns a temporary partition into a permanent-looking typo error,
    /// which is precisely the silent failure C-DELIVERY forbids.
    pub fn mailboxDeliver(
        self: *HubState,
        target: []const u8,
        msg_id: []const u8,
        raw_envelope: []const u8,
        origin: Origin,
    ) !Delivery {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());

        const hosted_conn: ?*Connection = blk: {
            self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
            defer self.routing_table.mutex.unlock(io_mod.get());
            break :blk self.routing_table.map.get(target);
        };
        const known_locally = hosted_conn != null or self.hostsLocallyLocked(target);

        if (!known_locally) {
            // Not ours. Ask the directory before concluding anything: an
            // identity on a machine we cannot see is not a typo.
            // ONE HOP, AND THIS IS WHERE IT IS ENFORCED ([[RFC-0009]]
            // C-DELIVERY: "a relayed message is never re-forwarded";
            // C-BOUNDARIES: "A hub MUST NOT re-advertise, re-forward, or
            // otherwise speak for what a peer told it").
            //
            // THE CHECK USED TO BE A COMMENT. `handleRelayForward` said
            // in as many words that re-forwarding "would be the multi-hop
            // routing this version deliberately does not specify" — and
            // said it AFTER this function had already written the second
            // hop, so the switch it introduced only decided what to tell
            // the sender. The hub forwarded the message to a third peer
            // AND answered `not_hosted`, so the sender released its copy
            // for a message it believed refused. Only the QUALIFIED
            // target was guarded (C-IDENTITY-SCOPE, `target_refused`); a
            // bare durable id — which that clause requires be advertised
            // UNQUALIFIED — walked straight through.
            //
            // The case is not contrived: it is exactly the window
            // C-DIRECTORY's incremental `remove` closes, an agent
            // re-homing away from us while the sending peer's directory
            // is still stale. If it were unreachable, `not_hosted` would
            // be dead vocabulary.
            if (origin == .relayed) return .{ .outcome = .unknown };
            if (self.directory.lookup(target)) |entry| {
                // ADDRESSED BY NOBODY ([[RFC-0009]] C-DIRECTORY). Two live
                // peers claim it, and picking one would misroute every
                // message between two machines that each believe the
                // identity is theirs.
                if (entry.conflicted()) return .{ .outcome = .conflicted };
                if (entry.reachable) {
                    if (self.forwardToPeerLocked(entry.peer, target, raw_envelope, null, true)) |fid| {
                        // WRITTEN, NOT ANSWERED. The caller waits and only
                        // then knows whether this is `forwarded`.
                        return .{ .outcome = .forwarded, .forward_id = fid };
                    }
                    // The link is nominally up but the write did not take.
                    // C-DELIVERY: an unacknowledged forward is spooled,
                    // never assumed delivered.
                }
                const push = self.spool.push(
                    entry.peer,
                    msg_id,
                    target,
                    raw_envelope,
                    std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
                    // NOTHING HAS GONE OUT, so there is no id to reuse.
                    // The first flush mints one and records it, and every
                    // attempt after that carries it again.
                    null,
                    // NOT AN OUTCOME. Failing to hold the copy is this
                    // hub failing, and none of C-DELIVERY's six says
                    // that: `unknown` would tell the sender their target
                    // is a typo when this hub holds an entry for it. The
                    // error propagates and the caller answers with a
                    // transport failure instead of a delivery status.
                ) catch |err| return err;
                // SAID OUT LOUD ([[RFC-0009]] C-DELIVERY). A message the
                // sender was told was held, dropped to make room for a
                // newer one, is a promise this hub broke — and one that
                // vanished silently is indistinguishable from one that
                // was delivered.
                if (push == .dropped_oldest) {
                    log.err(
                        "spool for {s} full — DROPPED the oldest message, which a sender was already told was held",
                        .{entry.peer},
                    );
                    // AND SAID WHERE ANYTHING CAN HEAR IT. A log line is
                    // read by whoever is looking at that machine's log,
                    // which for a hub on somebody else's host is nobody.
                    // The TTL drop has minted an event since it existed;
                    // this one — the same promise broken, under pressure
                    // rather than over time — reached no consumer at all
                    // ([[RFC-0009]] C-EVENT-LOCALITY: a hub mints local
                    // events for the promises it breaks).
                    _ = self.event_log.append(.{
                        .kind = .spool_evicted,
                        .agent = msg_id,
                        .peer = entry.peer,
                    }) catch 0;
                }
                self.persistLocked();
                return .{ .outcome = .spooled };
            }
            // NO ENTRY ANYWHERE IS A TYPO, and it can be said plainly now
            // that a dropped link RETAINS its entries marked unreachable
            // ([[RFC-0009]] C-DIRECTORY): a name on a sleeping machine
            // still HAS an entry and is answered `spooled` above, so what
            // reaches here is a name no peer has ever claimed. The old
            // `indeterminate` covered the gap when entries vanished with
            // their link, and there is no longer a gap for it to cover.
            return .{ .outcome = .unknown };
        }

        const was_empty = self.mailbox.count(target) == 0;
        try self.mailbox.append(target, raw_envelope);
        // RFC-0005 C-WAKE-TRIGGER: the empty→non-empty edge mints ONE
        // wake candidate — only for a currently registered identity (an
        // offline durable gets its candidate from the fresh-edge rule
        // when it registers/re-homes).
        if (was_empty) {
            if (self.generations.get(target)) |gen| self.wakeCandidateLocked(target, gen);
        }
        // Persist BEFORE the caller acks: "queued" has to mean durable,
        // or the ack is a promise the hub cannot keep across a restart.
        self.persistLocked();
        if (hosted_conn) |hc| {
            var nudge_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer nudge_arena.deinit();
            hc.enqueueEnvelope(nudge_arena.allocator(), .{
                .@"type" = "mail_nudge",
                .id = "hub-nudge",
                .source = "hub",
                .target = target,
                .payload = .null,
            }) catch {};
        }
        return .{ .outcome = .delivered, .hosted = hosted_conn != null };
    }

    // -- Credential-bound tool forwarding ([[ADR-0008]] decision 6) ----------

    /// Bound on outstanding forwarded tool requests. A workbench that
    /// accepts frames and never answers would otherwise pin one connection
    /// per request forever; refusing past the bound is visible, whereas a
    /// slow leak is not.
    pub const max_pending_tools: usize = 256;

    /// Broadcast a tool request to the workbench and park the requester's
    /// connection under its request id. Returns false when there is no
    /// workbench to forward to — the caller then refuses IMMEDIATELY.
    /// Queueing is rejected by design: a task claimed hours after it was
    /// asked for is worse than a refusal, because the world has moved on.
    pub fn toolForward(
        self: *HubState,
        requester: []const u8,
        request_id: []const u8,
        conn: *Connection,
        envelope: protocol.Envelope,
    ) bool {
        _ = requester;
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (self.event_log.subscriberCount() == 0) return false;
        if (self.pending_tools.count() >= max_pending_tools) return false;
        const key = self.allocator.dupe(u8, request_id) catch return false;
        conn.retain();
        self.pending_tools.put(key, .{
            .conn = conn,
            .parked_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
        }) catch {
            conn.release();
            self.allocator.free(key);
            return false;
        };
        // TO ONE, NOT TO ALL ([[RFC-0003:C-HUB-ROLE]]). Every workbench
        // that received this EXECUTED it, so a hub with two attached
        // wrote every comment twice and filed every new issue twice
        // ([[WI-2026-09-03-014]]). `pending_tools` above already parks
        // ONE requester per request id; the fan-out contradicted it, and
        // discarding the second receipt hid the second write rather than
        // preventing it.
        if (!self.event_log.dispatchOne(envelope)) {
            // Nobody took it, so nothing will answer: unpark rather than
            // leave a requester waiting on a workbench that is not there.
            if (self.pending_tools.fetchRemove(request_id)) |kv| {
                kv.value.conn.release();
                self.allocator.free(kv.key);
            }
            return false;
        }
        return true;
    }

    /// Deliver the workbench's answer to the parked requester. Returns
    /// false when nobody is waiting under that id — a late or duplicate
    /// receipt, which is dropped rather than guessed at.
    pub fn routeToolResponse(self: *HubState, request_id: []const u8, response: protocol.Envelope) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const kv = self.pending_tools.fetchRemove(request_id) orelse return false;
        defer self.allocator.free(kv.key);
        defer kv.value.conn.release();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        kv.value.conn.enqueueEnvelope(arena.allocator(), response) catch return false;
        return true;
    }

    // -- [[RFC-0009]] federation --------------------------------------------

    /// A relay link came up. Registers the link and clears the tombstones
    /// its identities carry — the peer will re-advertise, but presence and
    /// delivery must stop reporting unreachable the moment it can.
    pub fn peerLinkUp(
        self: *HubState,
        peer: []const u8,
        conn: *Connection,
        dialed_port: u16,
        version: u16,
        caps: federation.CapabilitySet,
    ) !void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        // OR THIS HUB'S OWN ([[RFC-0009]] C-BOUNDARIES). A hub's own id is
        // held by no LINK, so the live-link test alone admitted the one
        // peer that must never be admitted — and C-BOUNDARIES spells out
        // that exact gap in the sentence stating the rule. The cause is
        // routine rather than adversarial ([[RFC-0010]] C-PEER-IDENTITY):
        // a disk image copied, a backup restored onto other hardware, and
        // two machines mint nothing because both already have the id.
        //
        // WHAT IT COSTS if admitted: the peer speaks for identities this
        // hub hosts, its advertisements are attributed to us, and a
        // qualifier naming us is stripped and delivered locally — every
        // boundary in this document keyed on "is that peer me" answers
        // wrong at once.
        if (self.peer_id) |me| {
            if (mem.eql(u8, me, peer)) return error.PeerIdInUse;
        }
        if (self.peer_links.contains(peer)) return error.PeerIdInUse;
        const key = try self.allocator.dupe(u8, peer);
        errdefer self.allocator.free(key);
        try self.peer_links.put(key, .{
            .conn = conn,
            .dialed_port = dialed_port,
            .version = version,
            .caps = caps,
        });
        // ENDPOINT CONTINUITY. A different id at a port we have used
        // before means the machine there was rebuilt (restored backup,
        // fresh container, lost identity file). Its old entries advertise
        // the SAME durable agent ids as its new ones — durable ids are
        // globally meaningful and do not change with the machine — so
        // keeping both would trip C-DIRECTORY's conflict rule and make
        // every agent on that machine unroutable until the tombstones
        // expired, with nothing a human could do about it.
        if (dialed_port != 0) {
            if (self.endpoint_ids.get(dialed_port)) |previous| {
                if (!mem.eql(u8, previous, peer)) {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const dropped = self.directory.forgetPeer(arena.allocator(), previous) catch &.{};
                    for (dropped) |identity| {
                        _ = self.event_log.append(.{
                            .kind = .directory_identity_removed,
                            .agent = identity,
                            .peer = previous,
                        }) catch 0;
                    }
                    self.spool.dropPeer(previous);
                    log.info(
                        "relay: endpoint {d} changed identity {s} -> {s}; dropped {d} stale entries",
                        .{ dialed_port, previous, peer, dropped.len },
                    );
                }
            }
            // `catch peer` here would have stored the CALLER's slice in a
            // map whose values this struct owns and frees. peer.zig frees
            // that slice when the link drops, so the map would then hold a
            // dangling pointer: read by the continuity check above on the
            // next link to this port, and freed a second time by deinit.
            // Losing endpoint continuity for one link is a degradation;
            // handing the allocator someone else's memory is not.
            if (self.allocator.dupe(u8, peer)) |ep_key| {
                if (self.endpoint_ids.fetchPut(dialed_port, ep_key)) |maybe_old| {
                    if (maybe_old) |old| self.allocator.free(old.value);
                } else |_| {
                    // The map is unchanged, so ep_key belongs to nobody.
                    self.allocator.free(ep_key);
                    log.warn("relay: could not record endpoint {d} -> {s}; continuity is lost for this link", .{ dialed_port, peer });
                }
            } else |_| {
                log.warn("relay: could not record endpoint {d} -> {s}; continuity is lost for this link", .{ dialed_port, peer });
            }
        }
        // The port travels on the event so the workbench can key its
        // redial on the id the PEER reported — under [[RFC-0010]] that id
        // is not derivable from anything on the workbench's side.
        _ = self.event_log.append(.{
            .kind = .peer_link_up,
            .agent = peer,
            .peer = peer,
            .generation = if (dialed_port != 0) dialed_port else null,
        }) catch 0;
    }

    /// A relay link dropped. TOMBSTONES the peer's identities — never
    /// discards them: a hub that forgets who hosted an identity cannot
    /// spool toward it and cannot report `unknown` status for it.
    pub fn peerLinkDown(self: *HubState, peer: []const u8) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (self.peer_links.fetchRemove(peer)) |kv| self.allocator.free(kv.key);
        _ = self.directory.linkDown(peer, std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());
        _ = self.event_log.append(.{ .kind = .peer_link_down, .agent = peer, .peer = peer }) catch 0;
    }

    /// Record a peer's advertisement, minting the LOCAL event that makes
    /// the identity visible to subscribers and waitable by `synapty wait`.
    pub fn directoryAdvertise(
        self: *HubState,
        peer: []const u8,
        identity: []const u8,
    ) !federation.Directory.Advertise {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        // C-BOUNDARIES half one. Checked HERE and not in Directory,
        // because Directory holds only remote entries and so cannot see
        // the collision at all.
        if (self.hostsLocallyLocked(identity)) return .local_conflict;
        const result = try self.directory.advertise(peer, identity);
        if (result == .added) {
            _ = self.event_log.append(.{
                .kind = .directory_identity_added,
                .agent = identity,
                .peer = peer,
            }) catch 0;
        }
        return result;
    }

    /// THE PEER'S WHOLE VIEW, MADE EQUAL TO WHAT IT JUST SENT
    /// ([[RFC-0009]] C-DIRECTORY: a full set on link-up REPLACES the
    /// receiver's view of that peer).
    ///
    /// WHAT THIS FIXES: entries are TOMBSTONED when a link drops rather
    /// than discarded, and the clause says the peer re-advertises on
    /// reconnect — which is the moment the retained set is supposed to be
    /// corrected. Without a distinguishable replace it never was, so an
    /// identity that ended while the peer was away stayed in the
    /// directory, stayed addressable, and mail sent to it was spooled for
    /// a machine that would never claim it again.
    ///
    /// WHETHER THIS PEER MAY RETRACT AN ENTRY IS `withdraw`'S QUESTION
    /// AND IS NOT ASKED AGAIN HERE. A first draft filtered the candidate
    /// set by "does this peer claim it", which is the same rule Directory
    /// already applies — and a mutation removing the filter changed no
    /// behaviour and failed no test, which is what a second implementation
    /// of one rule looks like from the outside. So every entry the full
    /// set does not name is offered to `withdraw`, and `withdraw` decides:
    /// another peer's identity is left alone, and a CONTESTED entry the
    /// two of them share drops only this peer's side, leaving the rival
    /// standing alone — which is how a conflict clears itself without
    /// anybody adjudicating it.
    ///
    /// ADDING GOES THROUGH `directoryAdvertise` for the same reason: every
    /// rule about a claim — this hub hosts it, another live peer claims
    /// it, the peer is at its bound — has one implementation, and a
    /// replace that reimplemented them would be a second place to drift.
    pub fn directoryReplace(
        self: *HubState,
        arena: Allocator,
        peer: []const u8,
        identities: []const []const u8,
    ) !void {
        const stale = blk: {
            self.presence_mutex.lock(io_mod.get()) catch unreachable;
            defer self.presence_mutex.unlock(io_mod.get());
            var list: std.ArrayList([]const u8) = .empty;
            var it = self.directory.map.iterator();
            while (it.next()) |e| {
                var still_hosted = false;
                for (identities) |id| {
                    if (mem.eql(u8, id, e.key_ptr.*)) {
                        still_hosted = true;
                        break;
                    }
                }
                if (!still_hosted) try list.append(arena, try arena.dupe(u8, e.key_ptr.*));
            }
            break :blk try list.toOwnedSlice(arena);
        };
        for (stale) |identity| {
            if (self.directoryWithdraw(peer, identity)) {
                log.info(
                    "relay: {s} no longer hosts '{s}' — dropped on its full advertisement",
                    .{ peer, identity },
                );
            }
        }
        for (identities) |identity| {
            const result = self.directoryAdvertise(peer, identity) catch continue;
            // THE BOUND IS A FACT ABOUT THE LINK, not about the identity
            // ([[RFC-0009]] C-DIRECTORY). Reported up rather than logged
            // here, because the caller is the one holding the connection
            // it has to refuse.
            if (result == .at_capacity) return error.DirectoryOverflow;
        }
    }

    /// A DERIVATION THIS HUB REFUSED ([[RFC-0008]] C-IDENTITY). The agent
    /// keeps its pane-identity fallback and goes on running under it, so
    /// the reason has to outlive the moment: without this the only trace
    /// was a returned null and a log line, and "why is this agent still
    /// called local-1a2b" had no answer anywhere a consumer could read.
    pub fn recordIdentityRejected(self: *HubState, fallback_id: []const u8, reason: []const u8) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        _ = self.event_log.append(.{
            .kind = .identity_rejected,
            .agent = fallback_id,
            .reason = reason,
        }) catch 0;
    }

    pub fn directoryWithdraw(self: *HubState, peer: []const u8, identity: []const u8) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const removed = self.directory.withdraw(peer, identity);
        if (removed) {
            _ = self.event_log.append(.{
                .kind = .directory_identity_removed,
                .agent = identity,
                .peer = peer,
            }) catch 0;
        }
        return removed;
    }

    /// C-PRESENCE write-through. Relayed presence MUST NOT go through
    /// applyStatusSignal: that path runs the acceptance rules and refuses
    /// signals for identities this hub does not host — which is EVERY
    /// relayed conclusion, so reusing it would silently discard the whole
    /// feature. A peer relays a conclusion; this hub stores it verbatim.
    pub fn relayPresence(
        self: *HubState,
        peer: []const u8,
        identity: []const u8,
        status: protocol.Status,
    ) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const entry = self.directory.map.getPtr(identity) orelse
            return self.recordPresenceRefusalLocked(peer, identity, "not_in_directory");
        // A peer speaks for the identities IT hosts and no others.
        // REFUSED OUT LOUD, in this hub's own log: nothing travels back to
        // the peer, so a silent return left the only machine that saw the
        // attempt saying nothing about it ([[RFC-0009]] C-EVENT-LOCALITY,
        // C-BOUNDARIES).
        if (!mem.eql(u8, entry.peer, peer))
            return self.recordPresenceRefusalLocked(peer, identity, "not_its_identity");
        entry.status = status;
        _ = self.event_log.append(.{
            .kind = .peer_presence_relayed,
            .agent = identity,
            .peer = peer,
            .new_state = status,
        }) catch 0;
    }

    /// Caller holds presence_mutex.
    fn recordPresenceRefusalLocked(
        self: *HubState,
        peer: []const u8,
        identity: []const u8,
        reason: []const u8,
    ) void {
        _ = self.event_log.append(.{
            .kind = .peer_presence_refused,
            .agent = identity,
            .peer = peer,
            .reason = reason,
        }) catch 0;
    }

    /// Flush this peer's spool, spooled traffic FIRST. C-DELIVERY: without
    /// the order, a sender's later message can overtake its earlier one and
    /// nothing in the system reports it.
    pub fn flushSpoolTo(self: *HubState, peer: []const u8) usize {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        return self.flushSpoolToLocked(peer);
    }

    /// Caller holds presence_mutex. Split out because the sweep below
    /// already holds it and a promise kept only at link establishment is
    /// not kept at all.
    fn flushSpoolToLocked(self: *HubState, peer: []const u8) usize {
        // THE COPIES STAY HELD ([[RFC-0009]] C-DELIVERY: "A hub holds its
        // copy until the acknowledgement arrives, then releases it").
        //
        // This used to `take` — which frees every held copy — and then
        // write. So a `spooled` answer stopped being true the moment the
        // first flush attempt left, whether or not anything arrived: a
        // retry that was ALSO unanswered lost the message outright, and
        // `Spool.take`'s own comment claimed the caller "will re-hold
        // under the pending-ack table", which no caller did. Duplication
        // and loss are opposite failures and the forward id only settled
        // the first.
        //
        // A WRITTEN FRAME IS NOT AN ACKNOWLEDGED ONE. The release now
        // happens where the acknowledgement arrives, keyed on the forward
        // id the copy went out under.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const list = self.spool.map.getPtr(peer) orelse return 0;
        if (list.items.len == 0) return 0;
        // The ids are collected first because `forwardToPeerLocked` can
        // reallocate nothing here, but stamping does — and mutating the
        // list while iterating it is how that becomes a bug later.
        var work: std.ArrayList(struct { msg: []const u8, target: []const u8, raw: []const u8, fid: ?[]const u8 }) = .empty;
        for (list.items) |m| {
            work.append(a, .{
                .msg = a.dupe(u8, m.msg_id) catch return 0,
                .target = a.dupe(u8, m.target) catch return 0,
                .raw = a.dupe(u8, m.raw) catch return 0,
                .fid = if (m.forward_id) |f| a.dupe(u8, f) catch null else null,
            }) catch return 0;
        }
        var sent: usize = 0;
        for (work.items) |w| {
            // THE ID IT WENT OUT UNDER LAST TIME, when it has been out.
            // Without this every flush looked like a new message to the
            // peer, so a lost acknowledgement delivered it twice.
            //
            // MINTED HERE WHEN THERE IS NONE, rather than inside the
            // write, because the held copy has to learn it — and a copy
            // held under an id only the write knew would mint another on
            // the next sweep.
            const fid: []const u8 = w.fid orelse blk: {
                self.forward_seq += 1;
                const minted = federation.mintForwardId(a, self.startup_ms, self.forward_seq) catch continue;
                if (!self.spool.stampForwardId(peer, w.msg, minted)) continue;
                break :blk minted;
            };
            if (self.forwardToPeerLocked(peer, w.target, w.raw, fid, false) != null) sent += 1;
        }
        if (sent > 0) self.persistLocked();
        return sent;
    }

    /// The peer answered for a forward, so any copy still held under that
    /// id is finished with ([[RFC-0009]] C-DELIVERY).
    ///
    /// A NACK RELEASES IT TOO, and that is a judgement rather than an
    /// oversight: the peer has refused this message by name, so holding
    /// it means retrying into a refusal for the whole TTL. The refusal is
    /// logged where a silent drop would not be.
    pub fn releaseSpooled(self: *HubState, peer: []const u8, forward_id: []const u8, ok: bool) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (!self.spool.releaseByForwardId(peer, forward_id)) return;
        if (!ok) {
            log.warn(
                "relay: {s} refused a held message ({s}) — dropped rather than retried into the same refusal",
                .{ peer, forward_id },
            );
        }
        self.persistLocked();
    }

    /// How long a forwarded tool request may sit unanswered before the hub
    /// gives up on it — the workbench's budget plus the slack the hub is
    /// willing to pin a connection for, so a slow-but-honest call is never
    /// reaped out from under the agent waiting on it
    /// ([[protocol.tool_park_ms]]).
    pub const pending_tool_ttl_ms: i64 = protocol.tool_park_ms;

    /// Release requester connections parked on a tool request the
    /// workbench never answered. Without this a workbench crash pins one
    /// connection (and its fd) per outstanding request until the hub
    /// exits — bounded at max_pending_tools, but bounded is not the same
    /// as bounded AND released. Caller holds presence_mutex.
    fn reapPendingToolsLocked(self: *HubState, now_ms: i64) usize {
        var stale = std.ArrayList([]const u8).empty;
        defer stale.deinit(self.allocator);
        var it = self.pending_tools.iterator();
        while (it.next()) |e| {
            if (now_ms - e.value_ptr.parked_ms < pending_tool_ttl_ms) continue;
            stale.append(self.allocator, e.key_ptr.*) catch continue;
        }
        for (stale.items) |key| {
            const kv = self.pending_tools.fetchRemove(key) orelse continue;
            // ANSWER BEFORE LETTING GO. Releasing the connection without
            // saying anything left the caller blocked on a read that would
            // never complete — the workbench had gone or its receipt was
            // lost, and the agent waited forever for a reply nobody was
            // going to send. A park that expires is a FAILURE, and a
            // failure the caller is not told about is indistinguishable
            // from a hang.
            //
            // Best effort: if the enqueue fails the connection is already
            // gone, which is the one case where nobody is waiting.
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var payload = json.ObjectMap.empty;
            payload.put(arena.allocator(), "ok", .{ .bool = false }) catch {};
            payload.put(arena.allocator(), "error", .{
                .string = "the workbench did not answer in time",
            }) catch {};
            kv.value.conn.enqueueEnvelope(arena.allocator(), .{
                .@"type" = "tool_response",
                .id = key,
                .source = "hub",
                .target = "",
                .payload = .{ .object = payload },
            }) catch {};
            kv.value.conn.release();
            self.allocator.free(kv.key);
        }
        return stale.items.len;
    }

    /// Drop expired spool entries and expired directory tombstones,
    /// logging both, and release abandoned tool parks.
    ///
    /// THIS MUST ACTUALLY BE CALLED. Leaving it unwired is not a slow
    /// leak but a silent SPEC VIOLATION: directory tombstones never
    /// expire, so after the first peer link drop the "is any peer
    /// unreachable" test
    /// stays true for the rest of the hub's life and mailboxDeliver can
    /// never again answer
    /// `unknown` — a hub that never forgets a departed peer answers as
    /// though every name might still be on it, so a typo stops being
    /// distinguishable from a machine that has gone. The unit tests called
    /// spool.expire()/directory.expire() directly and passed throughout.
    pub fn federationSweep(self: *HubState, now_ms: i64) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // RETRY BEFORE EXPIRING, and retry at all.
        //
        // `spooled` covers two states — the hosting peer's link is down,
        // or it is up and the peer did not answer inside the bound
        // ([[RFC-0009]] C-DELIVERY) — and only the first ever got a
        // retry, because the flush ran at link establishment and nowhere
        // else. A message held because a HEALTHY peer went quiet waited
        // for a reconnect that peer had no reason to make, and died at
        // its TTL. C-DELIVERY calls the answer a promise; a promise kept
        // only when the link happens to bounce is not one.
        //
        // Before the expiry in the same pass, or a message that could
        // have gone now is dropped by a TTL it would never have reached.
        {
            var peers = std.ArrayList([]const u8).empty;
            defer peers.deinit(self.allocator);
            var it = self.peer_links.keyIterator();
            while (it.next()) |k| peers.append(self.allocator, k.*) catch continue;
            // Collected first: forwarding writes to a peer's connection,
            // and iterating a map while a write can touch it is a habit
            // that costs more than the allocation.
            for (peers.items) |peer| _ = self.flushSpoolToLocked(peer);
        }
        if (self.spool.expire(a, now_ms)) |dropped| {
            for (dropped) |msg_id| {
                _ = self.event_log.append(.{ .kind = .spool_expired, .agent = msg_id }) catch 0;
            }
            if (dropped.len > 0) self.persistLocked();
        } else |_| {}
        if (self.directory.expire(a, now_ms)) |dead| {
            for (dead) |identity| {
                _ = self.event_log.append(.{
                    .kind = .directory_identity_removed,
                    .agent = identity,
                }) catch 0;
            }
        } else |_| {}
        _ = self.reapPendingToolsLocked(now_ms);
    }

    /// Housekeeping thread body. Federation state expires on a clock, so
    /// something has to hold that clock.
    pub fn sweepLoop(self: *HubState) void {
        const io = io_mod.get();
        while (true) {
            io.sleep(std.Io.Duration.fromMilliseconds(30_000), .awake) catch return;
            self.federationSweep(std.Io.Timestamp.now(io, .real).toMilliseconds());
        }
    }

    /// Adopt this machine's MINTED, PERSISTED identity ([[RFC-0010]]
    /// C-PEER-IDENTITY) unless a peer id was already set on this instance.
    /// `suggested_label` is used only if no identity exists yet — an
    /// existing one is never overridden, because other machines may
    /// already key directory entries and spooled mail on it.
    ///
    /// This replaces naming the hub after its own hostname, which was
    /// wrong for a reason only a second machine exposes: two laptops are
    /// routinely both called "macbook-pro" and would collide on their
    /// first meeting, with the loser silently unable to peer.
    pub fn adoptMintedPeerId(self: *HubState, suggested_label: ?[]const u8) void {
        if (self.peer_id != null) return;
        var buf: [128]u8 = undefined;
        const id = @import("identity_store.zig").ensure(&buf, suggested_label) orelse return;
        self.setPeerId(id) catch {};
    }

    /// Start (or restart) an outbound relay link to the peer reachable on
    /// this loopback port. Fire-and-forget on its own thread: the dial
    /// blocks, and a hub must not stop routing while one peer is slow to
    /// answer. Redialing an already-linked peer is harmless — the second
    /// handshake is refused for the duplicate peer id, which is the
    /// same rule that catches two machines claiming one name.
    pub fn dialPeer(self: *HubState, port: u16) void {
        const peer_mod = @import("peer.zig");
        _ = self.dial_threads.reap();
        self.dial_threads.spawn(peer_mod.dialAndServe, .{
            peer_mod.DialArgs{ .state = self, .port = port },
        }) catch |err| {
            std.log.scoped(.hub).warn("relay: cannot spawn dial thread for 127.0.0.1:{d}: {any}", .{ port, err });
            return;
        };
    }

    /// Set this hub's peer id. Owned by the hub — callers pass a borrowed
    /// slice.
    ///
    /// NOT "the human's host label, lowercased", which this said and which
    /// [[RFC-0010]] C-PEER-IDENTITY superseded: the id is
    /// `<label>-<suffix>`, minted once and persisted, and a workbench that
    /// proposed one would be assigning a name that belongs to the machine.
    /// `peer_connect` refuses to rename a hub that already has an identity
    /// for exactly that reason.
    pub fn setPeerId(self: *HubState, id: []const u8) !void {
        if (!federation.validPeerId(id)) return error.InvalidPeerId;
        const owned = try self.allocator.dupe(u8, id);
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        if (self.peer_id) |old| self.allocator.free(old);
        self.peer_id = owned;
    }

    /// The peers this hub currently has live relay links to, with the
    /// loopback port it dialed. A workbench that restarts must be able to
    /// LEARN this rather than assume it starts with none: the hub
    /// deliberately outlives the workbench ([[ADR-0008]] supervision), so
    /// on relaunch it is routinely already federated while the workbench
    /// knows nothing about it. Without this the workbench holds no peer
    /// subscription and no port assignment, which silently disables both
    /// the merged view's rich data and any redial.
    pub fn peerLinksJson(self: *HubState, arena: Allocator) !json.Value {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        var arr = json.Array.init(arena);
        var it = self.peer_links.iterator();
        while (it.next()) |e| {
            var obj = json.ObjectMap.empty;
            try obj.put(arena, "peer", .{ .string = try arena.dupe(u8, e.key_ptr.*) });
            try obj.put(arena, "port", .{ .integer = @intCast(e.value_ptr.dialed_port) });
            try obj.put(arena, "version", .{ .integer = @intCast(e.value_ptr.version) });
            // What the peer DOES provide, so a surface can render what it
            // does not — C-DIAGNOSABILITY's requirement rests on this
            // being retained and exposed.
            var caps = json.Array.init(arena);
            inline for (@typeInfo(federation.Capability).@"enum".fields) |f| {
                if (e.value_ptr.caps.has(@field(federation.Capability, f.name))) {
                    try caps.append(.{ .string = f.name });
                }
            }
            try obj.put(arena, "capabilities", .{ .array = caps });
            try arr.append(.{ .object = obj });
        }
        return .{ .array = arr };
    }

    /// A COPY of this hub's peer id, or null. Callers that hold the id
    /// beyond the critical section MUST use this rather than borrowing
    /// `peer_id` directly: setPeerId frees the old slice, so a borrowed
    /// reference held for the life of a relay link dangles the moment the
    /// hub is renamed. Taking the lock in setPeerId alone does NOT fix
    /// that — the borrower is already gone by then.
    pub fn peerIdDupe(self: *HubState, alloc: Allocator) !?[]const u8 {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const id = self.peer_id orelse return null;
        return try alloc.dupe(u8, id);
    }

    /// Shut down every relay link. Used on hub teardown and by operators
    /// dropping federation; the reader loops then exit and each tombstones
    /// its peer's identities on the way out.
    pub fn closeAllPeerLinks(self: *HubState) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        var links = std.ArrayList(*Connection).empty;
        defer links.deinit(self.allocator);
        var it = self.peer_links.valueIterator();
        while (it.next()) |link| links.append(self.allocator, link.conn) catch {};
        self.presence_mutex.unlock(io_mod.get());
        // OUTSIDE the lock: shutdown wakes the reader, which calls
        // peerLinkDown and would deadlock against a held presence_mutex.
        for (links.items) |link| link.interruptStream();
    }

    /// Tell every peer that a local identity appeared or went away.
    /// Caller holds presence_mutex. Best-effort: a peer that misses an
    /// update re-syncs from the full advertisement on its next connect.
    fn broadcastDirectoryLocked(self: *HubState, identity: []const u8, added: bool) void {
        if (self.peer_links.count() == 0) return;
        const me = self.peer_id orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // C-IDENTITY-SCOPE: qualify on the way OUT. A hub MUST NOT
        // advertise an unqualified fallback id — two laptops collide on
        // the 4-hex space routinely.
        const wire_id = federation.qualify(a, identity, me) catch return;
        var payload = json.ObjectMap.empty;
        var arr = json.Array.init(a);
        arr.append(.{ .string = wire_id }) catch return;
        // ONE FRAME, THREE JOBS, AND THE OP IS WHAT TELLS THEM APART
        // ([[RFC-0009]] C-DIRECTORY). This and `advertiseAllTo` used to
        // emit the same `{"added":[...]}` shape and differ only in an
        // envelope id string, so the replace-on-link-up never happened:
        // a restarted peer's stale entries survived its reconnection and
        // went on attracting mail addressed to identities it no longer
        // hosted.
        payload.put(a, "op", .{ .string = if (added) "add" else "remove" }) catch return;
        payload.put(a, "identities", .{ .array = arr }) catch return;
        var it = self.peer_links.valueIterator();
        while (it.next()) |link| {
            link.conn.enqueueEnvelope(a, .{
                .@"type" = "relay_advertise",
                .id = "relay-adv",
                .source = me,
                .target = "",
                .payload = .{ .object = payload },
            }) catch {};
        }
    }

    /// The full set this hub hosts, qualified for the wire — sent once on
    /// peer connect so a fresh link starts consistent instead of learning
    /// only about identities that happen to change afterwards.
    pub fn advertiseAllTo(self: *HubState, conn: *Connection) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const me = self.peer_id orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var arr = json.Array.init(a);
        const ids = self.routing_table.agentIds(a) catch return;
        for (ids) |id| {
            const wire_id = federation.qualify(a, id, me) catch continue;
            arr.append(.{ .string = wire_id }) catch continue;
        }
        var payload = json.ObjectMap.empty;
        // REPLACE, because this is the full set. A receiver that treated
        // it as an add would keep whatever it learned before the link
        // dropped, which is exactly what this frame exists to correct.
        payload.put(a, "op", .{ .string = "replace" }) catch return;
        payload.put(a, "identities", .{ .array = arr }) catch return;
        conn.enqueueEnvelope(a, .{
            .@"type" = "relay_advertise",
            .id = "relay-adv-all",
            .source = me,
            .target = "",
            .payload = .{ .object = payload },
        }) catch {};
    }

    /// Rewrite an outgoing envelope's `source` into its qualified form,
    /// or null when there is nothing to change — a durable id, an already
    /// qualified one, or a payload that does not parse as an envelope.
    /// Arena-owned. Null means "send what you had", which keeps an opaque
    /// payload opaque rather than inventing a shape for it.
    fn qualifiedEnvelope(self: *HubState, a: Allocator, raw: []const u8) ?[]const u8 {
        const me = self.peer_id orelse return null;
        const parsed = protocol.parseEnvelope(a, raw) catch return null;
        const qualified = federation.qualify(a, parsed.value.source, me) catch return null;
        if (mem.eql(u8, qualified, parsed.value.source)) return null;
        var copy = parsed.value;
        copy.source = qualified;
        return protocol.serializeEnvelope(a, copy) catch null;
    }

    /// Write one forwarded message onto a live relay link. Caller holds
    /// presence_mutex. Returns null when there is no link — the caller
    /// then spools, which is the same rule with a queue in front of it.
    /// `reuse_id` is the forward id this message has ALREADY gone out
    /// under, when it has. A retry MUST carry it again: the receiver
    /// deduplicates on the forward id, so a retry minting a fresh one is
    /// a message it has no way to recognise, and a lost acknowledgement
    /// then delivers the same message twice ([[RFC-0009]] C-DELIVERY).
    /// Null mints a new one, which is the first attempt.
    /// `await_answer` says whether anybody will call `awaitForward` for
    /// this write. THE PENDING TABLE EXISTS FOR A WAITER: a submitted dm
    /// has one, a spool flush has none, and registering for a waiter that
    /// never comes leaves an entry nothing drops — which is what the
    /// flush path was doing on every sweep, for the lifetime of the hub.
    fn forwardToPeerLocked(
        self: *HubState,
        peer: []const u8,
        target: []const u8,
        raw_envelope: []const u8,
        reuse_id: ?[]const u8,
        await_answer: bool,
    ) ?[]const u8 {
        const link = (self.peer_links.get(peer) orelse return null).conn;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // QUALIFIED ON THE WAY OUT ([[RFC-0009]] C-IDENTITY-SCOPE). A
        // fallback id is only unique on the machine that minted it, so the
        // far side keys its directory on `local-1a2b@<us>` — and it admits
        // a relayed frame by the name it was advertised under
        // (C-BOUNDARIES). Passing the sender's envelope through verbatim
        // sent the bare id, which that check refuses; it is also a `from`
        // the recipient could not reply to.
        const outgoing = self.qualifiedEnvelope(a, raw_envelope) orelse raw_envelope;
        // The id must outlive this arena: the sender waits on it after the
        // lock is released, and the pending table owns the copy.
        // MINTED HERE, AND ON THE PAYLOAD ([[RFC-0009]] C-DELIVERY). The
        // relay frame's own envelope id belongs to the relay frame; it
        // used to carry the literal "relay-fwd" for every message, which
        // sendRelayAck echoed — so no acknowledgement on a link was
        // attributable to any message.
        const forward_id = if (reuse_id) |r|
            (a.dupe(u8, r) catch return null)
        else blk: {
            self.forward_seq += 1;
            break :blk federation.mintForwardId(a, self.startup_ms, self.forward_seq) catch
                return null;
        };
        var payload = json.ObjectMap.empty;
        payload.put(a, "forward_id", .{ .string = forward_id }) catch return null;
        payload.put(a, "envelope", .{ .string = outgoing }) catch return null;
        link.enqueueEnvelope(a, .{
            .@"type" = "relay_forward",
            .id = "relay-fwd",
            .source = self.peer_id orelse "hub",
            .target = target,
            .payload = .{ .object = payload },
        }) catch return null;
        // HELD, NOT DONE. The copy is released when the peer answers; the
        // caller waits on this id outside presence_mutex.
        if (!await_answer) {
            // Nobody will await, so nothing would ever drop the entry —
            // and the caller passed the id in, so it already has a stable
            // copy to key the release on.
            return reuse_id;
        }
        const owned = self.allocator.dupe(u8, forward_id) catch return null;
        self.registerForward(owned);
        self.allocator.free(owned);
        return self.pendingKey(forward_id);
    }

    /// The pending table's own copy of an id, which outlives this arena.
    fn pendingKey(self: *HubState, forward_id: []const u8) ?[]const u8 {
        self.forward_mutex.lock(io_mod.get()) catch unreachable;
        defer self.forward_mutex.unlock(io_mod.get());
        return (self.pending_forwards.getKey(forward_id));
    }

    /// Nobody answered inside the bound: hold the copy after all.
    /// C-DELIVERY — an unacknowledged forward is spooled, never assumed
    /// delivered — and the hosting peer is re-resolved here rather than
    /// carried out of the lock on a borrowed pointer.
    /// `forward_id` is the id the SILENT forward went out under, and it
    /// rides the held copy so the retry carries it again: a receiver
    /// deduplicates on it, and a retry minting a fresh one is a message
    /// the receiver has no way to recognise as the same one
    /// ([[RFC-0009]] C-DELIVERY).
    pub fn spoolAfterSilence(
        self: *HubState,
        target: []const u8,
        msg_id: []const u8,
        raw: []const u8,
        forward_id: ?[]const u8,
    ) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const entry = self.directory.lookup(target) orelse return;
        // THE ANSWER THIS PUSH RETURNS WAS BEING DISCARDED. There are two
        // places a message enters the spool, and only the older one said
        // anything when the cap pushed an older message out — so on THIS
        // path, the one an ack-silence takes, a broken promise was
        // invisible even in the log.
        const push = self.spool.push(
            entry.peer,
            msg_id,
            target,
            raw,
            std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
            forward_id,
        ) catch return;
        if (push == .dropped_oldest) {
            log.err(
                "spool for {s} full — DROPPED the oldest message, which a sender was already told was held",
                .{entry.peer},
            );
            _ = self.event_log.append(.{
                .kind = .spool_evicted,
                .agent = msg_id,
                .peer = entry.peer,
            }) catch 0;
        }
        self.persistLocked();
    }

    /// Drain the mailbox for the connection's CURRENTLY bound identity
    /// (C-MAILBOX: hub-side queues drain only through the hosting
    /// connection). Returned strings are arena-owned.
    pub fn mailboxDrainFor(self: *HubState, conn: *Connection, arena: Allocator) ![]const []const u8 {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        const bound = (try conn.boundIdDupe(arena)) orelse return &.{};
        const drained = try self.mailbox.drainInto(arena, bound);
        // RFC-0005: the mailbox returned to empty — the agent read its
        // mail on its own (or the wake landed); either way the candidate
        // is resolved.
        self.wakeCancelLocked(bound);
        // Delivered mail must not come back after a restart.
        if (drained.len > 0) self.persistLocked();
        return drained;
    }

    pub fn noteMessageRouted(self: *HubState, from: []const u8, to: []const u8) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        _ = self.event_log.append(.{ .kind = .message_routed, .agent = from, .peer = to }) catch 0;
    }

    // -- RFC-0007 exec routing -------------------------------------------------

    /// Fan an exec_request out to the workbench control endpoint (event
    /// subscribers). Returns false when nothing is listening — the agent
    /// must fail fast, not hang (C-PRIMITIVES bounded-timeout spirit).
    pub fn execForward(self: *HubState, envelope: protocol.Envelope) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        // TO ONE, NOT TO ALL ([[RFC-0003:C-HUB-ROLE]]). This fanned the
        // request out and every attached workbench ran it: two panes and
        // the command twice ([[WI-2026-09-03-014]]).
        return self.event_log.dispatchOne(envelope);
    }

    /// Record an exec receipt on the event log AND route the workbench's
    /// exec_response back to the requesting agent. `kind` is the receipt
    /// EventKind, `owner`/`gen`/`pane`/`detail` its fields; `requester`
    /// is the exec_request's original source; `response` is enqueued to
    /// the requester's live connection. All atomic under presence_mutex
    /// (the write-time invariant). Returns true if the response reached a
    /// live requester.
    pub fn recordExecReceipt(
        self: *HubState,
        kind: ?events.EventKind,
        owner: []const u8,
        gen: ?u64,
        pane: ?[]const u8,
        detail: ?[]const u8,
        requester: []const u8,
        response: protocol.Envelope,
    ) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        // read is route-only (RFC-0007: reads are not receipted). Other
        // verbs append their receipt to the event log.
        if (kind) |k| {
            _ = self.event_log.append(.{
                .kind = k,
                .agent = owner,
                .generation = gen,
                .peer = pane,
                .session = detail,
            }) catch 0;
        }
        const rc = self.routing_table.lookupAndRetain(requester) orelse return false;
        defer rc.release();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        rc.enqueueEnvelope(arena.allocator(), response) catch return false;
        return true;
    }

    // -- Durable state ([[ADR-0008]] stage 2) ---------------------------

    /// Write the state that carries a promise. Caller MUST hold
    /// presence_mutex: the snapshot has to be consistent with the
    /// mutation it records, exactly like the event log's write-time
    /// invariant. Failure is logged, never fatal — a hub that cannot
    /// persist must keep routing, but it must also stop claiming
    /// durability, which is why the failure is loud.
    fn persistLocked(self: *HubState) void {
        const path = self.state_path orelse return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        var boxes = std.ArrayList(state_store.Mailbox).empty;
        var it = self.mailbox.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.items.len == 0) continue;
            boxes.append(a, .{ .id = e.key_ptr.*, .messages = e.value_ptr.items }) catch return;
        }
        var ids = std.ArrayList([]const u8).empty;
        var id_it = self.durable_ids.keyIterator();
        while (id_it.next()) |k| ids.append(a, k.*) catch return;

        // THE SPOOL IS A PROMISE TOO ([[RFC-0009]] C-DELIVERY). A sender
        // answered `spooled` was told the hub holds the message and will
        // forward it; losing that on a restart makes the answer a lie,
        // and the drops the same clause requires to be written where the
        // spool is written would have nowhere to go.
        var queues = std.ArrayList(state_store.SpoolQueue).empty;
        var spool_it = self.spool.map.iterator();
        while (spool_it.next()) |e| {
            if (e.value_ptr.items.len == 0) continue;
            var msgs = std.ArrayList(state_store.SpooledMessage).empty;
            for (e.value_ptr.items) |m| {
                msgs.append(a, .{
                    .msg_id = m.msg_id,
                    .target = m.target,
                    .raw = m.raw,
                    .enqueued_ms = m.enqueued_ms,
                    // THE ID IT ALREADY WENT OUT UNDER. Omitted here, the
                    // field existed on both structs and in the wire
                    // format and was never populated, so a retry after a
                    // RESTART minted a fresh one and the peer queued the
                    // message a second time — the duplication the id
                    // exists to prevent, with a process boundary in the
                    // middle.
                    .forward_id = m.forward_id,
                }) catch return;
            }
            queues.append(a, .{ .peer = e.key_ptr.*, .messages = msgs.items }) catch return;
        }

        const doc = state_store.serialize(a, .{
            .mailboxes = boxes.items,
            .durable_ids = ids.items,
            .spool = queues.items,
        }) catch |err| {
            log.err("could not serialize hub state: {any} — mail is NOT durable", .{err});
            return;
        };
        state_store.writeFile(path, doc) catch |err| {
            log.err("could not write hub state to {s}: {any} — mail is NOT durable", .{ path, err });
        };
    }

    /// THE PATH IS OURS FROM HERE ON ([[WI-2026-09-02-014]]). runHub
    /// resolved the default into a block-scoped stack buffer and handed
    /// the slice down; it was stored and read on every persist for the
    /// life of the process — every production service hub, since
    /// `--state-path default` is what the service passes. The callee
    /// copies what it keeps, so no caller's discipline is load-bearing.
    pub fn setStatePath(self: *HubState, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        if (self.state_path) |old| self.allocator.free(old);
        self.state_path = owned;
    }

    /// Restore mail and durable identities at startup. Everything else
    /// (connections, generations, wake candidates, presence) belongs to a
    /// workbench lifetime and is deliberately NOT restored — see
    /// state_store's header. Returns the number of restored messages.
    pub fn restoreFromDisk(self: *HubState, path: []const u8) usize {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        self.setStatePath(path) catch {
            log.err("could not keep the hub state path {s} — mail is NOT durable", .{path});
            return 0;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const result = state_store.load(arena_state.allocator(), path);
        switch (result.outcome) {
            .absent => return 0,
            .rejected => {
                // Loud: an empty start after a rejected store looks
                // exactly like a first run, and the operator would have
                // no way to tell that mail was dropped.
                log.err("hub state at {s} rejected ({s}) — starting with EMPTY mailboxes", .{
                    path, result.reason orelse "unknown",
                });
                return 0;
            },
            .loaded => {},
        }
        // A DROPPED RESTORE IS A BROKEN PROMISE, so it is counted and
        // said out loud. Every message in this snapshot is one a sender
        // was already told was queued or spooled; C-DELIVERY's whole
        // position is that the system never reports work it did not do,
        // and a `catch continue` here breaks that promise after the fact,
        // across a restart, where nobody is watching. Same for a durable
        // id: lose it and mail to that identity stops being `queued` and
        // starts being `unknown` — a typo, as far as the sender can tell.
        var restored: usize = 0;
        var lost_messages: usize = 0;
        for (result.snapshot.mailboxes) |box| {
            for (box.messages) |m| {
                self.mailbox.append(box.id, m) catch {
                    lost_messages += 1;
                    continue;
                };
                restored += 1;
            }
        }
        var ids_restored: usize = 0;
        var lost_ids: usize = 0;
        for (result.snapshot.durable_ids) |id| {
            if (self.durable_ids.contains(id)) {
                ids_restored += 1;
                continue;
            }
            const key = self.allocator.dupe(u8, id) catch {
                lost_ids += 1;
                continue;
            };
            if (self.durable_ids.put(key, {})) {
                ids_restored += 1;
            } else |_| {
                self.allocator.free(key);
                lost_ids += 1;
            }
        }
        // SPOOLED MAIL COMES BACK WITH ITS AGE. push() stamps `now`, which
        // would hand every restored message a fresh TTL and let a queue
        // outlive the directory entry naming where to send it, so the
        // enqueue time is written back over the stamp.
        var spooled_back: usize = 0;
        var lost_spooled: usize = 0;
        for (result.snapshot.spool) |q| {
            for (q.messages) |m| {
                _ = self.spool.push(q.peer, m.msg_id, m.target, m.raw, m.enqueued_ms,
                                    m.forward_id) catch {
                    lost_spooled += 1;
                    continue;
                };
                spooled_back += 1;
            }
        }

        if (restored > 0 or ids_restored > 0 or spooled_back > 0) {
            // ACHIEVED counts, not the snapshot's. The previous version
            // logged `snapshot.durable_ids.len` for the second number —
            // the count in the FILE, printed regardless of how many
            // actually went in. A restore that lost half its identities
            // reported full success.
            log.info("restored {d} queued message(s) for {d} identity(ies), and {d} spooled for peers", .{
                restored, ids_restored, spooled_back,
            });
        }
        if (lost_messages > 0 or lost_ids > 0 or lost_spooled > 0) {
            log.err(
                "durable state PARTIALLY restored: {d} queued message(s), {d} identity(ies) and {d} spooled message(s) could not be restored — senders were already told these were queued or spooled",
                .{ lost_messages, lost_ids, lost_spooled },
            );
        }
        return restored;
    }

    /// Atomically remove `agent_id` from the routing table AND the derived
    /// registries (agent metadata, channels) when the routing entry still
    /// belongs to `conn`. All registries are touched while holding the
    /// ROUTING lock — a re-register of the same id also takes the routing
    /// lock, so it can never interleave between the ownership check and
    /// the cleanup (closes the TOCTOU where an old connection tore down a
    /// new connection's metadata; WI-2026-08-08-029). On success the
    /// generation ends and the agent_unregistered event is appended, all
    /// under presence_mutex (RFC-0004: registration ends ONLY here).
    pub fn teardownAgent(self: *HubState, agent_id: []const u8, conn: *Connection, conn_alloc: Allocator) bool {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        {
            self.routing_table.mutex.lock(io_mod.get()) catch unreachable;
            defer self.routing_table.mutex.unlock(io_mod.get());
            if (self.routing_table.map.get(agent_id)) |current| {
                if (current != conn) return false;
            }
            _ = self.routing_table.removeOwnedLocked(agent_id);
            self.agent_registry.remove(agent_id);
            _ = self.channel_registry.removeFromAll(agent_id, conn_alloc) catch {};
        }
        const gen: ?u64 = if (self.generations.fetchRemove(agent_id)) |kv| blk: {
            self.allocator.free(kv.key);
            break :blk kv.value;
        } else null;
        _ = self.event_log.append(.{ .kind = .agent_unregistered, .agent = agent_id, .generation = gen }) catch 0;
        // RFC-0005: unregister cancels the outstanding candidate.
        self.wakeCancelLocked(agent_id);
        // C-MAILBOX disposal: pane-class identities never re-home, so
        // their queues are unreachable after teardown. Durable queues
        // survive — that is the point of the identity.
        if (!self.durable_ids.contains(agent_id)) {
            self.mailbox.dispose(agent_id);
            self.persistLocked();
        }
        self.broadcastDirectoryLocked(agent_id, false);
        return true;
    }

    /// Subscriber management (RFC-0004 C-SUBSCRIPTION) — presence_mutex
    /// wrappers around the event log's subscriber list.
    pub fn removeSubscriber(self: *HubState, conn: *Connection) void {
        self.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer self.presence_mutex.unlock(io_mod.get());
        self.event_log.removeSubscriber(conn);
    }

    pub fn init(allocator: Allocator) HubState {
        return .{
            .supervision = null,
            .state_path = null,
            .dial_threads = sys.ThreadReaper.init(allocator),
            .directory = federation.Directory.init(allocator),
            .spool = federation.Spool.init(allocator),
            .forward_seen = federation.ForwardSeen.init(allocator),
            .pending_forwards = std.StringHashMap(ForwardAnswer).init(allocator),
            .forward_mutex = .init,
            .startup_ms = std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds(),
            .peer_links = std.StringHashMap(PeerLink).init(allocator),
            .endpoint_ids = std.AutoHashMap(u16, []const u8).init(allocator),
            .pending_tools = std.StringHashMap(PendingTool).init(allocator),
            .peer_id = null,
            .durable_ids = std.StringHashMap(void).init(allocator),
            .wake_pending = std.StringHashMap(u64).init(allocator),
            .mailbox = MailStore.init(allocator),
            .routing_table = RoutingTable.init(allocator),
            .agent_registry = AgentRegistry.init(allocator),
            .channel_registry = ChannelRegistry.init(allocator),
            .message_log = MessageLog.init(10_000),
            .activity_log = ActivityLog.init(500),
            .event_log = events.EventLog.init(allocator, 2_000),
            .generations = std.StringHashMap(u64).init(allocator),
            .presence_mutex = .init,
            .allocator = allocator,
            .all_connections = std.ArrayList(*Connection).empty,
            .all_connections_mutex = .init,
        };
    }

    pub fn deinit(self: *HubState) void {
        // Event log first: releases any straggler subscriber refs, which
        // may free those connections (removing them from all_connections).
        self.event_log.deinit();
        if (self.state_path) |p| self.allocator.free(p);
        self.dial_threads.deinit();
        var gen_it = self.generations.keyIterator();
        while (gen_it.next()) |key| self.allocator.free(key.*);
        self.generations.deinit();
        var did_it = self.durable_ids.keyIterator();
        while (did_it.next()) |key| self.allocator.free(key.*);
        self.durable_ids.deinit();
        var wake_it = self.wake_pending.keyIterator();
        while (wake_it.next()) |key| self.allocator.free(key.*);
        self.wake_pending.deinit();
        self.mailbox.deinit();
        self.directory.deinit();
        self.spool.deinit();
        self.forward_seen.deinit();
        {
            var pf = self.pending_forwards.iterator();
            while (pf.next()) |e| {
                if (e.value_ptr.* == .nacked) self.allocator.free(e.value_ptr.nacked);
                self.allocator.free(e.key_ptr.*);
            }
            self.pending_forwards.deinit();
        }
        var pl_it = self.peer_links.keyIterator();
        while (pl_it.next()) |key| self.allocator.free(key.*);
        self.peer_links.deinit();
        var ep_it = self.endpoint_ids.valueIterator();
        while (ep_it.next()) |v| self.allocator.free(v.*);
        self.endpoint_ids.deinit();
        var pt_it = self.pending_tools.iterator();
        while (pt_it.next()) |e| {
            e.value_ptr.conn.release();
            self.allocator.free(e.key_ptr.*);
        }
        self.pending_tools.deinit();
        if (self.peer_id) |pid| self.allocator.free(pid);
        // Free any remaining connections (e.g. from threads that didn't clean up).
        for (self.all_connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.all_connections.deinit(self.allocator);
        self.routing_table.deinit();
        self.agent_registry.deinit();
        self.channel_registry.deinit();
        self.message_log.deinit(self.allocator);
        self.activity_log.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------


test "AgentRegistry update and get" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "codex", .project = "/path", .session = "auth refactor" });
    const info = reg.get("agent-a", std.testing.allocator).?;
    defer {
        if (info.tool) |t| std.testing.allocator.free(t);
        if (info.project) |p| std.testing.allocator.free(p);
        if (info.session) |s| std.testing.allocator.free(s);
    }
    try std.testing.expectEqualStrings("codex", info.tool.?);
    try std.testing.expectEqualStrings("/path", info.project.?);
    try std.testing.expectEqualStrings("auth refactor", info.session.?);
}

test "AgentRegistry remove clears entry" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "claude" });
    reg.remove("agent-a");
    try std.testing.expect(reg.get("agent-a", std.testing.allocator) == null);
}

test "AgentRegistry applySignal on existing and unknown agents" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "claude" });
    const r1 = try reg.applySignal("agent-a", .explicit, .waiting);
    try std.testing.expect(r1.accepted and r1.changed);
    try std.testing.expectEqual(protocol.Status.unknown, r1.old);
    const info = reg.get("agent-a", std.testing.allocator).?;
    defer reg_free(info);
    try std.testing.expectEqual(protocol.Status.waiting, info.status);
    try std.testing.expectEqualStrings("claude", info.tool.?);

    // Unknown agent: status-only record.
    _ = try reg.applySignal("agent-b", .explicit, .working);
    const info_b = reg.get("agent-b", std.testing.allocator).?;
    defer reg_free(info_b);
    try std.testing.expectEqual(protocol.Status.working, info_b.status);
    try std.testing.expect(info_b.tool == null);

    // Re-applying the same state is accepted but unchanged (no event fodder).
    const r_same = try reg.applySignal("agent-b", .explicit, .working);
    try std.testing.expect(r_same.accepted and !r_same.changed);
}

test "AgentRegistry applySignal enforces the acceptance rules" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    // Passive done without observed prior work: REJECTED, state untouched
    // (a fresh rest-prompt match must not manufacture attention).
    const r1 = try reg.applySignal("agent-a", .passive, .done);
    try std.testing.expect(!r1.accepted);
    try std.testing.expect(reg.get("agent-a", std.testing.allocator) == null);

    // Explicit idle only lands on done (the stale-view race guard).
    _ = try reg.applySignal("agent-a", .passive, .waiting);
    const r2 = try reg.applySignal("agent-a", .explicit, .idle);
    try std.testing.expect(!r2.accepted);
    _ = try reg.applySignal("agent-a", .explicit, .done);
    const r3 = try reg.applySignal("agent-a", .explicit, .idle);
    try std.testing.expect(r3.accepted and r3.changed);

    // A stale explicit is corrected by a passive edge (dual-source point).
    _ = try reg.applySignal("agent-a", .passive, .working);
    const r4 = try reg.applySignal("agent-a", .passive, .done);
    try std.testing.expect(r4.accepted); // prior working -> done OK

    // Lifecycle resets to unknown from anything.
    const r5 = try reg.applySignal("agent-a", .lifecycle, .unknown);
    try std.testing.expect(r5.accepted and r5.changed);
}

test "AgentRegistry metadata update preserves merged status" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.update("agent-a", .{ .tool = "claude" });
    _ = try reg.applySignal("agent-a", .explicit, .waiting);
    // Re-register without status — the waiting flag must survive.
    try reg.update("agent-a", .{ .tool = "claude", .project = "/p" });
    const info = reg.get("agent-a", std.testing.allocator).?;
    defer reg_free(info);
    try std.testing.expectEqual(protocol.Status.waiting, info.status);
    try std.testing.expectEqualStrings("/p", info.project.?);
}

/// Test helper: free a get() snapshot.
fn reg_free(info: AgentInfo) void {
    if (info.tool) |t| std.testing.allocator.free(t);
    if (info.project) |p| std.testing.allocator.free(p);
    if (info.session) |s| std.testing.allocator.free(s);
}

test "HubState generation lifecycle and write-time invariant (RFC-0004)" {
    // This test re-registers on purpose; the duplicate-registration warn
    // is EXPECTED noise. Passing tests must keep stderr silent: zig's
    // build runner prints a spurious "failed command:" context line for
    // any successful step with stderr output (result_failed_command is
    // set unconditionally at spawn and printErrorMessages runs "no
    // matter the result").
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();

    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // Fresh registration: generation == seq of the creating event.
    const gen1 = try state.registerAgentTracked("agent-a", &conn);
    try std.testing.expectEqual(gen1, state.event_log.entries.items[state.event_log.entries.items.len - 1].seq);
    try std.testing.expectEqual(events.EventKind.agent_registered, state.event_log.entries.items[state.event_log.entries.items.len - 1].kind);

    // Live re-register (same id still routed): generation carried forward.
    const gen2 = try state.registerAgentTracked("agent-a", &conn);
    try std.testing.expectEqual(gen1, gen2);
    const rereg_ev = state.event_log.entries.items[state.event_log.entries.items.len - 1];
    try std.testing.expectEqual(events.EventKind.agent_registered, rereg_ev.kind);
    try std.testing.expectEqual(@as(?u64, gen1), rereg_ev.generation);
    try std.testing.expect(rereg_ev.seq != gen1); // new event, old generation

    // Metadata update: covered by an agent_registered event (invariant).
    try state.updateAgentTracked("agent-a", .{ .tool = "codex" });
    const meta_ev = state.event_log.entries.items[state.event_log.entries.items.len - 1];
    try std.testing.expectEqual(events.EventKind.agent_registered, meta_ev.kind);
    try std.testing.expectEqualStrings("codex", meta_ev.tool.?);

    // Accepted status change: exactly one status_changed event appended.
    const before = state.event_log.latestSeq();
    const res = try state.applyStatusSignal("agent-a", .explicit, .working);
    try std.testing.expect(res.accepted and res.changed);
    try std.testing.expectEqual(before + 1, state.event_log.latestSeq());
    const st_ev = state.event_log.entries.items[state.event_log.entries.items.len - 1];
    try std.testing.expectEqual(events.EventKind.agent_status_changed, st_ev.kind);
    try std.testing.expectEqual(@as(?protocol.Status, .unknown), st_ev.old_state);
    try std.testing.expectEqual(@as(?protocol.Status, .working), st_ev.new_state);

    // Rejected signal: NO event (nothing visible changed).
    const before_rej = state.event_log.latestSeq();
    const rej = try state.applyStatusSignal("agent-a", .passive, .idle);
    try std.testing.expect(!rej.accepted);
    try std.testing.expectEqual(before_rej, state.event_log.latestSeq());

    // Teardown: generation ends, agent_unregistered appended.
    try std.testing.expect(state.teardownAgent("agent-a", &conn, std.testing.allocator));
    const unreg_ev = state.event_log.entries.items[state.event_log.entries.items.len - 1];
    try std.testing.expectEqual(events.EventKind.agent_unregistered, unreg_ev.kind);
    try std.testing.expectEqual(@as(?u64, gen1), unreg_ev.generation);

    // Register again after teardown: a NEW generation.
    const gen3 = try state.registerAgentTracked("agent-a", &conn);
    try std.testing.expect(gen3 != gen1);
    try std.testing.expect(state.teardownAgent("agent-a", &conn, std.testing.allocator));
}

test "ChannelRegistry create and membership" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("design", "Design discussion", "agent-a");
    try std.testing.expect(cr.isMember("design", "agent-a"));
    try std.testing.expect(!cr.isMember("design", "agent-b"));

    try cr.addMember("design", "agent-b");
    try std.testing.expect(cr.isMember("design", "agent-b"));

    const members = try cr.getMembers("design", std.testing.allocator);
    defer {
        for (members) |m| std.testing.allocator.free(m);
        std.testing.allocator.free(members);
    }
    try std.testing.expectEqual(@as(usize, 2), members.len);
}

test "ChannelRegistry duplicate create returns error" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("design", "", "agent-a");
    try std.testing.expectError(error.ChannelExists, cr.create("design", "", "agent-b"));
}

test "ChannelRegistry removeMember garbage-collects empty channel" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("temp", "", "agent-a");
    try cr.removeMember("temp", "agent-a");
    // Channel should be garbage-collected.
    try std.testing.expect(!cr.isMember("temp", "agent-a"));
    try std.testing.expectError(error.ChannelNotFound, cr.getMembers("temp", std.testing.allocator));
}

test "ChannelRegistry removeFromAll removes agent from all channels" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("ch-1", "", "agent-a");
    try cr.create("ch-2", "", "agent-a");
    try cr.addMember("ch-1", "agent-b");

    const affected = try cr.removeFromAll("agent-a", std.testing.allocator);
    defer {
        for (affected) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(affected);
    }
    try std.testing.expectEqual(@as(usize, 2), affected.len);

    // agent-a should be gone from ch-1, ch-2 should be garbage-collected.
    try std.testing.expect(!cr.isMember("ch-1", "agent-a"));
    try std.testing.expect(cr.isMember("ch-1", "agent-b"));
}

test "ChannelRegistry channelsFor lists memberships" {
    var cr = ChannelRegistry.init(std.testing.allocator);
    defer cr.deinit();

    try cr.create("ch-1", "", "agent-a");
    try cr.create("ch-2", "", "agent-b");
    try cr.addMember("ch-2", "agent-a");

    const channels = try cr.channelsFor("agent-a", std.testing.allocator);
    defer {
        for (channels) |ch| std.testing.allocator.free(ch);
        std.testing.allocator.free(channels);
    }
    try std.testing.expectEqual(@as(usize, 2), channels.len);
}

test "MessageLog append and FIFO eviction" {
    var ml = MessageLog.init(3);
    defer ml.deinit(std.testing.allocator);

    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg1", .ts = 1 });
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg2", .ts = 2 });
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg3", .ts = 3 });
    try std.testing.expectEqual(@as(usize, 3), ml.entries.items.len);

    // 4th entry should evict the first.
    try ml.append(std.testing.allocator, .{ .from = "a", .to = "b", .channel = null, .text = "msg4", .ts = 4 });
    try std.testing.expectEqual(@as(usize, 3), ml.entries.items.len);
    try std.testing.expectEqualStrings("msg2", ml.entries.items[0].text);
    try std.testing.expectEqualStrings("msg4", ml.entries.items[2].text);
}

test "ActivityLog toJson survives eviction after snapshot (WI-2026-08-08-003)" {
    // Regression: toJson must dupe into the caller's arena while holding
    // the mutex; a later append past max_entries evicts (frees) the log's
    // own strings, so the returned value must not borrow them.
    var al = ActivityLog.init(2);
    defer al.deinit(std.testing.allocator);

    try al.append(std.testing.allocator, .{ .ts = 1, .agent = "agent-a", .tool = "task.list", .detail = "list #1" });
    try al.append(std.testing.allocator, .{ .ts = 2, .agent = "agent-b", .tool = "task.claim", .detail = "claim #2" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snapshot = try al.toJson(arena, 50);

    // Evict both entries that the snapshot borrowed from.
    try al.append(std.testing.allocator, .{ .ts = 3, .agent = "agent-c", .tool = "task.update", .detail = "update #3" });
    try al.append(std.testing.allocator, .{ .ts = 4, .agent = "agent-d", .tool = "task.comment", .detail = "comment #4" });

    // Serialize the snapshot AFTER the eviction — must still be valid and
    // complete (would be a use-after-free with the borrowed-slice version).
    const text = try json.Stringify.valueAlloc(arena, snapshot, .{});

    try std.testing.expect(mem.indexOf(u8, text, "claim #2") != null);
    try std.testing.expect(mem.indexOf(u8, text, "list #1") != null);
    try std.testing.expect(mem.indexOf(u8, text, "agent-a") != null);
    try std.testing.expect(mem.indexOf(u8, text, "agent-b") != null);
    // The snapshot predates entries 3-4: they must not appear.
    try std.testing.expect(mem.indexOf(u8, text, "comment #4") == null);
    try std.testing.expect(mem.indexOf(u8, text, "update #3") == null);
}

test "RoutingTable duplicate registration replaces old connection (WI-2026-08-08-016)" {
    // Expected duplicate-registration warn — keep stderr silent so the
    // build runner does not print its spurious "failed command:" line
    // (see the HubState generation test above).
    std.testing.log_level = .err;
    var table = RoutingTable.init(std.testing.allocator);
    defer table.deinit();

    // Two distinct connection objects on real fds so closeStream is exercised.
    const fd1 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    const fd2 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn1 = Connection.init(std.testing.allocator, fd1, @ptrCast(&dummy), noopRelease);
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), noopRelease);
    defer conn1.deinit();
    defer conn2.deinit();

    try table.register("agent-a", &conn1);
    try std.testing.expect(table.lookup("agent-a") == &conn1);

    // Duplicate: new connection replaces the old one; the old fd is
    // INTERRUPTED (EOF to unblock the reader) but NOT closed — closing it
    // under a concurrent writer could reuse the number for a new
    // connection's socket (WI-2026-08-08-029).
    try table.register("agent-a", &conn2);
    try std.testing.expect(table.lookup("agent-a") == &conn2);
    try std.testing.expect(!conn1.fd_closed);

    // THE OWNERSHIP RULE IS ASSERTED WHERE THE SESSION LOOP MEETS IT:
    // `teardownAgent` carries the guard plus everything a teardown owes —
    // the event, the generation, the metadata, and the directory `remove`
    // the peers are owed. A rule asserted on a primitive nothing calls is
    // a rule nothing enforces, so the primitive is gone.
    try std.testing.expect(table.lookup("agent-a") == &conn2);
}

fn noopRelease(_: *anyopaque, _: *Connection) void {}

test "resume_ref is duped, preserved, and freed like other metadata (WI-2026-08-11-012)" {
    var reg = AgentRegistry.init(std.testing.allocator);
    defer reg.deinit();
    var ref_buf: [32]u8 = undefined;
    @memcpy(ref_buf[0..12], "abc123456789");
    try reg.update("a1", .{ .tool = "claude", .resume_ref = ref_buf[0..12] });
    // Mutate the caller's buffer — the registry must hold its own copy.
    @memset(ref_buf[0..12], 'x');
    // Through the PUBLIC snapshot, not the internal map. The original
    // version of this test read reg.map directly, so it proved the value
    // was STORED while the snapshot that every consumer actually reads
    // dropped it — list_agents and the subscription snapshot were empty
    // of resume_ref for as long as that held.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const info = reg.get("a1", arena.allocator()).?;
    try std.testing.expectEqualStrings("abc123456789", info.resume_ref.?);
    try std.testing.expectEqualStrings("claude", info.tool.?);
    // Re-register without resume_ref: metadata replaced wholesale (the
    // register path always sends the full metadata set).
    try reg.update("a1", .{ .tool = "claude" });
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        reg.get("a1", arena.allocator()).?.resume_ref,
    );
}

test "RFC-0008 identity upgrade: pane id ends, durable binds, events trace (WI-2026-08-11-012)" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // Wire registration as the pane wrapper.
    const pane_gen = try state.registerAgentTracked("local-1111", &conn);
    try conn.setIdentity("local-1111");
    try state.updateAgentTracked("local-1111", .{ .tool = "human" });
    _ = pane_gen;

    // Identity upgrade (same connection).
    const outcome = try state.bindDurableIdTracked(&conn, "claude-abc12345", "abc12345-6789");
    try std.testing.expectEqual(HubState.BindOutcome.bound, outcome);
    // Bound id moved; fallback preserved.
    const bound = (try conn.boundIdDupe(std.testing.allocator)).?;
    defer std.testing.allocator.free(bound);
    try std.testing.expectEqualStrings("claude-abc12345", bound);
    const fb = (try conn.fallbackIdDupe(std.testing.allocator)).?;
    defer std.testing.allocator.free(fb);
    try std.testing.expectEqualStrings("local-1111", fb);
    // Pane id gone from registry + generations; durable present.
    try std.testing.expect(state.agent_registry.map.get("local-1111") == null);
    try std.testing.expect(state.generations.get("local-1111") == null);
    try std.testing.expect(state.generations.get("claude-abc12345") != null);
    // Routing points durable -> conn.
    try std.testing.expect(state.routing_table.map.get("claude-abc12345").? == &conn);
    try std.testing.expect(state.routing_table.map.get("local-1111") == null);
    // Event trail ends with identity_upgraded carrying the link.
    const last = state.event_log.entries.items[state.event_log.entries.items.len - 1];
    try std.testing.expectEqual(events.EventKind.identity_upgraded, last.kind);
    try std.testing.expectEqualStrings("claude-abc12345", last.agent);
    try std.testing.expectEqualStrings("local-1111", last.peer.?);

    // Refresh: binding the same id on the same connection is a no-op.
    try std.testing.expectEqual(
        HubState.BindOutcome.refreshed,
        try state.bindDurableIdTracked(&conn, "claude-abc12345", "abc12345-6789"),
    );
}

test "RFC-0008 re-home: displacement reverts old conn to fallback with notice; collision refused" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd1 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    const fd2 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn1 = Connection.init(std.testing.allocator, fd1, @ptrCast(&dummy), noopRelease);
    defer conn1.deinit();
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), noopRelease);
    defer conn2.deinit();

    _ = try state.registerAgentTracked("local-aaaa", &conn1);
    try conn1.setIdentity("local-aaaa");
    _ = try state.registerAgentTracked("local-bbbb", &conn2);
    try conn2.setIdentity("local-bbbb");

    // conn1 claims the durable identity, storing its resume_ref.
    _ = try state.bindDurableIdTracked(&conn1, "claude-abc12345", "abc12345-6789");
    try state.updateAgentTracked("claude-abc12345", .{ .tool = "claude", .resume_ref = "abc12345-6789" });
    const gen_before = state.generations.get("claude-abc12345").?;

    // COLLISION: conn2 claims the same derived id with a DIFFERENT ref.
    try std.testing.expectEqual(
        HubState.BindOutcome.collision,
        try state.bindDurableIdTracked(&conn2, "claude-abc12345", "abc12345-XXXX"),
    );
    try std.testing.expect(state.routing_table.map.get("claude-abc12345").? == &conn1);

    // RE-HOME: conn2 claims with the SAME ref (resume in a new pane).
    const outcome = try state.bindDurableIdTracked(&conn2, "claude-abc12345", "abc12345-6789");
    try std.testing.expectEqual(HubState.BindOutcome.rehomed, outcome);
    // Durable now on conn2 with a FRESH generation.
    try std.testing.expect(state.routing_table.map.get("claude-abc12345").? == &conn2);
    try std.testing.expect(state.generations.get("claude-abc12345").? != gen_before);
    // conn1 reverted to its fallback, re-registered fresh, and notified.
    const b1 = (try conn1.boundIdDupe(std.testing.allocator)).?;
    defer std.testing.allocator.free(b1);
    try std.testing.expectEqualStrings("local-aaaa", b1);
    try std.testing.expect(state.routing_table.map.get("local-aaaa").? == &conn1);
    try std.testing.expect(state.generations.get("local-aaaa") != null);
    var saw_notice = false;
    for (conn1.outbound.items) |line| {
        if (std.mem.indexOf(u8, line, "identity_displaced") != null) saw_notice = true;
    }
    try std.testing.expect(saw_notice);
}

test "RFC-0008 mailbox: offline queueing, upgrade merge, re-home drain, pane disposal (WI-2026-08-11-012)" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd1 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    const fd2 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn1 = Connection.init(std.testing.allocator, fd1, @ptrCast(&dummy), noopRelease);
    defer conn1.deinit();
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), noopRelease);
    defer conn2.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Mail to a pane id queues; upgrade merges it into the durable queue.
    _ = try state.registerAgentTracked("local-m1", &conn1);
    try conn1.setIdentity("local-m1");
    try std.testing.expectEqual(DeliveryOutcome.delivered, (try state.mailboxDeliver("local-m1", "m", "{\"msg\":\"pane-mail\"}", .submitted)).outcome);
    _ = try state.bindDurableIdTracked(&conn1, "claude-mailtest", "mailtest1-ref-xyz");
    try std.testing.expectEqual(@as(usize, 0), state.mailbox.count("local-m1"));
    try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("claude-mailtest"));

    // Drain through the hosting connection.
    const drained = try state.mailboxDrainFor(&conn1, a);
    try std.testing.expectEqual(@as(usize, 1), drained.len);
    try std.testing.expect(std.mem.indexOf(u8, drained[0], "pane-mail") != null);

    // Unknown target fails fast.
    // No peers configured, so "unknown" is a claim this hub can make.
    try std.testing.expectEqual(DeliveryOutcome.unknown, (try state.mailboxDeliver("ghost-nobody", "m", "{}", .submitted)).outcome);

    // Offline queueing: teardown the durable identity's connection —
    // the durable queue SURVIVES (that is the point of the identity).
    try std.testing.expect((try state.mailboxDeliver("claude-mailtest", "m", "{\"msg\":\"while-away\"}", .submitted)).hosted);
    _ = state.teardownAgent("claude-mailtest", &conn1, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), state.mailbox.count("claude-mailtest"));
    // Known-offline identity still accepts mail (ack=queued, hosted=false).
    try std.testing.expect(!(try state.mailboxDeliver("claude-mailtest", "m", "{\"msg\":\"more-mail\"}", .submitted)).hosted);

    // Re-home into a NEW pane: mail drains from the new home, and the
    // arrival nudge is queued on the new connection's outbound.
    _ = try state.registerAgentTracked("local-m2", &conn2);
    try conn2.setIdentity("local-m2");
    _ = try state.bindDurableIdTracked(&conn2, "claude-mailtest", "mailtest1-ref-xyz");
    var saw_nudge = false;
    for (conn2.outbound.items) |line| {
        if (std.mem.indexOf(u8, line, "mail_nudge") != null) saw_nudge = true;
    }
    try std.testing.expect(saw_nudge);
    const drained2 = try state.mailboxDrainFor(&conn2, a);
    try std.testing.expectEqual(@as(usize, 2), drained2.len);

    // Pane-class disposal: a bare pane's queue dies with its teardown.
    const fd3 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var conn3 = Connection.init(std.testing.allocator, fd3, @ptrCast(&dummy), noopRelease);
    defer conn3.deinit();
    _ = try state.registerAgentTracked("local-m3", &conn3);
    try conn3.setIdentity("local-m3");
    try std.testing.expect((try state.mailboxDeliver("local-m3", "doomed", "{\"msg\":\"doomed\"}", .submitted)).outcome == .delivered);
    _ = state.teardownAgent("local-m3", &conn3, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), state.mailbox.count("local-m3"));
}

/// Last event on the log must match kind/agent/generation.
fn expectLastEvent(state: *HubState, kind: events.EventKind, agent: []const u8, gen: ?u64) !void {
    const items = state.event_log.entries.items;
    try std.testing.expect(items.len > 0);
    const last = items[items.len - 1];
    try std.testing.expectEqual(kind, last.kind);
    try std.testing.expectEqualStrings(agent, last.agent);
    if (gen) |g| try std.testing.expectEqual(g, last.generation.?);
}

test "RFC-0005 wake: one candidate per empty->non-empty edge; cancel on drain and teardown (WI-2026-08-11-013)" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gen = try state.registerAgentTracked("local-w1", &conn);
    try conn.setIdentity("local-w1");

    // Edge: empty -> non-empty mints exactly one candidate, carrying the
    // recipient's registration generation.
    try std.testing.expect((try state.mailboxDeliver("local-w1", "m1", "{\"msg\":\"m1\"}", .submitted)).outcome == .delivered);
    try expectLastEvent(&state, .wake_candidate, "local-w1", gen);

    // Level: more mail into a non-empty box emits NOTHING.
    const evc = state.event_log.entries.items.len;
    try std.testing.expect((try state.mailboxDeliver("local-w1", "m2", "{\"msg\":\"m2\"}", .submitted)).outcome == .delivered);
    try std.testing.expectEqual(evc, state.event_log.entries.items.len);

    // Self-read to empty cancels the candidate (wake_cancelled carries
    // the candidate's birth generation).
    _ = try state.mailboxDrainFor(&conn, a);
    try expectLastEvent(&state, .wake_cancelled, "local-w1", gen);
    try std.testing.expectEqual(@as(usize, 0), state.wake_pending.count());

    // The next arrival is a fresh edge — a new candidate.
    try std.testing.expect((try state.mailboxDeliver("local-w1", "m3", "{\"msg\":\"m3\"}", .submitted)).outcome == .delivered);
    try expectLastEvent(&state, .wake_candidate, "local-w1", gen);

    // Unregister cancels the outstanding candidate.
    _ = state.teardownAgent("local-w1", &conn, std.testing.allocator);
    try expectLastEvent(&state, .wake_cancelled, "local-w1", gen);
    try std.testing.expectEqual(@as(usize, 0), state.wake_pending.count());
}

test "RFC-0005 wake: fresh edge on bind-with-mail; generation change cancels; receipts (WI-2026-08-11-013)" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd1 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    const fd2 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn1 = Connection.init(std.testing.allocator, fd1, @ptrCast(&dummy), noopRelease);
    defer conn1.deinit();
    var conn2 = Connection.init(std.testing.allocator, fd2, @ptrCast(&dummy), noopRelease);
    defer conn2.deinit();

    // conn1 claims a durable identity; a live deliver mints a candidate,
    // draining resolves it, then the identity goes offline (empty box).
    _ = try state.registerAgentTracked("local-wk1", &conn1);
    try conn1.setIdentity("local-wk1");
    _ = try state.bindDurableIdTracked(&conn1, "claude-wakefrsh", "wakefrsh-ref-001");
    try std.testing.expect((try state.mailboxDeliver("claude-wakefrsh", "live", "{\"msg\":\"live\"}", .submitted)).outcome == .delivered);
    try std.testing.expect(state.wake_pending.contains("claude-wakefrsh"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try state.mailboxDrainFor(&conn1, arena.allocator());
    try expectLastEvent(&state, .wake_cancelled, "claude-wakefrsh", null);
    _ = state.teardownAgent("claude-wakefrsh", &conn1, std.testing.allocator);

    // Mail to the KNOWN-offline durable is a real empty->non-empty edge
    // but mints NO candidate — nobody is registered to wake; the
    // fresh-edge rule below covers the identity's return.
    const evc = state.event_log.entries.items.len;
    try std.testing.expect(!(try state.mailboxDeliver("claude-wakefrsh", "m", "{\"msg\":\"offline\"}", .submitted)).hosted);
    try std.testing.expectEqual(evc, state.event_log.entries.items.len);
    try std.testing.expect(!state.wake_pending.contains("claude-wakefrsh"));

    // Re-home with waiting mail: the bind IS a fresh empty->non-empty
    // edge — one candidate under the NEW generation.
    _ = try state.registerAgentTracked("local-wk2", &conn2);
    try conn2.setIdentity("local-wk2");
    _ = try state.bindDurableIdTracked(&conn2, "claude-wakefrsh", "wakefrsh-ref-001");
    const new_gen = state.generations.get("claude-wakefrsh").?;
    try expectLastEvent(&state, .wake_candidate, "claude-wakefrsh", new_gen);

    // Stalled receipt: recorded, candidate stays outstanding.
    state.recordWakeReport("claude-wakefrsh", new_gen, .stalled);
    try expectLastEvent(&state, .wake_stalled, "claude-wakefrsh", new_gen);
    try std.testing.expect(state.wake_pending.contains("claude-wakefrsh"));

    // Delivered receipt: recorded, candidate resolved.
    state.recordWakeReport("claude-wakefrsh", new_gen, .delivered);
    try expectLastEvent(&state, .wake_delivered, "claude-wakefrsh", new_gen);
    try std.testing.expect(!state.wake_pending.contains("claude-wakefrsh"));

    // A later re-home while mail still waits mints a fresh candidate
    // even though the previous one was delivered (generation change).
    const fd3 = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var conn3 = Connection.init(std.testing.allocator, fd3, @ptrCast(&dummy), noopRelease);
    defer conn3.deinit();
    _ = try state.registerAgentTracked("local-wk3", &conn3);
    try conn3.setIdentity("local-wk3");
    _ = try state.bindDurableIdTracked(&conn3, "claude-wakefrsh", "wakefrsh-ref-001");
    const gen3 = state.generations.get("claude-wakefrsh").?;
    try expectLastEvent(&state, .wake_candidate, "claude-wakefrsh", gen3);
}

test "RFC-0009 C-DELIVERY: five outcomes, and the two failures stay distinct" {
    // The pre-federation code answered with ONE boolean; folding peer
    // knowledge into it collapses five outcomes onto two and turns a
    // partition into a permanent-looking typo error.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop");
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // 1. Local identity -> delivered.
    _ = try state.registerAgentTracked("local-here", &conn);
    try conn.setIdentity("local-here");
    const local = try state.mailboxDeliver("local-here", "m1", "{}", .submitted);
    try std.testing.expectEqual(DeliveryOutcome.delivered, local.outcome);
    try std.testing.expect(local.hosted);

    // 2. No peers at all -> `unknown` is a claim this hub CAN make.
    try std.testing.expectEqual(
        DeliveryOutcome.unknown,
        (try state.mailboxDeliver("claude-nosuchid", "m2", "{}", .submitted)).outcome,
    );

    // A peer advertises an identity, then its link drops.
    try std.testing.expectEqual(
        federation.Directory.Advertise.added,
        try state.directoryAdvertise("remotehost", "claude-remote01"),
    );
    state.peerLinkDown("remotehost");

    // 3. Known-but-unreachable -> spooled. Only possible because the
    // entry was TOMBSTONED: a discarded entry would not name the peer to
    // spool toward, and this would have to be reported as a typo.
    try std.testing.expectEqual(
        DeliveryOutcome.spooled,
        (try state.mailboxDeliver("claude-remote01", "m3", "{}", .submitted)).outcome,
    );
    try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost"));

    // 4. No directory match while a peer is unreachable -> `unknown`,
    // and honestly so: a dropped link keeps its entries
    // (C-DIRECTORY), so a name on the machine it cannot see would have
    // been answered `spooled`. What reaches here is a name no peer has
    // ever claimed, which is a typo.
    try std.testing.expectEqual(
        DeliveryOutcome.unknown,
        (try state.mailboxDeliver("claude-mystery1", "m4", "{}", .submitted)).outcome,
    );

    // A typo is a failure and a held message is not.
    try std.testing.expect(!DeliveryOutcome.unknown.isSuccess());
    try std.testing.expect(DeliveryOutcome.spooled.isSuccess());

    // 5. LOCAL A2A KEEPS WORKING THROUGHOUT the peer outage. This is the
    // property the whole architecture exists for, so it is asserted in
    // the same breath as the failures rather than in a happier test.
    try std.testing.expectEqual(
        DeliveryOutcome.delivered,
        (try state.mailboxDeliver("local-here", "m5", "{}", .submitted)).outcome,
    );
}

test "RFC-0009 C-EVENT-LOCALITY: federation facts appear in THIS hub's log" {
    // Without these local events a `synapty wait` on a remote identity
    // blocks forever with nothing to wake it, and the workbench is blind
    // to every agent it does not host — addressable yet invisible.
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const before = state.event_log.next_seq;
    _ = try state.directoryAdvertise("remotehost", "claude-remote01");
    state.peerLinkDown("remotehost");
    try std.testing.expect(state.event_log.next_seq > before + 1);

    var saw_added = false;
    var saw_link_down = false;
    for (state.event_log.entries.items) |e| {
        if (e.kind == .directory_identity_added and mem.eql(u8, e.agent, "claude-remote01")) saw_added = true;
        if (e.kind == .peer_link_down) saw_link_down = true;
        // The kinds must be DISTINCT from the local lifecycle ones, or a
        // consumer would read a directory fact as a local registration.
        try std.testing.expect(e.kind != .agent_registered);
    }
    try std.testing.expect(saw_added);
    try std.testing.expect(saw_link_down);
}

test "RFC-0009 C-DIRECTORY: a second peer claiming an identity is refused" {
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.directoryAdvertise("remotehost", "claude-remote01");
    try std.testing.expectEqual(
        federation.Directory.Advertise.conflict,
        try state.directoryAdvertise("build-box", "claude-remote01"),
    );
    // The original host survives — silent resolution would misroute every
    // message between the two machines.
    try std.testing.expectEqualStrings("remotehost", state.directory.lookup("claude-remote01").?.peer);
}

test "RFC-0009 C-PRESENCE: a relayed status is stored, served, and withdrawn when the peer goes dark" {
    // WI-2026-08-12-009. The receiving half existed before this; what was
    // missing was anything to receive. Now that a hosting hub emits on the
    // edge, the receiver has to STORE the conclusion (so list_agents can
    // report it) without ever re-running the acceptance rules over it.
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.directoryAdvertise("remotehost", "claude-remote01");

    state.relayPresence("remotehost", "claude-remote01", .waiting);
    try std.testing.expectEqual(protocol.Status.waiting, state.directory.lookup("claude-remote01").?.status);

    // The peer goes dark. The stored value SURVIVES on the entry (the
    // tombstone keeps everything), but a reader must not serve it: a
    // stale status is indistinguishable from a fresh one.
    state.peerLinkDown("remotehost");
    const entry = state.directory.lookup("claude-remote01").?;
    try std.testing.expect(!entry.reachable);
    try std.testing.expectEqual(protocol.Status.waiting, entry.status);
}

test "RFC-0009 C-PRESENCE: relayed status bypasses the local merge path" {
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    _ = try state.directoryAdvertise("remotehost", "claude-remote01");

    // applyStatusSignal REFUSES ids this hub does not host (the phantom
    // guard) — which is every relayed conclusion. Reusing it would have
    // silently discarded the entire feature.
    const refused = try state.applyStatusSignal("claude-remote01", .explicit, .working);
    try std.testing.expect(!refused.accepted);

    // The write-through path stores the peer's conclusion instead.
    state.relayPresence("remotehost", "claude-remote01", .working);
    var saw = false;
    for (state.event_log.entries.items) |e| {
        if (e.kind == .peer_presence_relayed and mem.eql(u8, e.agent, "claude-remote01")) {
            saw = true;
            try std.testing.expectEqual(protocol.Status.working, e.new_state.?);
        }
    }
    try std.testing.expect(saw);

    // A peer speaks for the identities IT hosts and no others. THE
    // STATUS IS WHAT MUST NOT MOVE — this asserted that no event was
    // appended, which pinned the silence rather than the refusal, and the
    // silence was the defect: nothing travels back to the peer either, so
    // the only machine that saw the attempt said nothing about it
    // anywhere ([[RFC-0009]] C-EVENT-LOCALITY).
    state.relayPresence("build-box", "claude-remote01", .idle);
    try std.testing.expectEqual(
        protocol.Status.working,
        state.directory.map.get("claude-remote01").?.status,
    );
    var refusal: ?events.Event = null;
    for (state.event_log.entries.items) |e| {
        if (e.kind == .peer_presence_refused) refusal = e;
    }
    try std.testing.expect(refusal != null);
    try std.testing.expectEqualStrings("build-box", refusal.?.peer.?);
    try std.testing.expectEqualStrings("not_its_identity", refusal.?.reason.?);
    // NOT the kind that says this hub TOOK a conclusion: a consumer
    // counting those would count the ones it threw away.
    try std.testing.expect(refusal.?.kind != .peer_presence_relayed);
}

test "federationSweep expiry restores `unknown` as a reachable answer" {
    // The defect this pins did not leak — it VIOLATED THE SPEC silently.
    // federationSweep was written and never called, so directory
    // tombstones never expired; after one peer link drop
    // the "is any peer unreachable" test stayed true forever and delivery could
    // never again answer `unknown`. C-DELIVERY's answers collapsed to
    // four, and the one that disappeared is the one telling a sender their
    // target is a typo. The unit tests passed throughout because they
    // called directory.expire() DIRECTLY — the production caller was the
    // missing piece, which is exactly the shape that keeps recurring.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop");
    state.directory.retention_ms = 1_000;

    _ = try state.directoryAdvertise("remotehost", "claude-remote01");
    state.peerLinkDown("remotehost");

    // While the tombstone lives, a name NO peer ever claimed is a typo and
    // is said to be one — the entries of the dropped link are still here,
    // so a name on that machine would have been answered `spooled`.
    try std.testing.expectEqual(
        DeliveryOutcome.unknown,
        (try state.mailboxDeliver("claude-nosuchid", "m1", "{}", .submitted)).outcome,
    );

    // After the sweep expires it, the hub can tell a typo from a
    // partition again.
    state.federationSweep(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + 10_000);
    try std.testing.expect(state.directory.lookup("claude-remote01") == null);
    try std.testing.expectEqual(
        DeliveryOutcome.unknown,
        (try state.mailboxDeliver("claude-nosuchid", "m2", "{}", .submitted)).outcome,
    );
}

test "federationSweep releases tool parks the workbench never answered" {
    // A workbench crash left the requester's connection retained forever:
    // bounded at max_pending_tools, but bounded is not released, and each
    // entry pins a file descriptor for the hub's whole life.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // A subscriber must exist or toolForward refuses outright — that
    // refusal is the "no workbench available" fast path.
    try state.event_log.addSubscriber(&conn);
    try std.testing.expect(state.toolForward("agent", "req-1", &conn, .{
        .@"type" = "tool_request",
        .id = "req-1",
        .source = "hub",
        .target = "workbench",
        .payload = .null,
    }));
    try std.testing.expectEqual(@as(usize, 1), state.pending_tools.count());

    // Inside the TTL: still parked, because a slow-but-honest GitHub call
    // must not be reaped out from under the agent waiting on it.
    state.federationSweep(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());
    try std.testing.expectEqual(@as(usize, 1), state.pending_tools.count());

    // Past it: released.
    state.federationSweep(
        std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds() + HubState.pending_tool_ttl_ms + 1,
    );
    try std.testing.expectEqual(@as(usize, 0), state.pending_tools.count());
    state.event_log.removeSubscriber(&conn);
}

test "RFC-0010: a rebuilt machine's old identity is dropped, not left to collide" {
    // THE ENDPOINT IS THE CONTINUITY. A machine that loses its identity
    // file mints a new peer id, and its durable agents keep the SAME ids
    // (RFC-0008 derives them from the harness session, not the machine).
    // Leaving the old tombstoned entries in place would put two peers
    // advertising one identity, which C-DIRECTORY refuses to route — so
    // every agent on that machine would be unreachable for the whole
    // tombstone retention, with no configuration error behind it.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop");
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // The machine at endpoint 9200 is "remotehost-aaaa" and hosts an agent.
    try state.peerLinkUp("remotehost-aaaa", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    _ = try state.directoryAdvertise("remotehost-aaaa", "claude-abc12345");
    state.peerLinkDown("remotehost-aaaa");
    // Mail is spooled toward it while it is away.
    try std.testing.expectEqual(
        DeliveryOutcome.spooled,
        (try state.mailboxDeliver("claude-abc12345", "m1", "{}", .submitted)).outcome,
    );
    try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-aaaa"));

    // It comes back REBUILT: same endpoint, new identity.
    try state.peerLinkUp("remotehost-bbbb", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());

    // The old entry is gone rather than tombstoned, so the same durable
    // agent can be advertised by the new identity without conflict.
    try std.testing.expect(state.directory.lookup("claude-abc12345") == null);
    try std.testing.expectEqual(
        federation.Directory.Advertise.added,
        try state.directoryAdvertise("remotehost-bbbb", "claude-abc12345"),
    );
    // And mail spooled for a machine that no longer exists is dropped
    // rather than riding out the TTL pointing at nobody.
    try std.testing.expectEqual(@as(usize, 0), state.spool.count("remotehost-aaaa"));

    state.peerLinkDown("remotehost-bbbb");
}

test "RFC-0010: the SAME identity returning to an endpoint keeps its entries" {
    // The counterpart that makes the rule safe: an ordinary reconnect must
    // NOT drop anything, or every link flap would discard the directory
    // and the spool it exists to protect.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop");
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    try state.peerLinkUp("remotehost-aaaa", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    _ = try state.directoryAdvertise("remotehost-aaaa", "claude-abc12345");
    state.peerLinkDown("remotehost-aaaa");
    _ = try state.mailboxDeliver("claude-abc12345", "m1", "{}", .submitted);

    try state.peerLinkUp("remotehost-aaaa", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    try std.testing.expect(state.directory.lookup("claude-abc12345") != null);
    try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-aaaa"));
    state.peerLinkDown("remotehost-aaaa");
}

test "RFC-0010: presence is never sent to a peer that did not declare it" {
    // The rule that makes the whole negotiation worth having. Sending to a
    // peer that cannot receive is not harmless — it makes THIS side
    // believe presence is flowing, which is the confusion the negotiation
    // exists to end.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();

    // A peer from before presence relay existed: no capabilities at all.
    try state.peerLinkUp("oldbuild-0001", &conn, 9200, federation.protocol_min, .{});
    try std.testing.expect(!state.peer_links.get("oldbuild-0001").?.caps.has(.presence_relay));

    // Its link is still up and still useful — a peer that cannot relay
    // presence is worth exchanging mail with, so this must not refuse.
    _ = try state.directoryAdvertise("oldbuild-0001", "claude-remote01");
    try std.testing.expect(state.directory.lookup("claude-remote01") != null);

    state.peerLinkDown("oldbuild-0001");
}

test "RFC-0010: a hub_info peer entry reports the version and what the peer provides" {
    // C-DIAGNOSABILITY rests on this being RETAINED and EXPOSED: a human
    // has to be able to see what a peer cannot do, or its silence keeps
    // looking like a fault.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    const fd = try sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    var dummy: u8 = 0;
    var conn = Connection.init(std.testing.allocator, fd, @ptrCast(&dummy), noopRelease);
    defer conn.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try state.peerLinkUp("modern-0001", &conn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    try state.peerLinkUp("oldbuild-0001", &conn, 9201, federation.protocol_min, .{});

    const text = try json.Stringify.valueAlloc(arena.allocator(), try state.peerLinksJson(arena.allocator()), .{});
    try std.testing.expect(mem.indexOf(u8, text, "presence_relay") != null);
    // The old peer's entry exists and its capability list is empty — the
    // absence is REPORTED, not inferred from silence.
    try std.testing.expect(mem.indexOf(u8, text, "oldbuild-0001") != null);
    try std.testing.expect(mem.indexOf(u8, text, "\"capabilities\":[]") != null);

    state.peerLinkDown("modern-0001");
    state.peerLinkDown("oldbuild-0001");
}

test "a hub restart keeps the promise it made when it answered `spooled`" {
    // Serializing the spool correctly is not the same as writing it: the
    // snapshot the hub builds carried mailboxes and durable ids only, so
    // the round trip below went out empty and came back empty while every
    // unit test on the codec passed.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/synapty-spool-test-{d}.json", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), path) catch {};

    var dummy: u8 = 0;
    {
        var state = HubState.init(std.testing.allocator);
        defer state.deinit();
        try state.setPeerId("laptop-0001");
        try state.setStatePath(path);

        const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
        var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
        defer pconn.deinit();
        try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
        _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");
        state.peerLinkDown("remotehost-4e84");

        // Unreachable peer, known host: this is the `spooled` answer.
        const out = try state.mailboxDeliver("claude-remote01", "m1", "{\"type\":\"dm\",\"id\":\"m1\"}", .submitted);
        try std.testing.expectEqual(federation.DeliveryOutcome.spooled, out.outcome);
        {
            state.presence_mutex.lock(io_mod.get()) catch unreachable;
            defer state.presence_mutex.unlock(io_mod.get());
            try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-4e84"));
        }
    }

    var revived = HubState.init(std.testing.allocator);
    defer revived.deinit();
    _ = revived.restoreFromDisk(path);
    {
        revived.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer revived.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), revived.spool.count("remotehost-4e84"));
    }
}

test "C-DIRECTORY: an identity upgrade tells the peers, both halves" {
    // FEDERATION WAS SILENTLY NON-FUNCTIONAL FOR DURABLE IDENTITIES while
    // a link stayed up. `broadcastDirectoryLocked` had exactly two
    // callers — register and unregister — and the upgrade path goes
    // through neither: it removes the pane id from the routing table
    // directly. So a peer's directory kept a pane id this hub no longer
    // hosted and never learnt the durable id, which is the name every
    // agent with a resume_ref actually answers to.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    const afd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var agent_conn = Connection.init(std.testing.allocator, afd, @ptrCast(&dummy), noopRelease);
    defer agent_conn.deinit();
    // AS THE SESSION LOOP DOES: the pane id is the connection's identity
    // before the upgrade, and `prev_id` is read from there.
    try agent_conn.setIdentity("local-1a2b");
    _ = try state.registerAgentTracked("local-1a2b", &agent_conn);
    const before = pconn.outbound.items.len;

    _ = try state.bindDurableIdTracked(&agent_conn, "claude-abc12345", "abc12345-dead-beef");

    // BOTH HALVES, in the frames the peer actually saw.
    var said_add = false;
    var said_remove = false;
    for (pconn.outbound.items[before..]) |frame| {
        if (mem.indexOf(u8, frame, "relay_advertise") == null) continue;
        if (mem.indexOf(u8, frame, "claude-abc12345") != null and
            mem.indexOf(u8, frame, "\"op\":\"add\"") != null) said_add = true;
        if (mem.indexOf(u8, frame, "local-1a2b") != null and
            mem.indexOf(u8, frame, "\"op\":\"remove\"") != null) said_remove = true;
    }
    try std.testing.expect(said_add);
    try std.testing.expect(said_remove);
}

test "C-DIRECTORY: a registration that ends before it works still tells the peers" {
    // FOUND BY APPLYING THE ELEVENTH REVIEW'S OWN LENS BY HAND: how many
    // places owe this rule, and does every one discharge it. The session
    // loop has two error-recovery paths — `setIdentity` fails, the writer
    // thread will not spawn — and both took the routing entry out
    // directly, AFTER `registerAgentTracked` had already told every peer
    // the identity existed. So the peers held an entry for a registration
    // that never worked, a subscriber saw `agent_registered` and never
    // the matching end, and the metadata, generation, wake candidate and
    // mailbox all stayed behind.
    //
    // Both now go through `teardownAgent`, which is what the ordinary
    // path uses. This asserts the whole of what that owes, because the
    // recovery paths are unreachable in a test (they need an allocation
    // or a thread spawn to fail) and the obligation is the function's.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    const afd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var agent_conn = Connection.init(std.testing.allocator, afd, @ptrCast(&dummy), noopRelease);
    defer agent_conn.deinit();
    _ = try state.registerAgentTracked("local-1a2b", &agent_conn);
    const before = pconn.outbound.items.len;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(state.teardownAgent("local-1a2b", &agent_conn, arena.allocator()));

    var said_remove = false;
    for (pconn.outbound.items[before..]) |frame| {
        if (mem.indexOf(u8, frame, "relay_advertise") == null) continue;
        if (mem.indexOf(u8, frame, "local-1a2b") != null and
            mem.indexOf(u8, frame, "\"op\":\"remove\"") != null) said_remove = true;
    }
    try std.testing.expect(said_remove);

    // AND THE OWNERSHIP GUARD SURVIVED THE MOVE: a stale connection's
    // teardown must not delete an entry that now belongs to another
    // ([[WI-2026-08-08-016]]).
    const bfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var newcomer = Connection.init(std.testing.allocator, bfd, @ptrCast(&dummy), noopRelease);
    defer newcomer.deinit();
    _ = try state.registerAgentTracked("local-3c4d", &newcomer);
    try std.testing.expect(!state.teardownAgent("local-3c4d", &agent_conn, arena.allocator()));
    try std.testing.expect(state.routing_table.lookup("local-3c4d") == &newcomer);
}

test "C-DIRECTORY: a displaced connection's pane id is advertised again" {
    // THE SIBLING BRANCH OF THE UPGRADE FIX, and it stayed broken for two
    // hours because the first fix answered the review's finding instead
    // of the clause's rule. A re-home displaces the previous holder,
    // which reverts to its fallback pane id and is bound locally again —
    // and that pane id was withdrawn from every peer at its OWN earlier
    // upgrade. Hosted here, known nowhere: the displaced agent's
    // cross-machine mail is refused `origin_refused`, because the far
    // side requires a directory entry for a stamped source.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");

    // The first holder takes the durable id, giving up its pane id.
    const f1 = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var first = Connection.init(std.testing.allocator, f1, @ptrCast(&dummy), noopRelease);
    defer first.deinit();
    try first.setIdentity("local-1a2b");
    _ = try state.registerAgentTracked("local-1a2b", &first);
    _ = try state.bindDurableIdTracked(&first, "claude-abc12345", "abc12345-dead-beef");

    // A second connection claims the same durable identity: the first is
    // displaced back onto its pane id.
    const f2 = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var second = Connection.init(std.testing.allocator, f2, @ptrCast(&dummy), noopRelease);
    defer second.deinit();
    try second.setIdentity("local-3c4d");
    _ = try state.registerAgentTracked("local-3c4d", &second);
    const before = pconn.outbound.items.len;
    _ = try state.bindDurableIdTracked(&second, "claude-abc12345", "abc12345-dead-beef");

    // THE HUB HOSTS IT AGAIN, so the peers have to hear about it.
    var said_back = false;
    for (pconn.outbound.items[before..]) |frame| {
        if (mem.indexOf(u8, frame, "relay_advertise") == null) continue;
        if (mem.indexOf(u8, frame, "local-1a2b") != null and
            mem.indexOf(u8, frame, "\"op\":\"add\"") != null) said_back = true;
    }
    try std.testing.expect(said_back);
}

test "C-DELIVERY: a second silence does not lose the message" {
    // THE OPPOSITE FAILURE FROM DUPLICATION, and the forward id only
    // settled that one. The flush freed every held copy at WRITE time —
    // `Spool.take`, whose own comment claimed the caller would "re-hold
    // under the pending-ack table", which no caller did. So `spooled`,
    // which C-DELIVERY defines as the message being HELD here, stopped
    // being true the moment the first retry left, and a retry that was
    // also unanswered lost the message outright.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    state.spoolAfterSilence(
        "claude-remote01",
        "m-silent",
        "{\"type\":\"dm\",\"id\":\"m-silent\"}",
        "1000-7",
    );

    // Three flushes, nobody ever answering.
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = state.flushSpoolTo("remotehost-4e84");

    state.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer state.presence_mutex.unlock(io_mod.get());
    // The promise has to survive an unanswered retry.
    try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-4e84"));
    // AND EVERY ATTEMPT CARRIED THE SAME ID, so the peer that may have
    // received the first one recognises the rest.
    var frames: usize = 0;
    for (pconn.outbound.items) |frame| {
        if (mem.indexOf(u8, frame, "relay_forward") == null) continue;
        frames += 1;
        try std.testing.expect(mem.indexOf(u8, frame, "\"forward_id\":\"1000-7\"") != null);
    }
    try std.testing.expect(frames >= 3);
}

test "C-DELIVERY: the id a held copy went out under survives the restart WITH it" {
    // THROUGH THE REAL SNAPSHOT, which is the whole point. The field
    // existed on both structs and in the wire format, the encode wrote it
    // and the decode read it, and a test hand-built `SpooledMessage`
    // values and round-tripped them through serialize/parse — so it was
    // green about a shape the production path never produced. The
    // BUILDER, which copies the live spool into the snapshot, omitted the
    // field, so every persisted copy carried null and a retry after a
    // restart minted a fresh id. The receiver then queued the message a
    // second time: exactly the duplication the id prevents, with a
    // process boundary in the middle.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf, "/tmp/synapty-fwdid-test-{d}.json", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(io_mod.get(), path) catch {};

    var dummy: u8 = 0;
    {
        var state = HubState.init(std.testing.allocator);
        defer state.deinit();
        try state.setPeerId("laptop-0001");
        try state.setStatePath(path);

        const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
        var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
        defer pconn.deinit();
        try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
        defer state.peerLinkDown("remotehost-4e84");
        _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

        // Written to a live link, then nobody answered — so the copy is
        // held UNDER THE ID IT WENT OUT WITH.
        state.spoolAfterSilence(
            "claude-remote01",
            "m-silent",
            "{\"type\":\"dm\",\"id\":\"m-silent\"}",
            "1000-7",
        );
        // `spoolAfterSilence` persists on its own: a `spooled` answer has
        // to mean durable, or it is a promise the hub cannot keep.
    }

    var revived = HubState.init(std.testing.allocator);
    defer revived.deinit();
    _ = revived.restoreFromDisk(path);
    revived.presence_mutex.lock(io_mod.get()) catch unreachable;
    defer revived.presence_mutex.unlock(io_mod.get());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const taken = try revived.spool.take(arena.allocator(), "remotehost-4e84");
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("1000-7", taken[0].forward_id.?);
}

test "C-IDENTITY-SCOPE: a forwarded frame leaves under the name the peer will look it up by" {
    // Two halves of one rule, and only one was built. A hub qualifies a
    // fallback id when it ADVERTISES it, so the far side's directory key
    // is `local-1a2b@laptop-0001` — and the forward path passed the
    // sender's envelope through verbatim, so the source arrived as bare
    // `local-1a2b`. While the receiver's check was a residual that let an
    // unknown source through, the mismatch was invisible; the moment the
    // advertisement became what ADMITS an identity, every cross-machine
    // message from a pane without a resume_ref was refused.
    //
    // It is also what makes a reply possible: an agent that reads a bare
    // `local-1a2b` in `from` has no name it can send back to.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    _ = try state.mailboxDeliver(
        "claude-remote01",
        "m1",
        "{\"type\":\"dm\",\"id\":\"m1\",\"source\":\"local-1a2b\",\"target\":\"claude-remote01\",\"payload\":{}}",
        .submitted,
    );

    // The frame that went out carries the qualified source.
    try std.testing.expect(pconn.outbound.items.len >= 1);
    const sent = pconn.outbound.items[pconn.outbound.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, sent, "local-1a2b@laptop-0001") != null);

    // A DURABLE id is not qualified — qualification is for the ids that
    // are only unique on one machine.
    _ = try state.mailboxDeliver(
        "claude-remote01",
        "m2",
        "{\"type\":\"dm\",\"id\":\"m2\",\"source\":\"claude-local001\",\"target\":\"claude-remote01\",\"payload\":{}}",
        .submitted,
    );
    const sent2 = pconn.outbound.items[pconn.outbound.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, sent2, "claude-local001@") == null);
}

test "C-DELIVERY: `forwarded` waits for the peer, and silence becomes `spooled`" {
    // Before this, a successful WRITE was reported as `forwarded` — an
    // answer that means "the peer took it" while saying only "a socket
    // accepted the bytes". The three endings below are the whole contract
    // the sender owes: the peer said yes, the peer said no in its own
    // words, or nobody said anything inside the bound.
    std.testing.log_level = .err;
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    state.registerForward("f-acked");
    state.completeForward("f-acked", true, "");
    try std.testing.expect(state.awaitForward(a, "f-acked", 50) == .acked);

    // THE PEER'S OWN CODE, carried through rather than replaced by ours:
    // a refusal described in our vocabulary tells the human about us
    // instead of about the machine that said no.
    state.registerForward("f-nacked");
    state.completeForward("f-nacked", false, "not_hosted");
    switch (state.awaitForward(a, "f-nacked", 50)) {
        .nacked => |code| try std.testing.expectEqualStrings("not_hosted", code),
        else => return error.TestExpectedNack,
    }

    // Nobody answered. C-DELIVERY: silence is an UNKNOWN OUTCOME, never
    // read as success or refusal — the copy is held and flushed later.
    state.registerForward("f-silent");
    try std.testing.expect(state.awaitForward(a, "f-silent", 40) == .silence);

    // AND NOTHING IS LEFT BEHIND. A waiter that answered but did not
    // remove its entry would grow this table for the life of the process.
    {
        state.forward_mutex.lock(io_mod.get()) catch unreachable;
        defer state.forward_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 0), state.pending_forwards.count());
    }
}

test "C-DELIVERY: a message spooled on a LIVE link is retried, not left for a reconnect" {
    // `spooled` was invented for two states at once: the link is down, or
    // it is up and the peer did not answer inside the bound. Only the
    // first of those ever got a retry — the flush ran at link
    // establishment and nowhere else — so a message held because a
    // HEALTHY peer was slow waited for a reconnect that peer had no
    // reason to make, and died at its TTL.
    //
    // C-DELIVERY calls `spooled` "a promise", and a promise kept only
    // when the link happens to bounce is not one.
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    // Held because the peer went quiet, on a link that never went down.
    state.spoolAfterSilence(
        "claude-remote01",
        "m-silent",
        "{\"type\":\"dm\",\"id\":\"m-silent\",\"source\":\"claude-local01\",\"target\":\"claude-remote01\",\"payload\":{}}",
        "1000-7",
    );
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(@as(usize, 1), state.spool.count("remotehost-4e84"));
    }

    const before = pconn.outbound.items.len;
    // The clock the rest of federation's expiry already runs on.
    state.federationSweep(std.Io.Timestamp.now(io_mod.get(), .real).toMilliseconds());

    // THE RETRY WENT OUT — which is what this test is for.
    try std.testing.expect(pconn.outbound.items.len > before);
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        // AND THE COPY IS STILL HELD. This asserted 0, pinning the defect
        // rather than the rule: the flush freed every copy at WRITE time,
        // so `spooled` — which C-DELIVERY defines as the message being
        // held here — stopped being true the moment the retry left, and a
        // second silence lost the message outright. A written frame is
        // not an acknowledged one; the release happens where the
        // acknowledgement arrives.
        try std.testing.expectEqual(
            @as(usize, 1),
            state.spool.count("remotehost-4e84"),
        );
    }

    // AND THE ACKNOWLEDGEMENT IS WHAT RELEASES IT.
    const fid = blk: {
        const last = pconn.outbound.items[pconn.outbound.items.len - 1];
        const at = mem.indexOf(u8, last, "\"forward_id\":\"").? + 14;
        break :blk last[at .. at + mem.indexOfScalar(u8, last[at..], '"').?];
    };
    state.releaseSpooled("remotehost-4e84", fid, true);
    {
        state.presence_mutex.lock(io_mod.get()) catch unreachable;
        defer state.presence_mutex.unlock(io_mod.get());
        try std.testing.expectEqual(
            @as(usize, 0),
            state.spool.count("remotehost-4e84"),
        );
    }
}

test "C-DELIVERY: a write to a live link does not decide the answer by itself" {
    std.testing.log_level = .err;
    const sys_mod = @import("sys");
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    try state.setPeerId("laptop-0001");

    var dummy: u8 = 0;
    const pfd = try sys_mod.socket(sys_mod.AF.INET, sys_mod.SOCK.STREAM, 0);
    var pconn = Connection.init(std.testing.allocator, pfd, @ptrCast(&dummy), noopRelease);
    defer pconn.deinit();
    try state.peerLinkUp("remotehost-4e84", &pconn, 9200, federation.protocol_max, federation.CapabilitySet.local());
    defer state.peerLinkDown("remotehost-4e84");
    _ = try state.directoryAdvertise("remotehost-4e84", "claude-remote01");

    const out = try state.mailboxDeliver("claude-remote01", "m1", "{\"type\":\"dm\",\"id\":\"m1\"}", .submitted);
    // It carries the id the caller must wait on rather than an answer.
    try std.testing.expect(out.forward_id != null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = state.awaitForward(arena.allocator(), out.forward_id.?, 1);
}

test "restoreFromDisk owns the path it is handed — the caller's buffer may die (WI-2026-09-02-014)" {
    var state = HubState.init(std.testing.allocator);
    defer state.deinit();
    var buf: [96]u8 = undefined;
    const original = "/nonexistent/synapty-test-owned-path/hub-state.json";
    @memcpy(buf[0..original.len], original);
    _ = state.restoreFromDisk(buf[0..original.len]);
    // The caller's storage is reused for something else entirely.
    @memset(&buf, 'x');
    try std.testing.expectEqualStrings(original, state.state_path.?);
    // Setting it again frees the previous copy rather than leaking it
    // (the testing allocator reports the leak otherwise).
    try state.setStatePath("/elsewhere/hub-state.json");
    try std.testing.expectEqualStrings("/elsewhere/hub-state.json", state.state_path.?);
}
