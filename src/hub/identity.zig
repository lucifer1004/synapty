//! RFC-0008 C-IDENTITY — durable agent identity derivation.
//!
//! The HUB is the sole deriver: `<tool>-<first 8 chars of resume_ref>`,
//! deterministic in (tool, resume_ref) and independent of hub state or
//! registration order (these ids land in the persistent task center).
//! Anything that fails the allowlist — or would collide with the
//! reserved pane-fallback namespace — returns a `Rejection` saying why,
//! and the caller keeps the pane identity (RFC-0008: unknown tools
//! degrade safely).

const std = @import("std");

pub const fragment_len = 8;
/// Pane wrapper ids mint `local-XXXX`; a durable derivation must never
/// land in that namespace (RFC-0008 C-IDENTITY).
pub const reserved_prefix = "local-";
pub const max_tool_len = 32;
pub const max_resume_ref_len = 128;

/// Allowlist validation for identity components (the [[RFC-0006]]
/// C-RESUME-PLAN discipline): printable ASCII, no whitespace, no
/// control characters, bounded. Both components are agent-influenced
/// bytes headed for ids and typed incantations — validate, don't escape.
pub fn validComponent(s: []const u8, max_len: usize) bool {
    if (s.len == 0 or s.len > max_len) return false;
    for (s) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
    }
    return true;
}

/// WHY A DERIVATION WAS REFUSED, so the caller can say so.
///
/// [[RFC-0008]] C-IDENTITY requires a rejection to fallback be EVENTED
/// under the kind `identity_rejected`, "because a MUST-be-evented with no
/// kind is a MUST two implementers spell differently, and because the
/// consequence outlives the record by orders of magnitude: an agent runs
/// its whole life under a fallback id while the ring entry explaining why
/// is evicted in minutes". A bare `null` could not carry which of these
/// it was, so nothing could write the reason down.
pub const Rejection = enum {
    /// The tool or the resume_ref is not printable, bounded and
    /// whitespace-free, or the ref is too short to fragment.
    invalid_component,
    /// The derivation collides with the `local-` fallback namespace.
    reserved_prefix,
    /// The derivation contains `@`, which [[RFC-0009]] C-IDENTITY-SCOPE
    /// reserves as the peer qualifier's separator.
    qualifier_separator,

    pub fn toString(self: Rejection) []const u8 {
        return @tagName(self);
    }
};

pub const Derived = union(enum) {
    id: []const u8,
    rejected: Rejection,
};

/// Derive the durable id, or a `Rejection` when the inputs cannot honestly
/// carry identity (the caller falls back to the pane id). The tool component is
/// lowercased so "Claude" and "claude" bind the same identity; the
/// resume_ref is used as-is (determinism over cosmetics). A resume_ref
/// shorter than the fragment cannot fragment and degrades like any
/// validation failure.
pub fn deriveDurableId(
    allocator: std.mem.Allocator,
    tool: []const u8,
    resume_ref: []const u8,
) !Derived {
    if (!validComponent(tool, max_tool_len)) return .{ .rejected = .invalid_component };
    if (!validComponent(resume_ref, max_resume_ref_len)) return .{ .rejected = .invalid_component };
    if (resume_ref.len < fragment_len) return .{ .rejected = .invalid_component };

    const id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ tool, resume_ref[0..fragment_len] });
    for (id[0..tool.len]) |*c| c.* = std.ascii.toLower(c.*);
    if (std.mem.startsWith(u8, id, reserved_prefix)) {
        allocator.free(id);
        return .{ .rejected = .reserved_prefix };
    }
    // `@` IS THE PEER QUALIFIER'S SEPARATOR AND IS RESERVED
    // ([[RFC-0009]] C-IDENTITY-SCOPE, [[RFC-0008]] C-IDENTITY). The
    // validation above admits it — printable, no whitespace, bounded —
    // and a derived id is advertised UNQUALIFIED, so one containing `@`
    // makes the receiving peer split it in the wrong place: `claude@x`
    // with a resume_ref derives `claude@x-abcd1234`, which a peer reads
    // as base `claude` on peer `x-abcd1234`. That is a machine it has no
    // relationship with, named by the agent that chose its own tool
    // string.
    //
    // REJECTED TO FALLBACK RATHER THAN SANITIZED, because C-IDENTITY
    // requires derivation to be deterministic and independent of hub
    // state and a rewrite is neither — the same reason the `local-`
    // collision above falls back instead of being renamed.
    if (std.mem.indexOfScalar(u8, id, '@') != null) {
        allocator.free(id);
        return .{ .rejected = .qualifier_separator };
    }
    return .{ .id = id };
}

// ---------------------------------------------------------------------------
// Tests (WI-2026-08-11-012, RFC-0008 C-IDENTITY)
// ---------------------------------------------------------------------------

const t = std.testing;

test "RFC-0008 C-IDENTITY: a refusal says WHICH refusal it was" {
    // A BARE NULL COULD NOT CARRY IT, so nothing could write the reason
    // down; C-IDENTITY's clause on why it must be evented is quoted above.
    try t.expectEqual(Rejection.qualifier_separator,
                      (try deriveDurableId(t.allocator, "claude@x", "abcd12345678")).rejected);
    try t.expectEqual(Rejection.reserved_prefix,
                      (try deriveDurableId(t.allocator, "local", "-abc12345678")).rejected);
    try t.expectEqual(Rejection.invalid_component,
                      (try deriveDurableId(t.allocator, "cla ude", "abcd12345678")).rejected);
    // And the three spell differently on the wire, which is the whole
    // point of naming them.
    try t.expect(!std.mem.eql(u8, Rejection.reserved_prefix.toString(),
                              Rejection.qualifier_separator.toString()));
}

test "derivation is deterministic and case-stable on tool" {
    const a = (try deriveDurableId(t.allocator, "claude", "abc12345-6789-dead-beef")).id;
    defer t.allocator.free(a);
    try t.expectEqualStrings("claude-abc12345", a);
    const b = (try deriveDurableId(t.allocator, "Claude", "abc12345-6789-dead-beef")).id;
    defer t.allocator.free(b);
    try t.expectEqualStrings(a, b);
}

test "allowlist rejects whitespace, control bytes, non-ascii, oversize" {
    try t.expect((try deriveDurableId(t.allocator, "cla ude", "abcd12345678")) == .rejected);
    try t.expect((try deriveDurableId(t.allocator, "claude", "abc\x1b12345678")) == .rejected);
    try t.expect((try deriveDurableId(t.allocator, "claude", "abcd1234\n5678")) == .rejected);
    try t.expect((try deriveDurableId(t.allocator, "cláude", "abcd12345678")) == .rejected);
    const long = "x" ** 129;
    try t.expect((try deriveDurableId(t.allocator, "claude", long)) == .rejected);
    try t.expect((try deriveDurableId(t.allocator, "", "abcd12345678")) == .rejected);

    // `@` IS THE QUALIFIER SEPARATOR — the walkthrough of what a tool
    // string containing it would do to a peer is on the allowlist above.
    try t.expect((try deriveDurableId(t.allocator, "claude@x", "abcd12345678")) == .rejected);
    // From either side of the separator.
    try t.expect((try deriveDurableId(t.allocator, "claude", "ab@d12345678")) == .rejected);
}

test "short resume_ref degrades to fallback" {
    try t.expect((try deriveDurableId(t.allocator, "claude", "abc")) == .rejected);
}

test "reserved fallback namespace is protected" {
    // tool "local" would mint local-XXXXXXXX — the pane namespace.
    try t.expect((try deriveDurableId(t.allocator, "local", "abcd12345678")) == .rejected);
    try t.expect((try deriveDurableId(t.allocator, "LOCAL", "abcd12345678")) == .rejected);
    // But a tool merely STARTING with "local" is a different namespace.
    const ok = (try deriveDurableId(t.allocator, "localdev", "abcd12345678")).id;
    defer t.allocator.free(ok);
    try t.expectEqualStrings("localdev-abcd1234", ok);
}
