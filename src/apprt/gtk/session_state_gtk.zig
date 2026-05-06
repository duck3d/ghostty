//! GTK-specific session state collection and restoration.
//!
//! This module bridges the platform-independent session_state module with
//! the GTK apprt, providing functions to build state from live GTK widgets
//! and to trigger save/restore at the appropriate lifecycle points.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const session_state = @import("../../session_state.zig");
const Application = @import("class/application.zig").Application;
const Config = @import("class/config.zig").Config;
const Surface = @import("class/surface.zig").Surface;
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Tab = @import("class/tab.zig").Tab;
const Window = @import("class/window.zig").Window;
const CoreSurface = @import("../../Surface.zig");

const log = std.log.scoped(.session_state_gtk);

/// Build a full State snapshot from all current Ghostty windows.
pub fn buildState(app: anytype, alloc: Allocator) !session_state.State {
    var windows: std.ArrayListUnmanaged(session_state.WindowState) = .empty;
    var active_window: ?usize = null;

    var current = @as(?*glib.List, app.as(gtk.Application).getWindows());
    while (current) |node| : (current = node.f_next) {
        const window_: *gtk.Window = @ptrCast(@alignCast(node.f_data orelse continue));
        const window = gobject.ext.cast(Window, window_) orelse continue;
        if (window.isQuickTerminal()) continue;

        const saved_window = saveWindow(alloc, window) catch |err| {
            log.warn("failed to save window: {}", .{err});
            continue;
        } orelse continue;

        if (window.as(gtk.Window).isActive() != 0) active_window = windows.items.len;
        try windows.append(alloc, saved_window);
    }

    return .{
        .active_window = active_window,
        .windows = windows.items,
    };
}

fn saveWindow(alloc: Allocator, window: *Window) !?session_state.WindowState {
    const tab_view = window.getTabView();
    const total = tab_view.getNPages();
    if (total <= 0) return null;

    var tabs: std.ArrayListUnmanaged(session_state.TabState) = .empty;
    const selected_page = tab_view.getSelectedPage();
    var selected_tab: usize = 0;

    for (0..@intCast(total)) |i| {
        const page = tab_view.getNthPage(@intCast(i));
        if (selected_page == page) selected_tab = i;

        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse continue;
        const saved_tab = saveTab(alloc, tab) catch |err| {
            log.warn("failed to save tab: {}", .{err});
            continue;
        } orelse continue;
        try tabs.append(alloc, saved_tab);
    }

    if (tabs.items.len == 0) return null;

    const size = windowSize(window);
    return .{
        .width = size.width,
        .height = size.height,
        .maximized = window.as(gtk.Window).isMaximized() != 0,
        .fullscreen = window.as(gtk.Window).isFullscreen() != 0,
        .selected_tab = @min(selected_tab, tabs.items.len - 1),
        .tabs = tabs.items,
    };
}

fn saveTab(alloc: Allocator, tab: *Tab) !?session_state.TabState {
    const split_tree = tab.getSplitTree();
    const tree = split_tree.getTree() orelse return null;
    if (tree.nodes.len == 0) return null;

    const active_surface = split_tree.getActiveSurface();
    const nodes = try alloc.alloc(session_state.NodeState, tree.nodes.len);
    var focused_node: ?usize = null;

    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => |surface| {
            if (active_surface == surface) focused_node = i;
            nodes[i] = .{
                .kind = .leaf,
                .pid = surfacePid(surface),
                .working_directory = dupOptional(alloc, surface.getPwd()),
            };
        },

        .split => |split| {
            nodes[i] = .{
                .kind = .split,
                .layout = switch (split.layout) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                },
                .ratio = @floatCast(split.ratio),
                .left = split.left.idx(),
                .right = split.right.idx(),
            };
        },
    };

    return .{
        .focused_node = focused_node,
        .zoomed_node = if (tree.zoomed) |handle| handle.idx() else null,
        .nodes = nodes,
    };
}

/// Get the foreground PID from a GTK Surface via its core surface.
fn surfacePid(surface: *Surface) ?u64 {
    const core = surface.core() orelse return null;
    return core.getProcessInfo(.foreground_pid);
}

fn dupOptional(alloc: Allocator, value: anytype) ?[]const u8 {
    const v = value orelse return null;
    // Handles both []const u8 and [:0]const u8
    return alloc.dupe(u8, v) catch return null;
}

fn windowSize(window: *Window) struct { width: u32, height: u32 } {
    if (window.as(gtk.Native).getSurface()) |surface| {
        return .{
            .width = @intCast(@max(surface.getWidth(), 0)),
            .height = @intCast(@max(surface.getHeight(), 0)),
        };
    }
    return .{
        .width = @intCast(@max(window.as(gtk.Widget).getWidth(), 0)),
        .height = @intCast(@max(window.as(gtk.Widget).getHeight(), 0)),
    };
}

// ─── Restore ────────────────────────────────────────────────────────────────

/// Attempt to restore session state from disk. Returns true if windows
/// were restored, false otherwise (caller should create a default window).
pub fn restoreState(app: anytype) bool {
    const gpa = app.allocator();

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load state file
    const state_path = session_state.statePath(gpa) catch |err| {
        log.warn("failed to get state path: {}", .{err});
        return false;
    };
    defer gpa.free(state_path);

    const state = (session_state.load(alloc, state_path) catch |err| {
        log.warn("failed to load session state: {}", .{err});
        return false;
    }) orelse return false;

    if (state.windows.len == 0) return false;

    // Load restore commands (optional — daemon may not have written one)
    const restore_path = session_state.restorePath(gpa) catch |err| {
        log.warn("failed to get restore path: {}", .{err});
        return false;
    };
    defer gpa.free(restore_path);

    const restore = session_state.loadRestore(alloc, restore_path) catch |err| {
        log.warn("failed to load restore commands: {}", .{err});
        null;
    };

    // Build a lookup: (window_index, tab_index, node_index) → command
    // For simplicity, we use a flat scan since the list is small.

    var restored_any = false;
    var focused_surface: ?*Surface = null;

    for (state.windows, 0..) |saved_window, window_index| {
        if (saved_window.tabs.len == 0) continue;

        const window = Window.new(app, .none);

        if (saved_window.width > 0 and saved_window.height > 0) {
            window.as(gtk.Window).setDefaultSize(
                @intCast(saved_window.width),
                @intCast(saved_window.height),
            );
        }

        const selected_tab = @min(saved_window.selected_tab, saved_window.tabs.len - 1);

        for (saved_window.tabs, 0..) |saved_tab, tab_index| {
            const tab = restoreTab(gpa, alloc, saved_tab, restore, window_index, tab_index) catch |err| {
                log.warn("failed to restore tab: {}", .{err});
                continue;
            } orelse continue;

            // Add tab to window's tab view
            const tab_view = window.getTabView();
            const page = tab_view.addPage(tab.tab.as(gtk.Widget), null);
            if (tab_index == selected_tab) {
                tab_view.setSelectedPage(page);
            }

            // Track focused surface
            if (window_index == (state.active_window orelse 0) and tab_index == selected_tab) {
                if (tab.focus_surface) |s| focused_surface = s;
            }
        }

        if (saved_window.maximized) {
            window.as(gtk.Window).maximize();
        }
        if (saved_window.fullscreen) {
            window.as(gtk.Window).fullscreen();
        }

        gtk.Window.present(window.as(gtk.Window));
        restored_any = true;
    }

    if (focused_surface) |surface| surface.grabFocus();

    // Delete restore file after consuming (one-shot)
    if (restore != null) {
        session_state.deleteRestore(restore_path);
    }

    log.info("restored session state: {} windows", .{state.windows.len});
    return restored_any;
}

const RestoredTab = struct {
    tab: *Tab,
    focus_surface: ?*Surface,
};

fn restoreTab(
    gpa: Allocator,
    scratch: Allocator,
    saved_tab: session_state.TabState,
    restore: ?session_state.RestoreState,
    window_index: usize,
    tab_index: usize,
) !?RestoredTab {
    if (saved_tab.nodes.len == 0) return null;

    // Recursively build the Surface.Tree from the saved node array
    var tree = try buildTree(gpa, scratch, saved_tab.nodes, 0, restore, window_index, tab_index);
    defer tree.deinit();

    // Create tab and adopt the tree
    const tab = Tab.new(null, .none);
    tab.getSplitTree().setTree(&tree);

    // Resolve focused surface
    const restored_tree = tab.getSplitTree().getTree() orelse return error.InvalidState;
    const focus_surface: ?*Surface = focus: {
        const idx = saved_tab.focused_node orelse break :focus null;
        if (idx >= restored_tree.nodes.len) break :focus null;
        switch (restored_tree.nodes[idx]) {
            .leaf => |surface| break :focus surface,
            .split => break :focus null,
        }
    };

    return .{
        .tab = tab,
        .focus_surface = focus_surface,
    };
}

/// Recursively build a Surface.Tree from the serialized node array.
fn buildTree(
    gpa: Allocator,
    scratch: Allocator,
    nodes: []const session_state.NodeState,
    idx: usize,
    restore: ?session_state.RestoreState,
    window_index: usize,
    tab_index: usize,
) !Surface.Tree {
    if (idx >= nodes.len) return error.InvalidState;

    return switch (nodes[idx].kind) {
        .leaf => tree: {
            // Create a surface with the saved working directory
            const wd: ?[:0]const u8 = if (nodes[idx].working_directory) |w|
                try scratch.dupeZ(u8, w)
            else
                null;

            const surface = Surface.new(.{
                .working_directory = wd,
            });
            defer surface.unref();
            _ = surface.refSink();

            // Set pending restore command if available
            if (restore) |r| {
                if (findRestoreCommand(r, window_index, tab_index, idx)) |command| {
                    if (surface.core()) |core| {
                        core.setRestorePendingCommand(command) catch |err| {
                            log.warn("failed to set restore command: {}", .{err});
                        };
                    }
                }
            }

            break :tree try Surface.Tree.init(gpa, surface);
        },

        .split => tree: {
            const left_idx = nodes[idx].left orelse return error.InvalidState;
            const right_idx = nodes[idx].right orelse return error.InvalidState;

            var left = try buildTree(gpa, scratch, nodes, left_idx, restore, window_index, tab_index);
            defer left.deinit();
            var right = try buildTree(gpa, scratch, nodes, right_idx, restore, window_index, tab_index);
            defer right.deinit();

            const direction: Surface.Tree.Split.Direction = switch (nodes[idx].layout orelse return error.InvalidState) {
                .horizontal => .right,
                .vertical => .down,
            };

            break :tree try left.split(
                gpa,
                .root,
                direction,
                @floatCast(nodes[idx].ratio orelse 0.5),
                &right,
            );
        },
    };
}

/// Look up a restore command for a given (window, tab, node) triple.
fn findRestoreCommand(
    restore: session_state.RestoreState,
    window_index: usize,
    tab_index: usize,
    node_index: usize,
) ?[]const u8 {
    for (restore.commands) |cmd| {
        if (cmd.window_index == window_index and
            cmd.tab_index == tab_index and
            cmd.node_index == node_index)
        {
            return cmd.command;
        }
    }
    return null;
}

/// Save the current session state to disk.
pub fn saveState(app: anytype) void {
    var arena = ArenaAllocator.init(app.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    const state = buildState(app, alloc) catch |err| {
        log.warn("failed to build session state: {}", .{err});
        return;
    };
    if (state.windows.len == 0) return;

    const path = session_state.statePath(app.allocator()) catch |err| {
        log.warn("failed to get state path: {}", .{err});
        return;
    };
    defer app.allocator().free(path);

    session_state.save(state, path) catch |err| {
        log.warn("failed to save session state: {}", .{err});
    };
}
