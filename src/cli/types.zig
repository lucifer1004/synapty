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
    notify: NotifyArgs,
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
    attach: AttachArgs,
    /// A bare `synapty attach`: list this machine's sessions and pick
    /// ([[WI-2026-09-02-013]]).
    attach_choose,
    sessions: SessionsArgs,
    end: EndArgs,
    /// `synapty name` — call a durable session by a human name
    /// ([[RFC-0014]] C-SESSION-NAME).
    name: NameArgs,
    hub: HubArgs,
    mcp_serve,
    github: GithubArgs,
    task: TaskArgs,
    skills: SkillsArgs,
    /// `synapty activity` — recent tool-request activity stream.
    activity,
    /// `synapty wait` — event-driven cross-agent sync (RFC-0004 C-WAIT).
    wait: WaitArgs,
    /// `synapty hooks` — harness adapter pack, hooks column
    /// (WI-2026-08-11-007).
    hooks: HooksArgs,
    /// `synapty hook-event <tool>` — harness hook stdin-JSON dispatcher
    /// (WI-2026-08-11-009). Silent, always exit 0.
    hook_event: HookEventArgs,
    /// `synapty exec <verb>` — agent-initiated pane execution
    /// (RFC-0007, WI-2026-08-11-015). Routes through the workbench.
    exec: ExecArgs,
    /// `synapty put` / `synapty fetch` — move a file between machines
    /// through the workbench ([[RFC-0013]] C-BROKER, [[WI-2026-08-15-010]]).
    file: FileArgs,
    /// `synapty expose <port>` — show a human something this agent is
    /// running ([[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-011]]).
    view: ViewArgs,
    /// `synapty ask` — a decision only a human can make
    /// ([[RFC-0013]] C-PRIMITIVES, [[WI-2026-08-15-012]]).
    ask: AskArgs,
    /// `synapty tools exec --tool <name> --args <json>` — execute a
    /// credential-bound task tool LOCALLY, with no hub involved.
    /// [[ADR-0008]] decision 6: the hub routes and the workbench executes,
    /// so this is what the workbench runs when the hub forwards it a
    /// tool_request. Prints `{"ok":..,"data":..,"error":..}` on stdout.
    tools_exec: ToolsExecArgs,
    /// `synapty identify` — which machine and session this pane is in.
    ///
    /// NOT A PRESENTATION PRIMITIVE. It shows the human nothing; it tells
    /// a caller the facts about its own placement that it cannot see from
    /// inside a shell. An agent knew only its own id, so answering "which
    /// of these panes am I" took probing the workbench with side-effect-
    /// free calls and reading which refusal came back.
    identify,
    /// `synapty exposed [port]` — what became of a page this agent put in
    /// front of a human.
    ///
    /// THE OTHER HALF OF `expose`, not a fifth verb. Exposing was
    /// write-only: an agent could put a page on the human's screen and
    /// then had no way to learn whether it loaded, what it said, or that
    /// it had failed.
    exposed: ExposedArgs,
    /// `synapty version` — print this binary's build identity and exit.
    ///
    /// The workbench asks the binary it SHIPS what build it is. Nothing
    /// at Swift compile time can know: Xcode copies a prebuilt `synapty`
    /// into the bundle, so the two are built separately.
    version,
};

pub const ToolsExecArgs = struct {
    tool: []const u8,
    /// Raw JSON object of tool arguments. Passed through verbatim: the
    /// hub has already applied attribution, and re-deriving it here would
    /// be a claim this process cannot verify.
    args_json: []const u8 = "{}",
};

/// `synapty exec open|run|wait-output|read|close`.
pub const ExecArgs = struct {
    pub const Verb = enum { open, run, wait_output, read, close };
    verb: Verb,
    /// Exec pane handle (run/wait-output/read/close; open returns one).
    pane: ?[]const u8 = null,
    /// run: the single command line.
    command: ?[]const u8 = null,
    /// run: target this agent's own previous run's process, not the shell.
    follow_up: bool = false,
    /// open: initial working directory.
    cwd: ?[]const u8 = null,
    /// wait-output: literal-or-regex pattern.
    pattern: ?[]const u8 = null,
    /// wait-output: mandatory timeout seconds.
    timeout_secs: u32 = 30,
    /// read: final N rows.
    rows: u32 = 40,
};

pub const HookEventArgs = struct {
    tool: []const u8,
};

/// `synapty hooks <install|uninstall|status> <tool> [--yes]`.
/// Installing modifies the USER'S standing harness config, so consent
/// is explicit: y/N prompt on a TTY, --yes required non-interactively.
pub const HooksArgs = struct {
    pub const Action = enum { install, uninstall, status };
    action: Action,
    tool: []const u8,
    yes: bool = false,
};

/// `synapty wait --agent <id> --until <state> [--timeout <secs>]`.
pub const WaitArgs = struct {
    agent: []const u8,
    /// Validated at parse: working | waiting | done | idle (`unknown` is
    /// not a valid target — "the agent went away" is the exit-4 pinning
    /// failure, not a state to wait for).
    until: []const u8,
    timeout_secs: ?u32 = null,
};

/// `synapty skills install` — copy the synapty-task skill to detected
/// agent platforms (RFC-0003 C-SKILLS).
pub const SkillsArgs = struct {
    /// AN ENUM RATHER THAN A BOOL, because a bool has no name to render:
    /// the usage line is built from these fields ([[actionList]]), and a
    /// second action cannot be added without [[cli]]'s switch answering
    /// for it.
    pub const Action = enum { install };
    action: Action,
};

/// `synapty github login` — configure hub repo + store PAT (C-AUTH).
pub const GithubArgs = struct {
    pub const Action = enum { login, logout, status };

    action: Action = .login,
    owner: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    token: ?[]const u8 = null,
};

/// `synapty task ...` — task tools per RFC-0003 C-CLI-TOOLS.
pub const TaskArgs = union(enum) {
    list: TaskListArgs,
    show: TaskShowArgs,
    claim: TaskClaimArgs,
    update: TaskUpdateArgs,
    comment: TaskCommentArgs,
    create: TaskCreateArgs,
};

/// One transfer, named the way [[RFC-0013]] C-ADDRESSING requires: WHAT to
/// reach, never HOW. The caller says a host and a path; the relay topology,
/// the intermediate machine and which connection is reused are none of its
/// business.
pub const FileArgs = struct {
    pub const Verb = enum { put, fetch };
    verb: Verb,
    /// The file to move. For `put` it is local to the calling agent's
    /// machine; for `fetch` it is on `host`.
    path: []const u8,
    /// The other end. A host label the workbench knows.
    host: []const u8,
    /// Destination DIRECTORY. Absent means the other end's home.
    into: ?[]const u8 = null,
};

/// One view an agent asks for.
pub const ViewArgs = struct {
    pub const Verb = enum { expose, withdraw, present };
    verb: Verb,
    /// The port on THIS agent's machine. The workbench decides which local
    /// port reaches it — an agent naming one would be choosing a number on
    /// a machine it cannot see.
    port: u16,
    /// What to call it. The agent's own words, quoted rather than rendered
    /// as a heading of the application's.
    title: ?[]const u8 = null,
    /// `present` only: the artifact on this agent's machine.
    path: ?[]const u8 = null,
    /// `expose` only: WHERE ON THE SERVICE to point — `/lab?token=…`, not a
    /// URL. A service worth showing is rarely at `/`.
    ///
    /// A SEPARATE FIELD FROM `path`, which is a FILE on this machine. One
    /// name for a filesystem path and a URL path would collide on the wire
    /// and mean whichever the reader assumed.
    at: ?[]const u8 = null,
};

pub const ExposedArgs = struct {
    /// One port, or every exposure this agent owns.
    port: ?u16 = null,
};

/// A question, and how long the agent will wait for it.
pub const AskArgs = struct {
    /// A CLOSED SET, AND A SMALL ONE. An answer an agent has no branch for
    /// is worse than no answer, and a question with a dozen choices is not
    /// one a badge can present — it is a form, which this primitive is
    /// deliberately not.
    pub const max_options = 8;

    question: []const u8,
    options_buf: [max_options][]const u8 = undefined,
    option_count: usize = 0,
    /// The agent's own patience, in seconds. It chooses, because only it
    /// knows what it is holding open while it waits.
    timeout_secs: u32 = 300,

    pub fn options(self: *const AskArgs) []const []const u8 {
        return self.options_buf[0..self.option_count];
    }
};

pub const TaskListArgs = struct {
    project: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const TaskShowArgs = struct {
    number: u32,
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

/// Agent registration per [[RFC-0003]] (agent identity).
pub const RegisterArgs = struct {
    tool: []const u8,
    project: ?[]const u8 = null,
    session: ?[]const u8 = null,
    /// RFC-0008: harness session identity (usually supplied by
    /// hook-event, but exposed for manual/skill registration too).
    resume_ref: ?[]const u8 = null,
};

/// `synapty notify --state <s>` per [[WI-2026-08-09-022]] — semantic
/// agent status for the GUI attention pipeline.
pub const NotifyArgs = struct {
    state: []const u8,
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
    /// [[ADR-0008]]: tie this pane's lifetime to the workbench that
    /// spawned it. Absent = a hand-launched wrapper, which no window owns
    /// and which must keep running.
    parent_pid: ?i32 = null,
    /// Hold the child on a pseudoterminal this process owns, and serve
    /// clients that attach to it ([[RFC-0014]]). Without it the child
    /// inherits the standard streams, which is what a local pane wants:
    /// the window IS the terminal there, and there is nothing to survive.
    hold: bool = false,
    /// Leave the session running in a session of its own and return
    /// ([[RFC-0014]] C-HOLDER). Without it `--hold` blocks, which is what
    /// a test or a foreground experiment wants.
    detach: bool = false,
};

/// Arguments for `synapty attach` ([[RFC-0014]] C-START: attaching is its
/// own request, and never creates a session).
pub const AttachArgs = struct {
    agent_id: []const u8,
    /// What this client tells the holder it is ([[RFC-0014]]
    /// C-CLIENT-LABEL): the workbench passes `gui`; a shell is `cli`.
    client: []const u8 = "cli",
    /// Relay mode: move frames between the holder's socket and this
    /// process's standard streams, touching no terminal and holding no
    /// state. This is what runs on the far side of a transport; the
    /// client itself is local ([[WI-2026-08-17-009]]).
    relay: bool = false,
    /// The command that reaches a relay — everything after `--`. Absent
    /// means the holder is on this machine and no transport is involved.
    through: []const []const u8 = &.{},
};

/// Arguments for `synapty sessions`.
pub const SessionsArgs = struct {
    /// Absent: list everything this account holds here.
    agent_id: ?[]const u8 = null,
};

/// Arguments for `synapty end` ([[RFC-0014]] C-END).
pub const EndArgs = struct {
    agent_id: []const u8,
};

pub const NameArgs = struct {
    agent_id: []const u8,
    name: []const u8,
};

/// Arguments for the standalone hub subcommand [[ADR-0004]].
pub const HubArgs = struct {
    port: u16 = 9000,
    /// [[ADR-0008]]: tie this hub's lifetime to a workbench. Absent =
    /// SERVICE mode (the hub outlives every workbench connection, which
    /// is what keeps a remote machine's agents reachable).
    parent_pid: ?i32 = null,
    /// Grace window after the parent dies before exiting, so a
    /// relaunching workbench can reclaim the hub instead of losing it.
    grace_secs: u32 = 30,
    /// Bind exactly --port or fail (SYNAPTY_HUB_PORT semantics).
    strict_port: bool = false,
    /// Override the discovery-file path. A second hub on a machine (a
    /// test, a scratch instance) must not clobber — or delete — the entry
    /// the machine's real hub published.
    discovery_path: ?[]const u8 = null,
    /// `--ensure`: guarantee this machine has a hub and print where it
    /// is, instead of BECOMING one ([[ADR-0008]] stage 3b). Idempotent:
    /// the deploy path runs it on every connect, and a server reboot
    /// self-heals on the next one.
    ensure: bool = false,
    /// [[RFC-0009]] C-BOUNDARIES: this hub's peer id. The AUTHORITATIVE
    /// source is the label the human gave the machine in host management,
    /// because the workbench is the only party that knows the whole fleet
    /// and can therefore keep the ids unique. A hub's own hostname is the
    /// FALLBACK for one nobody configured — two cloud VMs are routinely
    /// both called "ubuntu", and self-naming would make them collide.
    peer_id: ?[]const u8 = null,
    /// `--remint`: mint a NEW peer id for this machine, replacing the
    /// persisted one. The only resolution for a collision ([[RFC-0010]]
    /// C-COLLISION) — two machines hold one id because a disk image was
    /// copied or a backup restored, and renaming cannot fix it because
    /// the label and the id are deliberately independent.
    remint: bool = false,
    /// `--log`: print this machine's hub log and exit ([[RFC-0012]]
    /// C-DESTINATIONS). The way a REMOTE hub's log is read is by running
    /// this over the SSH the operator already has — a file on another
    /// machine is what SSH is for, and streaming logs over the A2A
    /// protocol would give that protocol a reader it should not have.
    log: bool = false,
    /// `--follow`: keep printing as the log grows.
    follow: bool = false,
    /// Override the identity-file path. The same hazard `--discovery-path`
    /// exists for, and worse: a scratch hub that mints into the real file
    /// renames the MACHINE, and every peer keys directory entries and
    /// spooled mail on that name. Learned by doing it — a `--peer-id`
    /// experiment relabelled the operator's laptop after a remote host.
    identity_path: ?[]const u8 = null,
    /// Durable-state file ([[ADR-0008]] stage 2). Absent = ephemeral,
    /// which is honest for a throwaway hub but means queued mail does
    /// not survive a restart.
    state_path: ?[]const u8 = null,
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

/// WHICH KIND OF CALLER TYPES A SUBCOMMAND. The bar is grouped by this,
/// because `synapty --help` is read by a human who wants to know which of
/// these are theirs and by an agent that got an invocation wrong, and a
/// flat list of twenty-nine names answers neither.
pub const Group = enum {
    /// An agent, from inside a pane. The skills teach these.
    agent,
    /// The workbench itself, or a human looking at what it runs.
    workbench,
    /// Something that hosts agents — a harness's hooks, an MCP client.
    harness,
    /// A human wiring this up once.
    setup,

    pub fn heading(self: Group) []const u8 {
        return switch (self) {
            .agent => "For an agent in a pane",
            .workbench => "Run by the workbench",
            .harness => "For a harness",
            .setup => "Setup",
        };
    }
};

/// HOW THE CLI DESCRIBES ONE OF ITS OWN VERBS: the name, who types it,
/// what it does, and how its flags parse. [[Subcommand]] is the PARSED
/// result; this is the description, and `Verb` is taken three times over
/// as a nested action enum.
pub const SubcommandInfo = struct {
    name: []const u8,
    group: Group,
    /// One line, lower case, no full stop — it is a list entry.
    summary: []const u8,
    /// THE FLAGS, IN ZIG-CLAP'S OWN SYNTAX, AND THE ONE PLACE THEY ARE
    /// WRITTEN. `parseArgs` parses from this and `--help` PRINTS from it,
    /// so a flag cannot be documented differently from how it parses.
    /// Empty where the subcommand takes positional arguments or
    /// sub-actions and does its own parsing.
    params: []const u8 = "",
    /// THE POSITIONAL SHAPE, which zig-clap cannot supply: its `<str>`
    /// positionals carry no name, so `clap.help` prints a blank row for
    /// each. Written here for the subcommands that take one, and left
    /// empty for those that are all flags.
    usage: []const u8 = "",
    /// WHAT A HUMAN NEEDS THAT IS NOT A FLAG. Printed after the options,
    /// because glued into `params` it is parsed as another row and read
    /// as belonging to whichever flag came last.
    notes: []const u8 = "",
};

/// THE SUB-ACTIONS A SUBCOMMAND TAKES, RENDERED FROM THE ENUM THAT DEFINES
/// THEM. `install|uninstall|status`, and never a word the parser does not
/// know: the usage strings were typed out beside these enums and drifted,
/// so `synapty hooks --help` told an agent to run `hooks show` — a word
/// `parseHooks` answers with UnknownSubcommand ([[WI-2026-08-30-005]]).
pub fn actionList(comptime Action: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(Action).@"enum".fields, 0..) |f, i| {
            out = out ++ (if (i > 0) "|" else "") ++ actionName(f.name);
        }
        return out;
    }
}

/// A field name as a human types it: `channel_create` is `channel-create`.
pub fn actionName(comptime field: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (field) |c| out = out ++ [_]u8{if (c == '_') '-' else c};
        return out;
    }
}

/// The inverse of [[actionName]] — the action a word names, or null when it
/// names none. THE PARSER'S HALF of the same fact, so a word that appears
/// in the help is a word the parser accepts and the reverse.
pub fn actionFrom(comptime Action: type, word: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        const name = comptime actionName(f.name);
        if (std.mem.eql(u8, word, name)) return @field(Action, f.name);
    }
    return null;
}

/// EVERY SUBCOMMAND THE PARSER ACCEPTS, written once.
///
/// LOAD-BEARING, NOT DECORATIVE. `parseArgs` refuses anything not in here
/// BEFORE it dispatches, so a verb added to the dispatch chain and not to
/// this list does not work at all — which whatever test covers that verb
/// catches at once. A list beside the thing it describes, with nothing
/// keeping the two in step, is how the usage line came to name nine of
/// twenty-nine ([[WI-2026-08-28-017]]).
///
/// `version`, `--version`, `--help` and `-h` are answered before the gate
/// and are not subcommands.
pub const subcommands = [_]SubcommandInfo{
    .{ .name = "register", .group = .agent, .summary = "join the hub under an identity", .params =
        \\    --tool <str>        Tool name (required).
        \\    --project <str>     Project path.
        \\    --session <str>     Session description (free text).
        \\    --resume-ref <str>  Harness session identity (RFC-0008).
        \\-h, --help              Display help and exit.
        \\
    },
    .{ .name = "agents", .group = .agent, .summary = "who else is registered, and where", .params =
        \\-h, --help  Display help and exit.
        \\
    },
    .{ .name = "identify", .group = .agent, .summary = "which machine and pane you are in" },
    .{ .name = "notify", .group = .agent, .summary = "tell the workbench what you are doing", .params =
        \\    --state <str>    Agent state: working | waiting | done (required).
        \\-h, --help           Display help and exit.
        \\
    },
    .{ .name = "send", .group = .agent, .summary = "a message to another agent or channel", .usage = "<agent-or-channel> <text>", .params =
        \\-h, --help  Display help and exit.
        \\<str>
        \\<str>
        \\
    },
    .{ .name = "recv", .group = .agent, .summary = "drain your mailbox", .params =
        \\    --wait  Wait for incoming messages.
        \\-h, --help  Display help and exit.
        \\
    },
    .{ .name = "wait", .group = .agent, .summary = "block until another agent reaches a state", .params =
        \\    --agent <str>    Target agent id (required).
        \\    --until <str>    Target state: working | waiting | done | idle (required).
        \\    --timeout <u32>  Give up after this many seconds (exit 3).
        \\-h, --help           Display help and exit.
        \\
    },
    .{ .name = "channel", .group = .agent, .summary = "a room several agents can talk in", .usage = "create|invite|leave|list [args]" },
    .{ .name = "ask", .group = .agent, .summary = "a decision only a human can make", .usage = "\"<question>\" --option <a> --option <b> [--timeout <secs>]" },
    .{ .name = "present", .group = .agent, .summary = "show the human something you made", .usage = "<path> [--title <text>]" },
    .{ .name = "expose", .group = .agent, .summary = "offer a port you are serving", .usage = "<port> [--title <text>] [--at <path>]" },
    .{ .name = "unexpose", .group = .agent, .summary = "withdraw a port you offered", .usage = "<port>" },
    .{ .name = "exposed", .group = .agent, .summary = "what is on offer, and where", .usage = "[<port>]" },
    .{ .name = "put", .group = .agent, .summary = "send a file to another machine", .usage = "<path> --to <host|agent:id>" },
    .{ .name = "fetch", .group = .agent, .summary = "bring a file back from another machine", .usage = "<path> --from <host>" },
    .{ .name = "exec", .group = .agent, .summary = "open a pane and run something in it", .usage = "open|run|wait-output|read|close [options]" },
    .{ .name = "task", .group = .agent, .summary = "the work queue this project keeps", .usage = "list|show|create|claim|comment|update [args]" },
    .{ .name = "hub", .group = .workbench, .summary = "the message router every agent connects to", .params =
        \\    --port <u16>         Preferred listen port (default: 9000; a ladder tries +1..+9 then an ephemeral port).
        \\    --strict-port        Bind exactly --port or fail.
        \\    --parent-pid <i32>   Exit when this workbench pid dies (service mode when absent).
        \\    --grace-secs <u32>   Seconds after parent death before exiting, allowing a relaunch to reclaim (default: 30).
        \\    --discovery-path <str>  Write the discovery file here instead of ~/.config/synapty/machine/hub.json.
        \\    --state-path <str>      Durable state file (default: ~/.config/synapty/machine/hub-state.json; --no-state disables).
        \\    --no-state              Run without durable state (queued mail does not survive a restart).
        \\    --ensure                Guarantee a hub is running on THIS machine and print where; do not become one.
        \\    --peer-id <str>         Suggested label, used ONLY when minting an id for the first time.
        \\    --remint                Mint a new peer id for this machine (resolves a collision) and exit.
        \\    --log                   Print this machine's hub log and exit.
        \\    --follow                With --log, keep printing as it grows.
        \\    --identity-path <str>   Read/write the machine identity here instead of ~/.config/synapty/machine/identity.json.
        \\-h, --help               Display help and exit.
        \\
    },
    .{ .name = "run", .group = .workbench, .summary = "wrap a pane's shell so the hub can reach it", .params =
        \\    --id <str>          Agent identifier (required).
        \\    --hub <str>         Hub address as host:port (default: 127.0.0.1:9000).
        \\    --parent-pid <i32>  Hang up when this workbench pid dies.
        \\    --hold              Hold the child on a pseudoterminal and serve attachments.
        \\    --detach            With --hold, return once the session answers.
        \\-h, --help              Display help and exit.
        \\
    },
    .{ .name = "attach", .group = .workbench, .summary = "reattach to a durable session", .params =
        \\    --id <str>          Session name; without it, a list to pick from.
        \\    --client <str>      What to tell the holder this client is (default cli).
        \\    --relay             Move frames on stdin/stdout; touch no terminal.
        \\-h, --help              Display help and exit.
        \\
    , .notes =
        \\Press ^] to detach: you leave, and what is running keeps running.
        \\Press it twice to send the character itself through instead.
        \\SYNAPTY_DETACH_KEY binds a different control character, written ^X.
        \\Without --id, a list of this machine's sessions opens; detaching
        \\returns to it. With --id the attach is one act and then exits.
        \\
        \\Ending a session is a separate act — see `synapty end`.
        \\
    },
    .{ .name = "sessions", .group = .workbench, .summary = "what durable sessions this machine holds", .params =
        \\    --id <str>          Answer about one session.
        \\-h, --help              Display help and exit.
        \\
    },
    .{ .name = "end", .group = .workbench, .summary = "end a durable session", .params =
        \\    --id <str>          Session name (required).
        \\-h, --help              Display help and exit.
        \\
    },
    .{ .name = "name", .group = .workbench, .summary = "call a durable session by a human name", .params =
        \\    --id <str>          Session name (required).
        \\    --name <str>        What to call it (required).
        \\-h, --help              Display help and exit.
        \\
    , .notes =
        \\The holder keeps the name and `synapty sessions` lists it; the
        \\workbench sends one when a pane is renamed.
        \\
    },
    .{ .name = "tools", .group = .workbench, .summary = "execute a credential-bound task tool locally", .usage = "exec --tool <name> --args <json>" },
    .{ .name = "activity", .group = .workbench, .summary = "what agents have been asking for" },
    .{ .name = "hooks", .group = .harness, .summary = "the adapter pack a harness installs", .usage = actionList(HooksArgs.Action) ++ " <tool> [--yes]" },
    .{ .name = "hook-event", .group = .harness, .summary = "dispatch one harness hook from stdin JSON", .usage = "<tool> (the event arrives as JSON on stdin)" },
    .{ .name = "mcp-serve", .group = .harness, .summary = "serve this workbench's tools over MCP", .params =
        \\-h, --help  Display help and exit.
        \\
    },
    .{ .name = "skills", .group = .setup, .summary = "install the agent skills into a harness", .usage = actionList(SkillsArgs.Action) },
    .{ .name = "github", .group = .setup, .summary = "connect the task queue to a GitHub repo", .usage = actionList(GithubArgs.Action), .params =
        \\    --owner <str>  Hub repo owner (optional; prompts if omitted).
        \\    --repo <str>   Hub repo name (optional; prompts if omitted).
        \\    --token <str>  Fine-grained PAT (optional; prompts if omitted).
        \\-h, --help        Display help and exit.
        \\
    },
};

pub fn isSubcommand(name: []const u8) bool {
    for (subcommands) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return true;
    }
    return false;
}

/// The flags of a named subcommand, for the parse function that parses
/// them. `@compileError` rather than a default, because a name that is not
/// in the table is a typo and there is no sensible flag set to fall back to.
pub fn paramsFor(comptime name: []const u8) []const u8 {
    for (subcommands) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return sc.params;
    }
    @compileError("no subcommand named " ++ name);
}

/// The usage line of a named subcommand, for whatever has to read what the
/// help promises. `@compileError` for the same reason as [[paramsFor]].
pub fn usageFor(comptime name: []const u8) []const u8 {
    for (subcommands) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return sc.usage;
    }
    @compileError("no subcommand named " ++ name);
}

pub const ParseError = error{
    MissingSubcommand,
    UnknownSubcommand,
    MissingArgument,
    /// AN ARGUMENT THAT IS ONE TOO MANY, which is not a subcommand nobody
    /// recognises. `ask` with nine `--option`s reported "unknown
    /// subcommand" about an invocation whose subcommand was fine, and the
    /// caller reading that message is an agent deciding what to do next
    /// ([[WI-2026-08-28-014]]).
    TooManyArguments,
    HelpRequested,
};
