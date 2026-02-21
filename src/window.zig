const std = @import("std");

pub const Window = struct {
    id: u32,
    title: []u8,
    minimized: bool = false,

    pub fn init(allocator: std.mem.Allocator, id: u32, title: []const u8) !Window {
        return .{
            .id = id,
            .title = try allocator.dupe(u8, title),
        };
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        self.* = undefined;
    }
};
