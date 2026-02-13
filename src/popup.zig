const std = @import("std");
const layout = @import("layout.zig");

pub const PopupKind = enum {
    command,
    notification,
    persistent,
};

pub const AnimationPhase = enum {
    none,
    fade_in,
    fade_out,
};

pub const AnimationState = struct {
    phase: AnimationPhase = .none,
    // 0..=1000 opacity-like progress.
    progress_permille: u16 = 1000,
    step_permille: u16 = 250,
};

pub const Popup = struct {
    id: u32,
    window_id: ?u32 = null,
    title: []u8,
    rect: layout.Rect,
    modal: bool,
    z_index: u32,
    parent_id: ?u32 = null,
    auto_close: bool = false,
    kind: PopupKind = .command,
    animation: AnimationState = .{},
};

pub const CreateParams = struct {
    window_id: ?u32 = null,
    title: []const u8,
    rect: layout.Rect,
    modal: bool = false,
    parent_id: ?u32 = null,
    auto_close: bool = false,
    kind: PopupKind = .command,
    animate: bool = true,
};

pub const PopupManager = struct {
    allocator: std.mem.Allocator,
    popups: std.ArrayListUnmanaged(Popup) = .{},
    next_popup_id: u32 = 1,
    focused_popup_id: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) PopupManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PopupManager) void {
        for (self.popups.items) |p| self.allocator.free(p.title);
        self.popups.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *PopupManager, params: CreateParams) !u32 {
        const id = self.next_popup_id;
        self.next_popup_id += 1;

        const popup: Popup = .{
            .id = id,
            .window_id = params.window_id,
            .title = try self.allocator.dupe(u8, params.title),
            .rect = params.rect,
            .modal = params.modal,
            .z_index = self.nextZIndex(),
            .parent_id = params.parent_id,
            .auto_close = params.auto_close,
            .kind = params.kind,
            .animation = if (params.animate)
                .{ .phase = .fade_in, .progress_permille = 0, .step_permille = 250 }
            else
                .{},
        };

        try self.popups.append(self.allocator, popup);
        self.focused_popup_id = id;
        return id;
    }

    pub fn close(self: *PopupManager, popup_id: u32) ?Popup {
        for (self.popups.items, 0..) |p, i| {
            if (p.id != popup_id) continue;
            const removed = self.popups.orderedRemove(i);
            self.recomputeFocusAfterRemove(popup_id);
            return removed;
        }
        return null;
    }

    pub fn closeFocused(self: *PopupManager) ?Popup {
        const id = self.focused_popup_id orelse return null;
        return self.close(id);
    }

    pub fn focused(self: *PopupManager) ?*Popup {
        const id = self.focused_popup_id orelse return null;
        return self.getById(id);
    }

    pub fn focusedWindowId(self: *const PopupManager) ?u32 {
        const id = self.focused_popup_id orelse return null;
        for (self.popups.items) |p| {
            if (p.id == id) return p.window_id;
        }
        return null;
    }

    pub fn hasModalOpen(self: *const PopupManager) bool {
        for (self.popups.items) |p| {
            if (p.modal) return true;
        }
        return false;
    }

    pub fn cycleFocus(self: *PopupManager) void {
        if (self.popups.items.len == 0) {
            self.focused_popup_id = null;
            return;
        }

        if (self.focused_popup_id) |id| {
            for (self.popups.items, 0..) |p, i| {
                if (p.id != id) continue;
                const next = (i + 1) % self.popups.items.len;
                self.focused_popup_id = self.popups.items[next].id;
                return;
            }
        }

        self.focused_popup_id = self.popups.items[self.popups.items.len - 1].id;
    }

    pub fn count(self: *const PopupManager) usize {
        return self.popups.items.len;
    }

    pub fn startCloseAnimation(self: *PopupManager, popup_id: u32) bool {
        const p = self.getById(popup_id) orelse return false;
        p.animation.phase = .fade_out;
        if (p.animation.progress_permille == 0) p.animation.progress_permille = 1000;
        return true;
    }

    pub fn startCloseAnimationFocused(self: *PopupManager) bool {
        const popup_id = self.focused_popup_id orelse return false;
        return self.startCloseAnimation(popup_id);
    }

    pub fn advanceAnimations(self: *PopupManager, allocator: std.mem.Allocator) ![]Popup {
        var closed = std.ArrayList(Popup).empty;
        errdefer closed.deinit(allocator);

        var i: usize = 0;
        while (i < self.popups.items.len) {
            var should_remove = false;
            {
                const p = &self.popups.items[i];
                switch (p.animation.phase) {
                    .none => {},
                    .fade_in => {
                        const next = @as(u32, p.animation.progress_permille) + p.animation.step_permille;
                        if (next >= 1000) {
                            p.animation.progress_permille = 1000;
                            p.animation.phase = .none;
                        } else {
                            p.animation.progress_permille = @intCast(next);
                        }
                    },
                    .fade_out => {
                        if (p.animation.progress_permille <= p.animation.step_permille) {
                            p.animation.progress_permille = 0;
                            should_remove = true;
                        } else {
                            p.animation.progress_permille -= p.animation.step_permille;
                        }
                    },
                }
            }

            if (should_remove) {
                const removed = self.popups.orderedRemove(i);
                try closed.append(allocator, removed);
                self.recomputeFocusAfterRemove(removed.id);
                continue;
            }

            i += 1;
        }

        return try closed.toOwnedSlice(allocator);
    }

    fn getById(self: *PopupManager, popup_id: u32) ?*Popup {
        for (self.popups.items) |*p| {
            if (p.id == popup_id) return p;
        }
        return null;
    }

    fn recomputeFocusAfterRemove(self: *PopupManager, removed_id: u32) void {
        if (self.focused_popup_id != removed_id) return;
        if (self.popups.items.len == 0) {
            self.focused_popup_id = null;
            return;
        }

        // Focus topmost popup after close.
        var best_z: u32 = 0;
        var best_id: u32 = self.popups.items[0].id;
        for (self.popups.items) |p| {
            if (p.z_index >= best_z) {
                best_z = p.z_index;
                best_id = p.id;
            }
        }
        self.focused_popup_id = best_id;
    }

    fn nextZIndex(self: *const PopupManager) u32 {
        var max_z: u32 = 0;
        for (self.popups.items) |p| {
            if (p.z_index > max_z) max_z = p.z_index;
        }
        return max_z + 1;
    }
};

test "popup manager assigns monotonic z-index and focuses newest" {
    const testing = std.testing;
    var pm = PopupManager.init(testing.allocator);
    defer pm.deinit();

    const a = try pm.create(.{
        .title = "a",
        .rect = .{ .x = 1, .y = 1, .width = 10, .height = 5 },
    });
    const b = try pm.create(.{
        .title = "b",
        .rect = .{ .x = 2, .y = 2, .width = 10, .height = 5 },
    });

    try testing.expectEqual(@as(usize, 2), pm.count());
    try testing.expectEqual(b, pm.focused_popup_id.?);
    try testing.expect(pm.popups.items[1].z_index > pm.popups.items[0].z_index);
    try testing.expect(a != b);
}

test "popup manager modal detection and close focused" {
    const testing = std.testing;
    var pm = PopupManager.init(testing.allocator);
    defer pm.deinit();

    _ = try pm.create(.{
        .title = "modal",
        .rect = .{ .x = 0, .y = 0, .width = 8, .height = 4 },
        .modal = true,
    });
    try testing.expect(pm.hasModalOpen());

    const closed = pm.closeFocused() orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(closed.title);
    try testing.expectEqual(@as(usize, 0), pm.count());
}

test "popup manager animation tick removes fade-out popup" {
    const testing = std.testing;
    var pm = PopupManager.init(testing.allocator);
    defer pm.deinit();

    const popup_id = try pm.create(.{
        .title = "anim",
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 4 },
        .animate = true,
    });
    try testing.expect(pm.startCloseAnimation(popup_id));

    var closed_any = false;
    var tick: usize = 0;
    while (tick < 8) : (tick += 1) {
        const closed = try pm.advanceAnimations(testing.allocator);
        defer {
            for (closed) |p| testing.allocator.free(p.title);
            testing.allocator.free(closed);
        }
        if (closed.len > 0) {
            closed_any = true;
            break;
        }
    }

    try testing.expect(closed_any);
    try testing.expectEqual(@as(usize, 0), pm.count());
}
