const std = @import("std");
const protocol = @import("protocol");
const mem = std.mem;
const Allocator = mem.Allocator;

// ---------------------------------------------------------------------------
// Hub federation — [[RFC-0009]]
//
// Peer directory, forwarding spool, and the delivery-outcome vocabulary.
// Everything here is PURE STATE: no sockets, no threads, no clock reads
// (callers pass `now_ms`). That is deliberate — the rules this file
// implements are the ones the RFC review found contradicting each other,
// so they need to be testable without a two-machine setup.
//
// The one rule worth restating at the top, because getting it wrong is
// what the review caught: a directory entry is TOMBSTONED when its peer's
// link drops, never discarded. A hub that forgets who hosted an identity
// cannot spool "to the hosting peer", cannot report `unknown` status for
// it, and cannot tell a typo from a machine that is merely off.
// ---------------------------------------------------------------------------

/// C-DELIVERY: the answers a send can produce. An ENUM and not a bool,
/// for a reason a review made concrete — `spooled` and `unknown` are
/// both "not delivered" and collapsing them turns a machine that is
/// merely asleep into a name the human is told they typed wrong.
pub const DeliveryOutcome = enum {
    /// Hosted locally; queued in the local mailbox.
    delivered,
    /// The hosting peer ACKNOWLEDGED it. Not "sent": the ack is what
    /// this word reports ([[RFC-0009]] C-DELIVERY).
    forwarded,
    /// The hosting peer NACKed it, with its reason carried through. The
    /// message is acknowledged, so it is neither retried nor spooled and
    /// the forwarding hub releases its copy.
    refused,
    /// Hosting peer known (a tombstoned entry names it) but unreachable;
    /// held and flushed on reconnect.
    spooled,
    /// Not hosted here and in no directory entry — so this really is a
    /// typo. A name on a peer that is merely asleep still HAS an entry
    /// (entries are tombstoned, not discarded) and is answered `spooled`,
    /// which is what lets this answer be unconditional on reachability.
    unknown,
    /// Two live peers claim the identity (C-DIRECTORY), so it is
    /// addressed by nobody until one of them stops. Not `unknown`: the
    /// identity exists, twice, and the hub can see perfectly well — it is
    /// the claim that is ambiguous, not the view.
    conflicted,

    pub fn toString(self: DeliveryOutcome) []const u8 {
        return @tagName(self);
    }

    /// What to tell the sender when this outcome is not a success, and
    /// `null` when it is.
    ///
    /// THE VERDICT AND THE WORDS ARE ONE SWITCH, deliberately. They were
    /// two: `isSuccess` here, and a second switch in `handleDm` that
    /// spelled out two of the failures and answered `else =>
    /// unreachable`. `conflicted` is neither, and `mailboxDeliver`
    /// returns it whenever two live peers claim one identity — so a
    /// message sent to a contested name PANICKED the hub, and every
    /// agent on the machine lost A2A because two other machines
    /// disagreed. With one switch, a value added without words is a
    /// compile error rather than a crash on a rare day.
    pub fn failureReason(self: DeliveryOutcome) ?[]const u8 {
        return switch (self) {
            .delivered, .forwarded, .spooled => null,
            .unknown => "unknown target",
            .conflicted => "contested: two peer hubs claim this identity, so it is addressed by nobody until one of them stops claiming it",
            .refused => "the hosting peer refused it",
        };
    }

    /// RFC-0003 C-CLI-TOOLS binary contract: which outcomes are success.
    pub fn isSuccess(self: DeliveryOutcome) bool {
        return self.failureReason() == null;
    }
};

// ---------------------------------------------------------------------------
// Peer identity — C-BOUNDARIES
// ---------------------------------------------------------------------------

pub const max_peer_id_len = 64;

/// The CHARSET a peer id may use. Its scope is one human's fleet, which is
/// the only scope in which peers ever meet — this is NOT a globally unique
/// name and the RFC does not pretend otherwise.
///
/// THIS SAID "a peer id is the human's own host label, lowercased", which
/// is the rule [[RFC-0010]] C-PEER-IDENTITY superseded. A peer id is
/// `<label>-<suffix>`, MINTED ONCE by the hub and persisted; the label is
/// half of it and not the whole, and THE LABEL AND THE IDENTITY ARE
/// DIFFERENT THINGS — renaming a machine must not change what directory
/// entries, spooled messages and qualified fallback ids are keyed on. The
/// code below never encoded the old rule; it validates characters, which
/// the new form needs just as much. Only the sentence lagged, and a
/// sentence is what the next reader reaches for.
///
/// `@` is rejected because C-IDENTITY-SCOPE reserves it as the qualifier
/// separator; allowing it here would make `local-ab12@a@b` ambiguous.
pub fn validPeerId(s: []const u8) bool {
    if (s.len == 0 or s.len > max_peer_id_len) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// C-IDENTITY-SCOPE: only the machine-scoped `local-` fallback needs
/// qualifying. A durable id derived from a session UUID is already
/// globally meaningful and MUST NOT be rewritten.
pub fn needsQualification(agent_id: []const u8) bool {
    return mem.startsWith(u8, agent_id, "local-");
}

/// Qualify for advertisement / the `source` of a relayed frame. Durable ids
/// pass through untouched.
pub fn qualify(arena: Allocator, agent_id: []const u8, peer: []const u8) ![]const u8 {
    if (!needsQualification(agent_id)) return agent_id;
    if (mem.indexOfScalar(u8, agent_id, '@') != null) return agent_id; // already qualified
    return std.fmt.allocPrint(arena, "{s}@{s}", .{ agent_id, peer });
}

pub const Qualified = struct {
    base: []const u8,
    peer: ?[]const u8,
};

/// Split a possibly-qualified id. The STRIP half of the encoding: without
/// it, a relayed frame addressed to `local-ab12@laptop` would never match
/// the hosting hub's own `local-ab12`, and C-BOUNDARIES' anti-impersonation
/// rule would then false-positive on exactly the 4-hex collisions
/// qualification exists to prevent.
pub fn splitQualifier(agent_id: []const u8) Qualified {
    const at = mem.lastIndexOfScalar(u8, agent_id, '@') orelse
        return .{ .base = agent_id, .peer = null };
    return .{ .base = agent_id[0..at], .peer = agent_id[at + 1 ..] };
}


/// WHY A HANDSHAKE WAS REFUSED, in one spelling.
///
/// The code travels to the dialling side on the `relay_refused` frame AND
/// into this hub's own event log ([[RFC-0009]] C-EVENT-LOCALITY), and
/// those two must agree: the refusal goes to the machine at fault while
/// the event stays with the hub that knows, so an operator reading one
/// and an operator reading the other are reading about the same event.
/// Four string literals at four call sites could not promise that.
///
/// THE REASONS STAY DISTINCT BECAUSE THE HUMAN'S NEXT ACTION DIFFERS:
/// re-mint an id, fix a configuration, upgrade a build.
pub const RefusalReason = enum {
    invalid_peer_id,
    malformed_hello,
    version_incompatible,
    peer_id_in_use,
    /// The peer hosts more identities than this hub is willing to record
    /// for one peer. [[RFC-0009]] C-DIRECTORY: a hub MUST NOT serve a
    /// view it knows is incomplete, because a dropped identity is
    /// answered `unknown` — which says "no peer advertises it", when a
    /// peer did and this hub declined to record it.
    directory_overflow,

    pub fn toString(self: RefusalReason) []const u8 {
        return @tagName(self);
    }
};

// ---------------------------------------------------------------------------
// Peer directory — C-DIRECTORY
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// The two durations C-DIRECTORY couples
//
// A spooled message names the directory entry that says where to send it.
// If the entry expires first, the message outlives its own destination —
// which is a silent loss, because nothing left in the system knows the
// message was ever addressable. C-DIRECTORY therefore requires tombstone
// retention to be no shorter than the spool TTL.
//
// So retention is DERIVED rather than written down twice. Two
// independent literals in two init functions can agree without anything
// MAKING them agree, and tuning either alone breaks the invariant with no
// signal; the comptime assertion below fails the build instead.
// ---------------------------------------------------------------------------

pub const spool_ttl_ms: i64 = 24 * 60 * 60 * 1000;
pub const directory_retention_ms: i64 = spool_ttl_ms;

comptime {
    if (directory_retention_ms < spool_ttl_ms) @compileError(
        "C-DIRECTORY: tombstone retention must be >= spool TTL, or a spooled " ++
            "message outlives the entry naming where to send it",
    );
}

pub const Directory = struct {
    pub const Entry = struct {
        /// Owned by the directory's allocator.
        peer: []const u8,
        /// False once the peer's link drops. The entry SURVIVES: see the
        /// header note. Only `expire` removes it.
        reachable: bool = true,
        /// When the entry was tombstoned; 0 while reachable.
        tombstoned_ms: i64 = 0,
        /// The hosting peer's own merged conclusion, relayed. Stored on
        /// the entry because it belongs to the identity, not to this hub's
        /// evidence — nothing here re-runs the acceptance rules over it
        /// (C-PRESENCE: a peer relays a conclusion, it does not re-merge
        /// evidence it never saw). While the peer is unreachable this
        /// value is NOT served: a stale status is indistinguishable from
        /// a fresh one, so the reader reports `unknown` instead.
        status: protocol.Status = .unknown,
        /// THE OTHER PEER THAT CLAIMS THIS IDENTITY, if one does
        /// ([[RFC-0009]] C-DIRECTORY). Retained rather than refused,
        /// because refusing the second claim leaves the first routable —
        /// which is picking a winner, and the clause forbids it. While
        /// this is set the identity is addressed by nobody, and the state
        /// clears itself when either claimant withdraws or its link
        /// drops. Owned by the directory's allocator.
        rival: ?[]const u8 = null,

        /// Two live claims: nobody may route to it.
        pub fn conflicted(self: Entry) bool {
            return self.rival != null;
        }
    };

    pub const Advertise = enum {
        /// New identity recorded.
        added,
        /// Already present from the same peer; reachability refreshed.
        refreshed,
        /// A DIFFERENT peer already advertises this identity, LIVE. Both
        /// claims are kept and the identity becomes unroutable until one
        /// of them stops claiming it — two machines answering to one
        /// identity is a configuration error, and silently resolving it
        /// misroutes every message between them.
        conflict,
        /// A different peer claimed it, and the previous claimant's entry
        /// was TOMBSTONED — its link is gone. That is a move, which is
        /// what a re-home looks like from here ([[RFC-0008]] C-REHOME),
        /// so the new claim supersedes the old one. Refusing it would
        /// make a moved agent unroutable for the whole retention window
        /// — deliberately no shorter than the spool TTL, so exactly the
        /// period the design added to keep it reachable.
        moved,
        /// This peer is at its bound. Enforced, not assumed.
        at_capacity,
        /// THIS hub hosts the identity. C-BOUNDARIES states one MUST with
        /// two halves — a hub rejects relayed traffic claiming an identity
        /// it hosts locally, or one another peer has advertised — and only
        /// the second was implemented. A distinct value rather than
        /// reusing `conflict`, because the two have different remedies:
        /// peer-vs-peer is a configuration error between two OTHER
        /// machines, and this one says a peer is speaking for something
        /// standing right here. Directory alone cannot detect it (it holds
        /// only remote entries), so the check lives in HubState, which is
        /// the party that knows both sides.
        local_conflict,
    };

    /// identity -> Entry. Keys owned.
    map: std.StringHashMap(Entry),
    /// A MEMORY BOUND THIS IMPLEMENTATION CHOOSES. [[RFC-0009]]
    /// C-DIRECTORY permits it and deliberately does not set its size;
    /// what the clause settles is what happens AT the bound.
    ///
    /// IT IS NOT DECORATION. C-BOUNDARIES concedes that a relay link is
    /// authenticated by nothing a hub can check — it arrives on the same
    /// loopback listener as every submission — so a local process can
    /// become a peer, and this is the only thing between that and
    /// unbounded directory growth.
    ///
    /// REACHING IT IS A FACT ABOUT THE LINK. The surplus identity used to
    /// be dropped with a log line, and a later send to it answered
    /// `unknown` — "no peer advertises it and this hub does not host it"
    /// — when a peer did and this hub declined to record it, so the hub
    /// reported its own truncation as a name the human typed wrong. The
    /// link is refused now (`directory_overflow`): a link that does not
    /// come up with a stated reason is better than a directory that lies
    /// quietly about one identity in a thousand.
    max_per_peer: usize,
    /// Tombstone retention. C-DIRECTORY requires this be no shorter than
    /// the spool TTL, so a spooled message never outlives the entry naming
    /// where to send it.
    retention_ms: i64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Directory {
        return .{
            .map = std.StringHashMap(Entry).init(allocator),
            .max_per_peer = 1024,
            .retention_ms = directory_retention_ms,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Directory) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.peer);
            if (e.value_ptr.rival) |r| self.allocator.free(r);
        }
        self.map.deinit();
    }

    pub fn countFor(self: *const Directory, peer: []const u8) usize {
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (mem.eql(u8, e.value_ptr.peer, peer)) n += 1;
        }
        return n;
    }

    pub fn advertise(self: *Directory, peer: []const u8, identity: []const u8) !Advertise {
        if (self.map.getPtr(identity)) |existing| {
            if (!mem.eql(u8, existing.peer, peer)) {
                // A claim against a tombstone is a MOVE.
                if (!existing.reachable) {
                    const owned = try self.allocator.dupe(u8, peer);
                    self.allocator.free(existing.peer);
                    existing.* = .{ .peer = owned };
                    return .moved;
                }
                // Two live claims. Keep both; route to neither.
                if (existing.rival) |r| {
                    if (mem.eql(u8, r, peer)) return .conflict;
                    // A third claimant says nothing the second did not.
                    return .conflict;
                }
                existing.rival = try self.allocator.dupe(u8, peer);
                return .conflict;
            }
            existing.reachable = true;
            existing.tombstoned_ms = 0;
            return .refreshed;
        }
        if (self.countFor(peer) >= self.max_per_peer) return .at_capacity;
        const key = try self.allocator.dupe(u8, identity);
        errdefer self.allocator.free(key);
        const owned_peer = try self.allocator.dupe(u8, peer);
        errdefer self.allocator.free(owned_peer);
        try self.map.put(key, .{ .peer = owned_peer });
        return .added;
    }

    /// A peer withdrew one identity (it ended locally on that machine).
    /// This is an explicit statement, unlike a link drop — so the entry
    /// really is removed.
    pub fn withdraw(self: *Directory, peer: []const u8, identity: []const u8) bool {
        const e = self.map.getEntry(identity) orelse return false;
        // EITHER CLAIMANT MAY WITHDRAW, and the one that remains then
        // stands alone — which is how a conflict clears itself without
        // anybody adjudicating it ([[RFC-0009]] C-DIRECTORY).
        if (e.value_ptr.rival) |r| {
            if (mem.eql(u8, r, peer)) {
                self.allocator.free(r);
                e.value_ptr.rival = null;
                return true;
            }
            if (mem.eql(u8, e.value_ptr.peer, peer)) {
                self.allocator.free(e.value_ptr.peer);
                e.value_ptr.peer = r;
                e.value_ptr.rival = null;
                e.value_ptr.reachable = true;
                e.value_ptr.tombstoned_ms = 0;
                return true;
            }
            return false;
        }
        if (!mem.eql(u8, e.value_ptr.peer, peer)) return false;
        const key = e.key_ptr.*;
        const owned_peer = e.value_ptr.peer;
        _ = self.map.remove(identity);
        self.allocator.free(key);
        self.allocator.free(owned_peer);
        return true;
    }

    /// TOMBSTONE every entry from `peer`. Not a removal — the entry is what
    /// tells delivery where to spool and presence whose status is unknown.
    pub fn linkDown(self: *Directory, peer: []const u8, now_ms: i64) usize {
        var n: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| {
            // A CONFLICT CLEARS WHEN ONE SIDE GOES. The claim that is
            // still standing keeps the identity, and it is routable again.
            if (e.value_ptr.rival) |r| {
                if (mem.eql(u8, r, peer)) {
                    self.allocator.free(r);
                    e.value_ptr.rival = null;
                    continue;
                }
                if (mem.eql(u8, e.value_ptr.peer, peer)) {
                    self.allocator.free(e.value_ptr.peer);
                    e.value_ptr.peer = r;
                    e.value_ptr.rival = null;
                    continue;
                }
                continue;
            }
            if (!mem.eql(u8, e.value_ptr.peer, peer)) continue;
            if (!e.value_ptr.reachable) continue;
            e.value_ptr.reachable = false;
            e.value_ptr.tombstoned_ms = now_ms;
            n += 1;
        }
        return n;
    }

    /// Drop tombstones past their retention. Returned identities are
    /// allocator-owned by `arena` and are what the caller logs — at this
    /// point the identity becomes genuinely unknown to this hub, which is
    /// an honest answer rather than a lost one.
    pub fn expire(self: *Directory, arena: Allocator, now_ms: i64) ![]const []const u8 {
        var dead = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.reachable) continue;
            if (now_ms - e.value_ptr.tombstoned_ms < self.retention_ms) continue;
            try dead.append(arena, try arena.dupe(u8, e.key_ptr.*));
        }
        for (dead.items) |id| {
            const entry = self.map.getEntry(id).?;
            const key = entry.key_ptr.*;
            const owned_peer = entry.value_ptr.peer;
            const owned_rival = entry.value_ptr.rival;
            _ = self.map.remove(id);
            self.allocator.free(key);
            self.allocator.free(owned_peer);
            if (owned_rival) |r| self.allocator.free(r);
        }
        return dead.items;
    }

    pub fn lookup(self: *const Directory, identity: []const u8) ?Entry {
        return self.map.get(identity);
    }

    /// Forget every entry belonging to `peer`, reachable or not. Used when
    /// an endpoint presents a NEW identity: the machine was rebuilt, and
    /// its old entries advertise the same globally-meaningful durable
    /// agent ids as its new ones. Leaving both would trip the conflict
    /// rule and make every agent on that machine unroutable for the whole
    /// tombstone retention — with no configuration error behind it and
    /// nothing a human could do (C-PEER-IDENTITY, endpoint continuity).
    pub fn forgetPeer(self: *Directory, arena: Allocator, peer: []const u8) ![]const []const u8 {
        var dead = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (!mem.eql(u8, e.value_ptr.peer, peer)) continue;
            try dead.append(arena, try arena.dupe(u8, e.key_ptr.*));
        }
        for (dead.items) |id| {
            const entry = self.map.getEntry(id) orelse continue;
            const key = entry.key_ptr.*;
            const owned_peer = entry.value_ptr.peer;
            const owned_rival = entry.value_ptr.rival;
            _ = self.map.remove(id);
            self.allocator.free(key);
            self.allocator.free(owned_peer);
            if (owned_rival) |r| self.allocator.free(r);
        }
        return dead.items;
    }

};

// ---------------------------------------------------------------------------
// Forwarding spool — C-DELIVERY
// ---------------------------------------------------------------------------

/// A FORWARD ID, minted by the sending hub and unique on that link
/// ([[RFC-0009]] C-DELIVERY). `<startup>-<n>`: the counter alone repeats
/// after a restart, and the receiver must not see a repeat for a day.
pub fn mintForwardId(arena: Allocator, startup_ms: i64, n: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}-{d}", .{ startup_ms, n });
}

/// How long a receiver remembers a forward it accepted, and how long a
/// sender refuses to reuse an id it last sent. Both ends, one number.
pub const forward_window_ms: i64 = 24 * 60 * 60 * 1000;

/// FORWARDS THIS HUB HAS ALREADY ACCEPTED, so a retry after a lost
/// acknowledgement is acknowledged again rather than queued a second
/// time ([[RFC-0009]] C-DELIVERY).
///
/// NOT DROP-OLDEST AT THE BOUND, which is every other store's answer
/// here and the one thing this store must never do: forgetting a pair IS
/// the duplicate. At the bound it REFUSES to accept a new forward, and
/// the sender — which is holding its copy — spools and tries later.
pub const ForwardSeen = struct {
    /// "peer\x00id" -> when it was accepted. The clock restarts on every
    /// re-acknowledgement, so the receiver's memory always outlives the
    /// sender's silence.
    map: std.StringHashMap(i64),
    max_entries: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) ForwardSeen {
        return .{ .map = std.StringHashMap(i64).init(allocator), .max_entries = 8192, .allocator = allocator };
    }

    pub fn deinit(self: *ForwardSeen) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    fn keyOf(arena: Allocator, peer: []const u8, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ peer, id });
    }

    pub const Admit = enum {
        /// Not seen: queue it, then acknowledge.
        fresh,
        /// Seen: acknowledge again and do NOT queue.
        duplicate,
        /// At the bound: acknowledge nothing, so the sender keeps its copy.
        at_capacity,
    };

    /// Record an accepted forward, or report why it was not recorded.
    pub fn admit(self: *ForwardSeen, peer: []const u8, id: []const u8, now_ms: i64) !Admit {
        var buf: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const probe = keyOf(fba.allocator(), peer, id) catch return .at_capacity;
        if (self.map.getEntry(probe)) |e| {
            e.value_ptr.* = now_ms; // re-acknowledged: the clock restarts
            return .duplicate;
        }
        if (self.map.count() >= self.max_entries) return .at_capacity;
        const owned = try self.allocator.dupe(u8, probe);
        errdefer self.allocator.free(owned);
        try self.map.put(owned, now_ms);
        return .fresh;
    }

    /// Forget what has outlived the window. Returns how many went.
    pub fn expire(self: *ForwardSeen, now_ms: i64) usize {
        var gone: usize = 0;
        var it = self.map.iterator();
        var doomed = std.ArrayList([]const u8).empty;
        defer doomed.deinit(self.allocator);
        while (it.next()) |e| {
            if (now_ms - e.value_ptr.* > forward_window_ms)
                doomed.append(self.allocator, e.key_ptr.*) catch continue;
        }
        for (doomed.items) |k| {
            if (self.map.fetchRemove(k)) |kv| {
                self.allocator.free(kv.key);
                gone += 1;
            }
        }
        return gone;
    }
};

pub const Spool = struct {
    pub const Message = struct {
        /// The DM's own envelope id. Identifies the message; it is NOT
        /// what a relay ack echoes — that is the forward id below.
        msg_id: []const u8,
        target: []const u8,
        raw: []const u8,
        enqueued_ms: i64,
        /// THE ID THIS COPY WAS ALREADY SENT UNDER, when it has been.
        ///
        /// A retry MUST carry it again ([[RFC-0009]] C-DELIVERY: a lost
        /// acknowledgement must not deliver the message twice). The
        /// receiver deduplicates on the forward id, so a retry that mints
        /// a fresh one is a message the receiver has no way to recognise
        /// — which is what happened: the sender's only mint site ran
        /// unconditionally, so every retry looked new and the peer queued
        /// a second copy.
        ///
        /// Null for a copy held because the link was down when it was
        /// submitted: nothing has gone out, so there is no id to reuse.
        forward_id: ?[]const u8 = null,
    };

    /// peer -> FIFO. Order matters: C-DELIVERY's flush rule requires
    /// spooled traffic to precede newly submitted traffic on reconnect,
    /// or a sender's later message can overtake its earlier one with
    /// nothing in the system reporting it.
    map: std.StringHashMap(std.ArrayList(Message)),
    /// Defaults are the SPOOLING hub's own policy, not a negotiated
    /// parameter — the receiving peer never observes this queue, so peers
    /// with different settings interoperate correctly.
    max_per_peer: usize,
    ttl_ms: i64,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Spool {
        return .{
            .map = std.StringHashMap(std.ArrayList(Message)).init(allocator),
            .max_per_peer = 256,
            .ttl_ms = spool_ttl_ms,
            .allocator = allocator,
        };
    }

    fn freeMessage(self: *Spool, m: Message) void {
        self.allocator.free(m.msg_id);
        self.allocator.free(m.target);
        self.allocator.free(m.raw);
        if (m.forward_id) |f| self.allocator.free(f);
    }

    pub fn deinit(self: *Spool) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |m| self.freeMessage(m);
            e.value_ptr.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
        }
        self.map.deinit();
    }

    /// Discard everything held for a peer that no longer exists — its
    /// machine was rebuilt under a new identity, so this mail can never be
    /// forwarded and would otherwise ride out the TTL pointing at nobody.
    pub fn dropPeer(self: *Spool, peer: []const u8) void {
        const entry = self.map.fetchRemove(peer) orelse return;
        var list = entry.value;
        for (list.items) |m| self.freeMessage(m);
        list.deinit(self.allocator);
        self.allocator.free(entry.key);
    }

    pub const Push = enum { queued, dropped_oldest };

    pub fn push(
        self: *Spool,
        peer: []const u8,
        msg_id: []const u8,
        target: []const u8,
        raw: []const u8,
        now_ms: i64,
        forward_id: ?[]const u8,
    ) !Push {
        const gop = try self.map.getOrPut(peer);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, peer) catch |err| {
                _ = self.map.remove(peer);
                return err;
            };
            gop.value_ptr.* = std.ArrayList(Message).empty;
        }
        const copy: Message = .{
            .msg_id = try self.allocator.dupe(u8, msg_id),
            .target = try self.allocator.dupe(u8, target),
            .raw = try self.allocator.dupe(u8, raw),
            .enqueued_ms = now_ms,
            .forward_id = if (forward_id) |f| try self.allocator.dupe(u8, f) else null,
        };
        // The four dupes above go with the message if the append fails
        // ([[WI-2026-09-02-014]]); the partial-literal case is OOM inside
        // OOM and is left to the allocator's own report.
        errdefer self.freeMessage(copy);
        try gop.value_ptr.append(self.allocator, copy);
        if (gop.value_ptr.items.len > self.max_per_peer) {
            const oldest = gop.value_ptr.orderedRemove(0);
            self.freeMessage(oldest);
            return .dropped_oldest;
        }
        return .queued;
    }

    pub fn count(self: *const Spool, peer: []const u8) usize {
        const list = self.map.get(peer) orelse return 0;
        return list.items.len;
    }

    /// Drop expired messages and return their ids for the event log —
    /// C-DELIVERY: an expired message that vanishes silently is
    /// indistinguishable from one that was delivered.
    pub fn expire(self: *Spool, arena: Allocator, now_ms: i64) ![]const []const u8 {
        var dropped = std.ArrayList([]const u8).empty;
        var it = self.map.iterator();
        while (it.next()) |e| {
            var i: usize = 0;
            while (i < e.value_ptr.items.len) {
                const m = e.value_ptr.items[i];
                if (now_ms - m.enqueued_ms < self.ttl_ms) {
                    i += 1;
                    continue;
                }
                try dropped.append(arena, try arena.dupe(u8, m.msg_id));
                _ = e.value_ptr.orderedRemove(i);
                self.freeMessage(m);
            }
        }
        return dropped.items;
    }

    /// STAMP THE ID A HELD COPY HAS NOW GONE OUT UNDER, so the next
    /// attempt reuses it and the receiver can recognise the retry.
    /// Returns false when the message is no longer held.
    pub fn stampForwardId(self: *Spool, peer: []const u8, msg_id: []const u8, fid: []const u8) bool {
        const list = self.map.getPtr(peer) orelse return false;
        for (list.items) |*m| {
            if (!mem.eql(u8, m.msg_id, msg_id)) continue;
            if (m.forward_id) |old| self.allocator.free(old);
            m.forward_id = self.allocator.dupe(u8, fid) catch null;
            return true;
        }
        return false;
    }

    /// THE ACKNOWLEDGEMENT IS WHAT RELEASES A HELD COPY, which is the
    /// whole of C-DELIVERY's promise: "A hub holds its copy until the
    /// acknowledgement arrives, then releases it." Returns true when a
    /// copy was released.
    pub fn releaseByForwardId(self: *Spool, peer: []const u8, fid: []const u8) bool {
        const list = self.map.getPtr(peer) orelse return false;
        for (list.items, 0..) |m, i| {
            const held = m.forward_id orelse continue;
            if (!mem.eql(u8, held, fid)) continue;
            const gone = list.orderedRemove(i);
            self.freeMessage(gone);
            return true;
        }
        return false;
    }

    /// Take everything queued for `peer`, in FIFO order. The caller owns
    /// the returned slices via `arena`; the spool's copies are freed here.
    /// USE THIS ONLY WHERE THE COPIES ARE GENUINELY FINISHED WITH — a
    /// FLUSH is not, because a written frame is not an acknowledged one.
    pub fn take(self: *Spool, arena: Allocator, peer: []const u8) ![]const Message {
        const list = self.map.getPtr(peer) orelse return &.{};
        var out = std.ArrayList(Message).empty;
        for (list.items) |m| {
            try out.append(arena, .{
                .msg_id = try arena.dupe(u8, m.msg_id),
                .target = try arena.dupe(u8, m.target),
                .raw = try arena.dupe(u8, m.raw),
                .enqueued_ms = m.enqueued_ms,
                .forward_id = if (m.forward_id) |f| try arena.dupe(u8, f) else null,
            });
            self.freeMessage(m);
        }
        list.clearRetainingCapacity();
        return out.items;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a claim against a tombstone is a move, and the new peer holds it" {
    var d = Directory.init(testing.allocator);
    defer d.deinit();
    try testing.expectEqual(Directory.Advertise.added, try d.advertise("alpha", "claude-abc"));
    _ = d.linkDown("alpha", 1000);

    // Alpha is gone and beta says the agent is there now. Refusing this
    // would keep a re-homed agent unroutable for the whole retention
    // window ([[RFC-0009]] C-DIRECTORY).
    try testing.expectEqual(Directory.Advertise.moved, try d.advertise("beta", "claude-abc"));
    const e = d.lookup("claude-abc").?;
    try testing.expectEqualStrings("beta", e.peer);
    try testing.expect(e.reachable);
    try testing.expect(!e.conflicted());
}

test "two live claims block both, and the survivor takes it when one goes" {
    var d = Directory.init(testing.allocator);
    defer d.deinit();
    try testing.expectEqual(Directory.Advertise.added, try d.advertise("alpha", "claude-abc"));
    try testing.expectEqual(Directory.Advertise.conflict, try d.advertise("beta", "claude-abc"));

    // NOT A WINNER: the first claimant does not keep it.
    try testing.expect(d.lookup("claude-abc").?.conflicted());

    // Beta's link drops; alpha's claim stands alone and routing resumes.
    _ = d.linkDown("beta", 2000);
    const e = d.lookup("claude-abc").?;
    try testing.expect(!e.conflicted());
    try testing.expectEqualStrings("alpha", e.peer);
}

test "a conflict also clears when one claimant withdraws" {
    var d = Directory.init(testing.allocator);
    defer d.deinit();
    _ = try d.advertise("alpha", "claude-abc");
    _ = try d.advertise("beta", "claude-abc");

    // The FIRST claimant withdrawing hands it to the other, rather than
    // removing an identity the other still hosts.
    try testing.expect(d.withdraw("alpha", "claude-abc"));
    const e = d.lookup("claude-abc").?;
    try testing.expect(!e.conflicted());
    try testing.expectEqualStrings("beta", e.peer);
}

test "DeliveryOutcome maps onto the CLI binary contract" {
    // RFC-0003 C-CLI-TOOLS: success = JSON on stdout exit 0. The two
    // failures are DISTINCT and both must be expressible — that is the
    // whole reason this is not a bool.
    try testing.expect(DeliveryOutcome.delivered.isSuccess());
    try testing.expect(DeliveryOutcome.forwarded.isSuccess());
    try testing.expect(DeliveryOutcome.spooled.isSuccess());
    try testing.expect(!DeliveryOutcome.unknown.isSuccess());
    try testing.expect(!DeliveryOutcome.conflicted.isSuccess());
    try testing.expect(!DeliveryOutcome.refused.isSuccess());
    try testing.expectEqualStrings("refused", DeliveryOutcome.refused.toString());
    try testing.expectEqualStrings("conflicted", DeliveryOutcome.conflicted.toString());
}

test "peer id discipline rejects the qualifier separator" {
    try testing.expect(validPeerId("remotehost"));
    try testing.expect(validPeerId("build-box.lan"));
    try testing.expect(!validPeerId(""));
    try testing.expect(!validPeerId("Remotehost")); // lowercased by the caller
    // '@' would make `local-ab12@a@b` ambiguous.
    try testing.expect(!validPeerId("host@name"));
    try testing.expect(!validPeerId("a" ** (max_peer_id_len + 1)));
}

test "qualification touches the fallback prefix only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A durable id is already globally meaningful — rewriting it would
    // break RFC-0008's hub-state-independent derivation.
    try testing.expectEqualStrings("claude-abc12345", try qualify(a, "claude-abc12345", "laptop"));
    try testing.expectEqualStrings("local-ab12@laptop", try qualify(a, "local-ab12", "laptop"));
    // Idempotent: qualifying twice must not stack separators.
    try testing.expectEqualStrings("local-ab12@laptop", try qualify(a, "local-ab12@laptop", "other"));
}

test "splitQualifier is the strip half of the encoding" {
    const q = splitQualifier("local-ab12@laptop");
    try testing.expectEqualStrings("local-ab12", q.base);
    try testing.expectEqualStrings("laptop", q.peer.?);
    const plain = splitQualifier("claude-abc12345");
    try testing.expectEqualStrings("claude-abc12345", plain.base);
    try testing.expect(plain.peer == null);
}

test "Directory: link drop TOMBSTONES rather than discards" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();

    try testing.expectEqual(Directory.Advertise.added, try dir.advertise("remotehost", "claude-aaaa1111"));
    try testing.expectEqual(Directory.Advertise.refreshed, try dir.advertise("remotehost", "claude-aaaa1111"));

    try testing.expectEqual(@as(usize, 1), dir.linkDown("remotehost", 1_000));

    // THE finding: the entry must still name its host, or delivery cannot
    // spool toward it and presence cannot report unknown for it.
    const e = dir.lookup("claude-aaaa1111").?;
    try testing.expect(!e.reachable);
    try testing.expectEqualStrings("remotehost", e.peer);
}

test "Directory: only expiry forgets, and then honestly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    dir.retention_ms = 10_000;

    _ = try dir.advertise("remotehost", "claude-aaaa1111");
    _ = dir.linkDown("remotehost", 1_000);

    // Inside retention: still known, still unreachable.
    try testing.expectEqual(@as(usize, 0), (try dir.expire(arena.allocator(), 5_000)).len);
    try testing.expect(dir.lookup("claude-aaaa1111") != null);

    // Past retention: forgotten, and the caller gets the id to log.
    const dead = try dir.expire(arena.allocator(), 20_000);
    try testing.expectEqual(@as(usize, 1), dead.len);
    try testing.expectEqualStrings("claude-aaaa1111", dead[0]);
    try testing.expect(dir.lookup("claude-aaaa1111") == null);
}

test "Directory: a second peer claiming an identity is refused, not resolved" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    _ = try dir.advertise("remotehost", "claude-aaaa1111");
    // Silent resolution here would misroute every message between them.
    try testing.expectEqual(
        Directory.Advertise.conflict,
        try dir.advertise("build-box", "claude-aaaa1111"),
    );
    try testing.expectEqualStrings("remotehost", dir.lookup("claude-aaaa1111").?.peer);
}

test "Directory: the per-peer bound is enforced, not assumed" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    dir.max_per_peer = 2;
    _ = try dir.advertise("p", "a");
    _ = try dir.advertise("p", "b");
    try testing.expectEqual(Directory.Advertise.at_capacity, try dir.advertise("p", "c"));
    // A different peer has its own budget.
    try testing.expectEqual(Directory.Advertise.added, try dir.advertise("q", "c"));
}

test "Directory: withdraw is explicit and removes; link drop is not" {
    var dir = Directory.init(testing.allocator);
    defer dir.deinit();
    _ = try dir.advertise("p", "a");
    // A peer cannot withdraw someone else's identity.
    try testing.expect(!dir.withdraw("q", "a"));
    try testing.expect(dir.withdraw("p", "a"));
    try testing.expect(dir.lookup("a") == null);
}

test "Spool: FIFO order survives, because a later message must not overtake" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sp = Spool.init(testing.allocator);
    defer sp.deinit();

    _ = try sp.push("p", "m1", "agent", "{\"n\":1}", 0, null);
    _ = try sp.push("p", "m2", "agent", "{\"n\":2}", 1, null);
    _ = try sp.push("p", "m3", "agent", "{\"n\":3}", 2, null);
    try testing.expectEqual(@as(usize, 3), sp.count("p"));

    const taken = try sp.take(arena.allocator(), "p");
    try testing.expectEqual(@as(usize, 3), taken.len);
    try testing.expectEqualStrings("m1", taken[0].msg_id);
    try testing.expectEqualStrings("m3", taken[2].msg_id);
    try testing.expectEqual(@as(usize, 0), sp.count("p"));
}

test "Spool: TTL expiry reports what it dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sp = Spool.init(testing.allocator);
    defer sp.deinit();
    sp.ttl_ms = 1_000;

    _ = try sp.push("p", "old", "agent", "{}", 0, null);
    _ = try sp.push("p", "new", "agent", "{}", 900, null);

    const dropped = try sp.expire(arena.allocator(), 1_500);
    try testing.expectEqual(@as(usize, 1), dropped.len);
    try testing.expectEqualStrings("old", dropped[0]);
    try testing.expectEqual(@as(usize, 1), sp.count("p"));
}

test "Spool: the per-peer bound drops oldest and says so" {
    var sp = Spool.init(testing.allocator);
    defer sp.deinit();
    sp.max_per_peer = 2;
    try testing.expectEqual(Spool.Push.queued, try sp.push("p", "a", "t", "{}", 0, null));
    try testing.expectEqual(Spool.Push.queued, try sp.push("p", "b", "t", "{}", 0, null));
    try testing.expectEqual(Spool.Push.dropped_oldest, try sp.push("p", "c", "t", "{}", 0, null));
    try testing.expectEqual(@as(usize, 2), sp.count("p"));
}

// ---------------------------------------------------------------------------
// Peer identity minting — [[RFC-0010]] C-PEER-IDENTITY
// ---------------------------------------------------------------------------

pub const peer_suffix_len = 4;

/// Turn any human label into something that can be half of a peer id.
/// DISCIPLINED, NOT REJECTED: a human should not have to rename their
/// laptop to federate, so anything unusable becomes usable rather than an
/// error. Three rules with reasons:
///
///   `@` is excluded BY NAME because C-IDENTITY-SCOPE qualifies a fallback
///   agent id as `local-<4 hex>@<peer-id>` and the receiving hub splits on
///   `@` to strip it — a label containing one makes that split ambiguous,
///   which is a silent misrouting defect reachable from a legal hostname.
///
///   A leading `local-` is displaced because RFC-0008 reserves that prefix
///   for fallback agent ids, and the qualified form puts both namespaces
///   in one lexical space: a machine whose hostname is `local` would mint
///   an id that is simultaneously a well-formed peer id and a well-formed
///   fallback agent id.
///
///   Empty input still has to produce something, or a machine with no
///   usable hostname cannot federate at all.
pub fn disciplineLabel(out: []u8, label: []const u8) []const u8 {
    var n: usize = 0;
    var last_dash = false;
    for (label) |c| {
        if (n >= out.len) break;
        const lower = std.ascii.toLower(c);
        const ok = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or
            lower == '_' or lower == '.';
        if (ok) {
            out[n] = lower;
            n += 1;
            last_dash = false;
        } else if (!last_dash and n > 0) {
            // Anything else — including '@' — collapses to a single dash
            // rather than vanishing, so two different labels do not
            // discipline into the same string.
            out[n] = '-';
            n += 1;
            last_dash = true;
        }
    }
    while (n > 0 and out[n - 1] == '-') n -= 1;
    if (n == 0) {
        const fallback = "host";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    if (mem.startsWith(u8, out[0..n], "local-") or mem.eql(u8, out[0..n], "local")) {
        // Displace rather than refuse. `m-` is arbitrary but stable, and
        // the point is only that the result cannot be mistaken for a
        // fallback AGENT id.
        const shifted = @min(out.len, n + 2);
        var i = shifted;
        while (i > 2) : (i -= 1) out[i - 1] = out[i - 3];
        out[0] = 'm';
        out[1] = '-';
        return out[0..shifted];
    }
    return out[0..n];
}

/// Compose `<label>-<suffix>` within the peer-id length bound. The label
/// is truncated rather than the suffix: the suffix is what makes two
/// same-named machines distinguishable, so losing it defeats the point.
pub fn composePeerId(out: []u8, label: []const u8, suffix: []const u8) []const u8 {
    const room = @min(out.len, max_peer_id_len);
    const keep = if (label.len + 1 + suffix.len <= room)
        label.len
    else
        room -| (1 + suffix.len);
    var n: usize = 0;
    @memcpy(out[0..keep], label[0..keep]);
    n = keep;
    // A truncation can land on a dash; two in a row reads as damage.
    while (n > 0 and out[n - 1] == '-') n -= 1;
    if (n < room) {
        out[n] = '-';
        n += 1;
    }
    const s = @min(suffix.len, room - n);
    @memcpy(out[n .. n + s], suffix[0..s]);
    return out[0 .. n + s];
}

test "disciplineLabel excludes '@' by name — the silent misrouting path" {
    var buf: [64]u8 = undefined;
    // A hostname containing '@' is legal and would make the qualifier
    // split in C-IDENTITY-SCOPE ambiguous.
    try testing.expectEqualStrings("my-box", disciplineLabel(&buf, "my@box"));
    try testing.expectEqualStrings("remotehost", disciplineLabel(&buf, "RemoteHost"));
    try testing.expectEqualStrings("deskmac.local", disciplineLabel(&buf, "deskmac.local"));
    // Collapse, not vanish: two different labels must not discipline into
    // one string.
    try testing.expectEqualStrings("a-b", disciplineLabel(&buf, "a  b"));
    try testing.expect(!mem.eql(u8, disciplineLabel(&buf, "a@b"), disciplineLabel(&buf, "ab")));
}

test "disciplineLabel displaces the reserved agent-id prefix" {
    var buf: [64]u8 = undefined;
    // RFC-0008 reserves `local-`; the qualified form puts peer ids and
    // agent ids in one lexical space, so a machine called `local` must not
    // mint something that is also a well-formed fallback agent id.
    const d = disciplineLabel(&buf, "local");
    try testing.expect(!mem.startsWith(u8, d, "local"));
    const d2 = disciplineLabel(&buf, "local-thing");
    try testing.expect(!mem.startsWith(u8, d2, "local-"));
    // And a machine with no usable name still gets one — refusing would
    // mean it cannot federate at all.
    try testing.expectEqualStrings("host", disciplineLabel(&buf, ""));
    try testing.expectEqualStrings("host", disciplineLabel(&buf, "!!!"));
}

test "composePeerId keeps the suffix when it has to truncate" {
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("deskmac-7f3a", composePeerId(&buf, "deskmac", "7f3a"));
    // The suffix is what makes two same-named machines distinguishable,
    // so a long label loses characters and the suffix survives whole.
    const long = "a" ** 100;
    const id = composePeerId(&buf, long, "7f3a");
    try testing.expect(id.len <= max_peer_id_len);
    try testing.expect(mem.endsWith(u8, id, "-7f3a"));
    try testing.expect(validPeerId(id));
}

test "every disciplined label composes into a VALID peer id" {
    // The contract that matters: discipline + compose must never produce
    // something validPeerId rejects, or a legal hostname becomes a hub
    // that cannot federate.
    var lbuf: [64]u8 = undefined;
    var ibuf: [80]u8 = undefined;
    const hostnames = [_][]const u8{
        "MacBook-Pro", "deskmac.local", "my@box", "", "!!!", "local",
        "RemoteHost.1669084767", "a" ** 100, "-leading", "trailing-",
    };
    for (hostnames) |h| {
        const id = composePeerId(&ibuf, disciplineLabel(&lbuf, h), "7f3a");
        try testing.expect(validPeerId(id));
        try testing.expect(mem.indexOfScalar(u8, id, '@') == null);
        try testing.expect(!mem.startsWith(u8, id, "local-"));
    }
}

// ---------------------------------------------------------------------------
// Version and capability negotiation — [[RFC-0010]] C-CAPABILITIES
// ---------------------------------------------------------------------------

/// The relay protocol versions this build can speak. A RANGE and not a
/// single number: "a version it can speak" is a set, and carrying one
/// integer makes "incompatible" unfalsifiable — which is the same defect
/// this negotiation exists to fix, one level up. relay_hello carried
/// `protocol: 1` from the start and nothing ever read it.
pub const protocol_min: u16 = 1;
pub const protocol_max: u16 = 1;

/// Optional behaviours within a compatible version. Declared by the side
/// that PROVIDES them, with absence as the default — which is what lets a
/// new one ship without a version bump or a coordinated deploy: an older
/// peer simply does not list it and both sides already know what that
/// means.
///
/// The line between a capability and a version bump is drawn at MEANING,
/// not at vocabulary: a change needs a VERSION if a peer that does not
/// implement it could MISINTERPRET a frame it already accepts. A
/// capability is sufficient only when the peer's non-participation is
/// semantically equivalent to the behaviour that existed before.
pub const Capability = enum {
    /// Relays its local agents' merged status to peers. Its absence is
    /// exactly why this negotiation exists: a hub without it linked
    /// normally and then never relayed presence, and the silence read as
    /// a broken feature rather than an older build.
    presence_relay,

    pub fn toString(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?Capability {
        inline for (@typeInfo(Capability).@"enum".fields) |f| {
            if (mem.eql(u8, s, f.name)) return @field(Capability, f.name);
        }
        return null;
    }
};

/// What THIS build provides.
pub const local_capabilities = [_]Capability{.presence_relay};

pub const CapabilitySet = struct {
    bits: u32 = 0,

    pub fn add(self: *CapabilitySet, c: Capability) void {
        self.bits |= @as(u32, 1) << @intFromEnum(c);
    }

    pub fn has(self: CapabilitySet, c: Capability) bool {
        return (self.bits & (@as(u32, 1) << @intFromEnum(c))) != 0;
    }

    pub fn local() CapabilitySet {
        var s = CapabilitySet{};
        for (local_capabilities) |c| s.add(c);
        return s;
    }

    /// Names the peer sent that this build does not know. Kept as a COUNT
    /// rather than dropped silently: a peer declaring things we cannot
    /// name means it is newer, which is worth being able to say.
    pub fn fromNames(names: []const []const u8, unknown: *usize) CapabilitySet {
        var s = CapabilitySet{};
        unknown.* = 0;
        for (names) |n| {
            if (Capability.fromString(n)) |c| s.add(c) else unknown.* += 1;
        }
        return s;
    }
};

/// The version both sides will speak, or null when the ranges do not
/// intersect. Highest common: a newer peer should not be held to an older
/// dialect just because the other side can also speak it.
pub fn negotiateVersion(their_min: u16, their_max: u16) ?u16 {
    const lo = @max(protocol_min, their_min);
    const hi = @min(protocol_max, their_max);
    if (lo > hi) return null;
    return hi;
}

test "negotiateVersion picks the highest common version, or refuses" {
    // Same build.
    try testing.expectEqual(@as(?u16, protocol_max), negotiateVersion(protocol_min, protocol_max));
    // A newer peer that still speaks our dialect: we meet at ours.
    try testing.expectEqual(@as(?u16, protocol_max), negotiateVersion(protocol_min, protocol_max + 5));
    // A peer that has dropped support for everything we speak.
    try testing.expectEqual(@as(?u16, null), negotiateVersion(protocol_max + 1, protocol_max + 3));
    // ...and one too old to have reached us.
    try testing.expect(negotiateVersion(0, 0) == null or protocol_min == 0);
}

test "an unknown capability name is counted, not silently dropped" {
    // A peer declaring names this build cannot resolve means it is NEWER.
    // Losing that fact would make "the peer does less than us" and "the
    // peer does more than us" look identical from here.
    var unknown: usize = 0;
    const s = CapabilitySet.fromNames(&.{ "presence_relay", "time_travel" }, &unknown);
    try testing.expect(s.has(.presence_relay));
    try testing.expectEqual(@as(usize, 1), unknown);

    // Absence is the default, and it is what an older peer looks like.
    var none: usize = 0;
    const empty = CapabilitySet.fromNames(&.{}, &none);
    try testing.expect(!empty.has(.presence_relay));
    try testing.expectEqual(@as(usize, 0), none);
}

test "this build declares what it actually implements" {
    // A declaration that drifts from the implementation is worse than no
    // declaration: a peer would withhold a behaviour we do provide, or
    // invoke one we do not.
    try testing.expect(CapabilitySet.local().has(.presence_relay));
    try testing.expectEqualStrings("presence_relay", Capability.presence_relay.toString());
    try testing.expectEqual(Capability.presence_relay, Capability.fromString("presence_relay").?);
    try testing.expect(Capability.fromString("nope") == null);
}

test "C-DIRECTORY: a default spool entry cannot outlive the directory entry naming its destination" {
    // The comptime assertion covers the constants. This covers the
    // INSTANCES, which is what delivery actually reads and what tests and
    // operators tune independently.
    var dir = Directory.init(std.testing.allocator);
    defer dir.deinit();
    var sp = Spool.init(std.testing.allocator);
    defer sp.deinit();
    try testing.expect(dir.retention_ms >= sp.ttl_ms);
}

test "ForwardSeen: a retry after a lost ack is acknowledged, not queued twice" {
    var seen = ForwardSeen.init(testing.allocator);
    defer seen.deinit();

    try testing.expectEqual(ForwardSeen.Admit.fresh, try seen.admit("remotehost", "100-1", 1000));
    // The ack was lost; the sender still holds its copy and sends again.
    try testing.expectEqual(ForwardSeen.Admit.duplicate, try seen.admit("remotehost", "100-1", 2000));
    // A DIFFERENT peer's identical id is a different forward: the id is
    // unique on ITS link and nothing else.
    try testing.expectEqual(ForwardSeen.Admit.fresh, try seen.admit("buildbox", "100-1", 2000));

    // THE CLOCK RESTARTS ON RE-ACKNOWLEDGEMENT, so the receiver's memory
    // outlives the sender's silence rather than expiring underneath it.
    try testing.expectEqual(@as(usize, 0), seen.expire(2000 + forward_window_ms - 1));
    try testing.expectEqual(ForwardSeen.Admit.duplicate, try seen.admit("remotehost", "100-1", 2000));
}

test "ForwardSeen: at its bound it refuses rather than forgetting" {
    var seen = ForwardSeen.init(testing.allocator);
    defer seen.deinit();
    seen.max_entries = 2;

    try testing.expectEqual(ForwardSeen.Admit.fresh, try seen.admit("p", "1", 0));
    try testing.expectEqual(ForwardSeen.Admit.fresh, try seen.admit("p", "2", 0));
    // Dropping the oldest to make room would forget a pair, and forgetting
    // a pair IS the duplicate this store exists to prevent. Refusing keeps
    // the message with the sender, which is still holding it.
    try testing.expectEqual(ForwardSeen.Admit.at_capacity, try seen.admit("p", "3", 0));
    try testing.expectEqual(ForwardSeen.Admit.duplicate, try seen.admit("p", "1", 0));
}

test "mintForwardId: a restart does not repeat what the receiver still remembers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try mintForwardId(a, 1000, 7);
    const after_restart = try mintForwardId(a, 2000, 7);
    try testing.expect(!std.mem.eql(u8, before, after_restart));
}
