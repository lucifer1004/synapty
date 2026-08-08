//! GitHub bridge — user config, Keychain credential, REST client.
//!
//! Implements [[RFC-0003]] C-AUTH (fine-grained PAT in macOS Keychain,
//! login device only) and the request-driven bridge surface: every agent
//! tool request is executed here, on the login device, via the GitHub REST
//! API (C-EVENTS, C-CLI-TOOLS).

const std = @import("std");
const sys = @import("sys");
const io_mod = @import("io");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// User config — ~/.config/synapty/config.toml
// ---------------------------------------------------------------------------

pub const Config = struct {
    owner: []const u8,
    repo: []const u8,
    /// GitHub username of the login-device operator; used as the issue
    /// assignee on task.claim. Optional.
    username: ?[]const u8 = null,

    /// Absolute path to the config file. Returns null if HOME is unset.
    pub fn configPath(allocator: Allocator) !?[]const u8 {
        const home = sys.getenv("HOME") orelse return null;
        const p = try std.fmt.allocPrint(allocator, "{s}/.config/synapty/config.toml", .{home});
        return @as(?[]const u8, p);
    }

    /// Load config from disk. Returns null when the file does not exist.
    pub fn load(allocator: Allocator) !?Config {
        const path = (try configPath(allocator)) orelse return null;
        defer allocator.free(path);

        const io = io_mod.get();
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        const n = file.readPositionalAll(io, &buf, 0) catch return null;
        return parseConfigText(allocator, buf[0..n]);
    }

    /// Parse the TOML-subset config text. Pure function (testable).
    pub fn parseConfigText(allocator: Allocator, text: []const u8) !?Config {
        var owner: ?[]const u8 = null;
        var repo: ?[]const u8 = null;
        var username: ?[]const u8 = null;
        errdefer {
            if (owner) |o| allocator.free(o);
            if (repo) |r| allocator.free(r);
            if (username) |u| allocator.free(u);
        }
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
                const key = std.mem.trim(u8, trimmed[0..eq], " \t");
                const value = std.mem.trim(u8, std.mem.trim(u8, trimmed[eq + 1 ..], " \t"), "\"");
                if (std.mem.eql(u8, key, "owner")) {
                    owner = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "repo")) {
                    repo = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "username")) {
                    username = try allocator.dupe(u8, value);
                }
            }
        }
        if (owner == null or repo == null) {
            // Normal return — errdefer does not fire; free explicitly.
            if (owner) |o| allocator.free(o);
            if (repo) |r| allocator.free(r);
            if (username) |u| allocator.free(u);
            return null;
        }
        return .{ .owner = owner.?, .repo = repo.?, .username = username };
    }

    /// Write config to disk (creates ~/.config/synapty/ as needed).
    pub fn save(self: *const Config, allocator: Allocator) !void {
        const path = (try configPath(allocator)) orelse return error.NoHome;
        defer allocator.free(path);

        const io = io_mod.get();
        const dir_path = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
        try std.Io.Dir.cwd().createDirPath(io, dir_path);

        const content = if (self.username) |u|
            try std.fmt.allocPrint(allocator,
                \\[github]
                \\owner = "{s}"
                \\repo = "{s}"
                \\username = "{s}"
                \\
            , .{ self.owner, self.repo, u })
        else
            try std.fmt.allocPrint(allocator,
                \\[github]
                \\owner = "{s}"
                \\repo = "{s}"
                \\
            , .{ self.owner, self.repo });
        defer allocator.free(content);

        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }

    pub fn deinit(self: *const Config, allocator: Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.repo);
        if (self.username) |u| allocator.free(u);
    }
};

// ---------------------------------------------------------------------------
// Keychain — fine-grained PAT via the `security` CLI (C-AUTH)
// ---------------------------------------------------------------------------

const keychain_service = "synapty.github";

fn runSecurity(allocator: Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, io_mod.get(), .{ .argv = argv });
}

/// Store the token for the given account (owner/repo). Upserts.
/// The token is fed through STDIN (`security -w` with no value reads a
/// line from stdin) — passing it via argv exposed it to any local user
/// through `ps` while the process ran (WI-2026-08-08-028).
pub fn storeToken(allocator: Allocator, account: []const u8, token: []const u8) !void {
    var child = try std.process.spawn(io_mod.get(), .{
        .argv = &.{
            "security", "add-generic-password",
            "-U", // update if exists
            "-a", account,
            "-s", keychain_service,
            "-w", // no value: read the secret from stdin
        },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer std.process.Child.kill(&child, io_mod.get());

    if (child.stdin) |stdin| {
        defer stdin.close(io_mod.get());
        try stdin.writeStreamingAll(io_mod.get(), token);
        try stdin.writeStreamingAll(io_mod.get(), "\n");
    }

    const term = try std.process.Child.wait(&child, io_mod.get());
    switch (term) {
        .exited => |code| if (code != 0) return error.KeychainStoreFailed,
        else => return error.KeychainStoreFailed,
    }
    _ = allocator;
}

/// Load the token for the given account. Returns null when absent.
pub fn loadToken(allocator: Allocator, account: []const u8) !?[]const u8 {
    const result = try runSecurity(allocator, &.{
        "security", "find-generic-password",
        "-a", account,
        "-s", keychain_service,
        "-w",
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| {
            if (code != 0) return null;
            const token = std.mem.trim(u8, result.stdout, "\r\n");
            const t = try allocator.dupe(u8, token);
            return @as(?[]const u8, t);
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// REST client
// ---------------------------------------------------------------------------

pub const ApiError = error{
    GithubApi,
    OutOfMemory,
} || std.http.Client.FetchError;

pub const Api = struct {
    allocator: Allocator,
    owner: []const u8,
    repo: []const u8,
    token: []const u8,

    /// Perform a REST request. `path` starts with "/" (e.g. "/issues").
    /// Returns the response body (caller-owned) on 2xx.
    pub fn request(self: *const Api, method: std.http.Method, path: []const u8, body: ?[]const u8) ApiError![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "https://api.github.com{s}", .{path});
        defer self.allocator.free(url);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = io_mod.get() };
        defer client.deinit();

        var resp = std.Io.Writer.Allocating.init(self.allocator);
        defer resp.deinit();

        const auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token});
        defer self.allocator.free(auth);

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &resp.writer,
            .headers = .{
                .user_agent = .{ .override = "synapty" },
            },
            .extra_headers = &.{
                .{ .name = "Authorization", .value = auth },
                .{ .name = "Accept", .value = "application/vnd.github+json" },
                .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
            },
        }) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => err,
            };
        };

        const status = @intFromEnum(result.status);
        if (status < 200 or status >= 300) {
            // Include the API error message in the failure.
            return error.GithubApi;
        }
        // Dupe out of the writer's buffer: `resp` is deinitialized on return,
        // so the caller must receive an owned slice.
        const resp_body = resp.written();
        return self.allocator.dupe(u8, resp_body);
    }

    /// GET /issues?labels=<labels>&state=<state>
    pub fn listIssues(self: *const Api, labels: ?[]const u8, state: []const u8) ApiError![]const u8 {
        var path_buf: [512]u8 = undefined;
        const path = if (labels) |l|
            std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues?labels={s}&state={s}&per_page=100", .{ self.owner, self.repo, l, state }) catch return error.OutOfMemory
        else
            std.fmt.bufPrint(&path_buf, "/repos/{s}/{s}/issues?state={s}&per_page=100", .{ self.owner, self.repo, state }) catch return error.OutOfMemory;
        return self.request(.GET, path, null);
    }

    /// POST /issues
    pub fn createIssue(self: *const Api, title: []const u8, body: ?[]const u8, labels: []const []const u8) ApiError![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/issues", .{ self.owner, self.repo });
        defer self.allocator.free(path);

        var payload = std.Io.Writer.Allocating.init(self.allocator);
        defer payload.deinit();
        const w = &payload.writer;
        w.writeAll("{\"title\":") catch return error.OutOfMemory;
        try writeJsonString(w, title);
        w.writeAll(", \"labels\":[") catch return error.OutOfMemory;
        for (labels, 0..) |label, i| {
            if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
            try writeJsonString(w, label);
        }
        w.writeAll("]") catch return error.OutOfMemory;
        if (body) |b| {
            w.writeAll(", \"body\":") catch return error.OutOfMemory;
            try writeJsonString(w, b);
        }
        w.writeAll("}") catch return error.OutOfMemory;

        return self.request(.POST, path, payload.written());
    }

    /// PATCH /issues/{number} — update state/labels/assignee.
    pub fn updateIssue(
        self: *const Api,
        number: u32,
        state: ?[]const u8,
        labels: ?[]const []const u8,
        assignee: ?[]const u8,
    ) ApiError![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/issues/{d}", .{ self.owner, self.repo, number });
        defer self.allocator.free(path);

        var payload = std.Io.Writer.Allocating.init(self.allocator);
        defer payload.deinit();
        const w = &payload.writer;
        w.writeAll("{") catch return error.OutOfMemory;
        var first = true;
        if (state) |s| {
            w.writeAll("\"state\":") catch return error.OutOfMemory;
            try writeJsonString(w, s);
            first = false;
        }
        if (labels) |ls| {
            if (!first) w.writeAll(",") catch return error.OutOfMemory;
            w.writeAll("\"labels\":[") catch return error.OutOfMemory;
            for (ls, 0..) |label, i| {
                if (i > 0) w.writeAll(",") catch return error.OutOfMemory;
                try writeJsonString(w, label);
            }
            w.writeAll("]") catch return error.OutOfMemory;
            first = false;
        }
        if (assignee) |a| {
            if (!first) w.writeAll(",") catch return error.OutOfMemory;
            w.writeAll("\"assignees\":[") catch return error.OutOfMemory;
            try writeJsonString(w, a);
            w.writeAll("]") catch return error.OutOfMemory;
        }
        w.writeAll("}") catch return error.OutOfMemory;

        return self.request(.PATCH, path, payload.written());
    }

    /// POST /issues/{number}/comments
    pub fn addComment(self: *const Api, number: u32, body: []const u8) ApiError![]const u8 {
        const path = try std.fmt.allocPrint(self.allocator, "/repos/{s}/{s}/issues/{d}/comments", .{ self.owner, self.repo, number });
        defer self.allocator.free(path);

        var payload = std.Io.Writer.Allocating.init(self.allocator);
        defer payload.deinit();
        const w = &payload.writer;
        w.writeAll("{\"body\":") catch return error.OutOfMemory;
        try writeJsonString(w, body);
        w.writeAll("}") catch return error.OutOfMemory;

        return self.request(.POST, path, payload.written());
    }
};

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Config.parseConfigText roundtrip" {
    const text = "[github]\nowner = \"octocat\"\nrepo = \"synapty-work\"\n";
    const cfg = (try Config.parseConfigText(std.testing.allocator, text)).?;
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("octocat", cfg.owner);
    try std.testing.expectEqualStrings("synapty-work", cfg.repo);
}

test "Config.parseConfigText tolerates spaces and comments" {
    const text = "# comment\nowner=\"octocat\"   \n   repo = \"synapty-work\"  \n";
    const cfg = (try Config.parseConfigText(std.testing.allocator, text)).?;
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("octocat", cfg.owner);
    try std.testing.expectEqualStrings("synapty-work", cfg.repo);
}

test "Config.parseConfigText returns null on missing fields" {
    const text = "owner = \"octocat\"\n";
    try std.testing.expect((try Config.parseConfigText(std.testing.allocator, text)) == null);
}

test "writeJsonString escapes quotes and newlines" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try writeJsonString(&buf.writer, "a\"b\nc\\d");
    try std.testing.expectEqualStrings("\"a\\\"b\\nc\\\\d\"", buf.written());
}
