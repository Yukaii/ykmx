const std = @import("std");
const layout_native = @import("layout_native.zig");
const multiplexer = @import("multiplexer.zig");

pub const Result = struct {
    frames: usize,
    avg_ms: f64,
    p95_ms: f64,
    max_ms: f64,
};

pub fn run(allocator: std.mem.Allocator, frames: usize) !Result {
    var mux = multiplexer.Multiplexer.init(allocator, layout_native.NativeLayoutEngine.init());
    defer mux.deinit();

    _ = try mux.createTab("bench");
    _ = try mux.createCommandWindow("producer", &.{
        "/bin/sh",
        "-c",
        "i=0; while [ \"$i\" -lt 120 ]; do echo bench-$i; i=$((i+1)); done",
    });

    var samples = try allocator.alloc(f64, frames);
    defer allocator.free(samples);

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try mux.tick(2, .{ .x = 0, .y = 0, .width = 120, .height = 40 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
        const end = std.time.nanoTimestamp();
        samples[i] = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    std.mem.sort(f64, samples, {}, lessThanF64);

    var sum: f64 = 0;
    for (samples) |v| sum += v;
    const avg = sum / @as(f64, @floatFromInt(samples.len));
    const p95_idx = (samples.len * 95) / 100;
    const p95 = samples[@min(p95_idx, samples.len - 1)];
    const max = samples[samples.len - 1];

    return .{
        .frames = frames,
        .avg_ms = avg,
        .p95_ms = p95,
        .max_ms = max,
    };
}

fn lessThanF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

test "benchmark run returns non-zero frame count" {
    const testing = std.testing;
    const result = try run(testing.allocator, 20);
    try testing.expectEqual(@as(usize, 20), result.frames);
    try testing.expect(result.max_ms >= 0);
}
