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

const session_state = @import("../../session_state.zig");
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
