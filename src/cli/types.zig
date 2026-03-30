const std = @import("std");
const protocol = @import("protocol");

// ---------------------------------------------------------------------------
// Subcommand types — IPC actions reference protocol.IpcAction as SSOT
// ---------------------------------------------------------------------------

/// IPC-routed subcommand: the action enum comes from protocol.IpcAction.
pub const IpcSubcommand = struct {
    action: protocol.IpcAction,
    args: IpcArgs,
};

/// Per-action argument payloads.
pub const IpcArgs = union(enum) {
    register: RegisterArgs,
    send: SendArgs,
    recv: RecvArgs,
    agents,
    channel_create: ChannelCreateArgs,
    channel_invite: ChannelInviteArgs,
    channel_leave: ChannelLeaveArgs,
    channel_list,
};

pub const Subcommand = union(enum) {
    ipc: IpcSubcommand,
    run: RunArgs,
    mcp_serve,
};

/// Agent registration per [[RFC-0002:C-AGENT-IDENTITY]].
pub const RegisterArgs = struct {
    tool: []const u8,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const SendArgs = struct {
    target: []const u8,
    text: []const u8,
};

pub const RecvArgs = struct {
    wait: bool,
};

pub const RunArgs = struct {
    agent_id: []const u8,
    child_argv: []const []const u8,
};

pub const ChannelCreateArgs = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const ChannelInviteArgs = struct {
    channel: []const u8,
    agent_id: []const u8,
};

pub const ChannelLeaveArgs = struct {
    channel: []const u8,
};

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingArgument,
    HelpRequested,
};
