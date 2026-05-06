//! Session state serialization for cross-platform window/tab/split restoration.
//!
//! This module defines the state schema and provides JSON serialization for
//! persisting terminal session layout across restarts. It is platform-independent;
//! the apprt layers (GTK, embedded/macOS) provide the data collection and
//! trigger save/restore at the appropriate lifecycle points.
//!
//! The state file (`session-state.json`) captures the full window/tab/split
//! topology along with per-terminal metadata (PID, working directory, title).
//! An optional companion file (`session-restore.json`) written by an external
//! daemon maps terminal node indices to restore commands (e.g., `claude --resume`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const internal_os = @import("os/main.zig");

const log = std.log.scoped(.session_state);

/// Current schema version. Bump on breaking changes.
pub const version: u32 = 1;

/// Maximum state file size to prevent OOM on corrupt files.
const max_state_size = 8 * 1024 * 1024;

// ─── State Schema ───────────────────────────────────────────────────────────

pub const State = struct {
    version: u32 = version,
    active_window: ?usize = null,
    windows: []const WindowState,
};

pub const WindowState = struct {
    width: u32,
    height: u32,
    maximized: bool = false,
    fullscreen: bool = false,
    selected_tab: usize = 0,
    tabs: []const TabState,
};

pub const TabState = struct {
    title_override: ?[]const u8 = null,
    focused_node: ?usize = null,
    zoomed_node: ?usize = null,
    nodes: []const NodeState,
};

pub const NodeState = struct {
    kind: Kind,
    /// Child process PID (leaf only). Used by restore daemon to resolve
    /// app-specific restore commands.
    pid: ?u64 = null,
    working_directory: ?[]const u8 = null,
    title_override: ?[]const u8 = null,
    /// Layout direction (split only).
    layout: ?Layout = null,
    /// Split ratio (split only).
    ratio: ?f32 = null,
    /// Left child node index (split only).
    left: ?usize = null,
    /// Right child node index (split only).
    right: ?usize = null,

    pub const Kind = enum {
        leaf,
        split,
    };

    pub const Layout = enum {
        horizontal,
        vertical,
    };
};

// ─── Restore Command Schema ─────────────────────────────────────────────────

/// Schema for the daemon-written restore file (`session-restore.json`).
/// Each entry maps a (window_index, tab_index, node_index) triple to a
/// restore command string. The daemon writes this file; Ghostty reads it
/// on startup and deletes it after consuming.
pub const RestoreState = struct {
    version: u32 = version,
    commands: []const RestoreCommand,
};

pub const RestoreCommand = struct {
    window_index: usize = 0,
    tab_index: usize = 0,
    node_index: usize,
    command: []const u8,
};

// ─── Serialization ──────────────────────────────────────────────────────────

/// Write the state to a file atomically (temp file + rename).
/// The file is written with mode 0o600 for security.
pub fn save(state: State, path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;

    // Ensure directory exists
    try std.fs.cwd().makePath(dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    const basename = std.fs.path.basename(path);

    var buf: [8192]u8 = undefined;
    var atomic_file = try dir.atomicFile(basename, .{
        .mode = 0o600,
        .write_buffer = &buf,
    });
    defer atomic_file.deinit();

    const writer = &atomic_file.file_writer.interface;
    try writer.print("{f}\n", .{std.json.fmt(state, .{})});
    try atomic_file.finish();

    log.info("saved session state to {s}", .{path});
}

/// Load state from a file. Returns null if the file doesn't exist.
/// Uses an arena allocator; caller is responsible for freeing.
pub fn load(arena_alloc: Allocator, path: []const u8) !?State {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(arena_alloc, max_state_size) catch |err| {
        log.warn("failed to read session state: {}", .{err});
        return null;
    };

    const state = std.json.parseFromSliceLeaky(State, arena_alloc, content, .{}) catch |err| {
        log.warn("failed to parse session state: {}", .{err});
        return null;
    };

    if (state.version != version) {
        log.warn("session state version mismatch: expected={}, got={}", .{ version, state.version });
        return null;
    }

    return state;
}

/// Load restore commands from the daemon's file. Returns null if not found.
pub fn loadRestore(arena_alloc: Allocator, path: []const u8) !?RestoreState {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = file.readToEndAlloc(arena_alloc, max_state_size) catch |err| {
        log.warn("failed to read session restore: {}", .{err});
        return null;
    };

    const restore = std.json.parseFromSliceLeaky(RestoreState, arena_alloc, content, .{}) catch |err| {
        log.warn("failed to parse session restore: {}", .{err});
        return null;
    };

    if (restore.version != version) {
        log.warn("session restore version mismatch: expected={}, got={}", .{ version, restore.version });
        return null;
    }

    return restore;
}

/// Delete the restore file after consuming it (one-shot).
pub fn deleteRestore(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |err| {
        log.warn("failed to delete restore file: {}", .{err});
    };
}

// ─── Path Helpers ───────────────────────────────────────────────────────────

/// Returns the platform-appropriate path for the session state file.
pub fn statePath(alloc: Allocator) ![]u8 {
    return stateDir(alloc, "session-state.json");
}

/// Returns the platform-appropriate path for the session restore file.
pub fn restorePath(alloc: Allocator) ![]u8 {
    return stateDir(alloc, "session-restore.json");
}

fn stateDir(alloc: Allocator, filename: []const u8) ![]u8 {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = "ghostty" });
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "round-trip serialize/deserialize" {
    const alloc = std.testing.allocator;

    const state = State{
        .active_window = 0,
        .windows = &.{
            .{
                .width = 1920,
                .height = 1080,
                .maximized = false,
                .fullscreen = false,
                .selected_tab = 0,
                .tabs = &.{
                    .{
                        .focused_node = 1,
                        .nodes = &.{
                            .{
                                .kind = .split,
                                .layout = .horizontal,
                                .ratio = 0.5,
                                .left = 1,
                                .right = 2,
                            },
                            .{
                                .kind = .leaf,
                                .pid = 12345,
                                .working_directory = "/home/user/projects",
                                .title_override = "my-session",
                            },
                            .{
                                .kind = .leaf,
                                .pid = 67890,
                                .working_directory = "/tmp",
                            },
                        },
                    },
                },
            },
        },
    };

    // Serialize
    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(alloc);
    try json_buf.writer(alloc).print("{f}", .{std.json.fmt(state, .{})});

    // Deserialize
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(State, arena.allocator(), json_buf.items, .{});

    try std.testing.expectEqual(@as(u32, 1), parsed.version);
    try std.testing.expectEqual(@as(usize, 1), parsed.windows.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.windows[0].tabs.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.windows[0].tabs[0].nodes.len);

    const leaf = parsed.windows[0].tabs[0].nodes[1];
    try std.testing.expectEqual(NodeState.Kind.leaf, leaf.kind);
    try std.testing.expectEqual(@as(u64, 12345), leaf.pid.?);
    try std.testing.expectEqualStrings("/home/user/projects", leaf.working_directory.?);
    try std.testing.expectEqualStrings("my-session", leaf.title_override.?);

    const split = parsed.windows[0].tabs[0].nodes[0];
    try std.testing.expectEqual(NodeState.Kind.split, split.kind);
    try std.testing.expectEqual(NodeState.Layout.horizontal, split.layout.?);
}

test "file-based save/load round-trip" {
    const alloc = std.testing.allocator;
    const tmp_path = "/tmp/ghostty-test-session-state.json";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const state = State{
        .windows = &.{
            .{
                .width = 800,
                .height = 600,
                .tabs = &.{
                    .{
                        .nodes = &.{
                            .{
                                .kind = .leaf,
                                .pid = 42,
                                .working_directory = "/tmp",
                            },
                        },
                    },
                },
            },
        },
    };

    try save(state, tmp_path);

    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const loaded = (try load(arena.allocator(), tmp_path)).?;

    try std.testing.expectEqual(@as(u32, 1), loaded.version);
    try std.testing.expectEqual(@as(usize, 1), loaded.windows.len);
    try std.testing.expectEqual(@as(u64, 42), loaded.windows[0].tabs[0].nodes[0].pid.?);
}

test "load returns null for missing file" {
    const alloc = std.testing.allocator;
    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const result = try load(arena.allocator(), "/tmp/ghostty-nonexistent-file.json");
    try std.testing.expect(result == null);
}

test "restore command round-trip" {
    const alloc = std.testing.allocator;

    const restore = RestoreState{
        .commands = &.{
            .{ .node_index = 0, .command = "claude --resume abc123" },
            .{ .window_index = 0, .tab_index = 1, .node_index = 2, .command = "ssh user@host" },
        },
    };

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(alloc);
    try json_buf.writer(alloc).print("{f}", .{std.json.fmt(restore, .{})});

    var arena = ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(RestoreState, arena.allocator(), json_buf.items, .{});

    try std.testing.expectEqual(@as(usize, 2), parsed.commands.len);
    try std.testing.expectEqualStrings("claude --resume abc123", parsed.commands[0].command);
    try std.testing.expectEqual(@as(usize, 2), parsed.commands[1].node_index);
}
