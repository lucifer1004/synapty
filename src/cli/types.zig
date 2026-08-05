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
    hub: HubArgs,
    mcp_serve,
    github: GithubArgs,
    task: TaskArgs,
    skills: SkillsArgs,
    /// `synapty activity` — recent tool-request activity stream.
    activity,
};

/// `synapty skills install` — copy the synapty-task skill to detected
/// agent platforms (RFC-0003 C-SKILLS).
pub const SkillsArgs = struct {
    install: bool = false,
};

/// `synapty github login` — configure hub repo + store PAT (C-AUTH).
pub const GithubArgs = struct {
    owner: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

/// `synapty task ...` — task tools per RFC-0003 C-CLI-TOOLS.
pub const TaskArgs = union(enum) {
    list: TaskListArgs,
    claim: TaskClaimArgs,
    update: TaskUpdateArgs,
    comment: TaskCommentArgs,
    create: TaskCreateArgs,
};

pub const TaskListArgs = struct {
    project: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const TaskClaimArgs = struct {
    number: u32,
};

pub const TaskUpdateArgs = struct {
    number: u32,
    status: []const u8,
};

pub const TaskCommentArgs = struct {
    number: u32,
    body: []const u8,
};

pub const TaskCreateArgs = struct {
    title: []const u8,
    project: ?[]const u8 = null,
    body: ?[]const u8 = null,
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
    /// Hub address. Default: 127.0.0.1
    hub_addr: []const u8 = "127.0.0.1",
    /// Hub port. Default: 9000
    hub_port: u16 = 9000,
};

/// Arguments for the standalone hub subcommand [[ADR-0004]].
pub const HubArgs = struct {
    port: u16 = 9000,
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
