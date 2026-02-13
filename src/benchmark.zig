const std = @import("std");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const layout_opentui = @import("layout_opentui.zig");
const multiplexer = @import("multiplexer.zig");

pub const Result = struct {
    frames: usize,
    avg_ms: f64,
    p95_ms: f64,
    max_ms: f64,
};

pub const BackendResult = struct {
    backend: []const u8,
    iterations: usize,
    avg_ms: f64,
    p95_ms: f64,
    max_ms: f64,
};

pub const LayoutChurnResult = struct {
    native: BackendResult,
    opentui: ?BackendResult,
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

pub fn runLayoutChurn(allocator: std.mem.Allocator, iterations: usize) !LayoutChurnResult {
    const bounded_iterations = @max(iterations, 1);
    const native_stats = try runLayoutChurnForEngine(
        allocator,
        "native",
        layout_native.NativeLayoutEngine.init(),
        bounded_iterations,
    );

    const opentui_stats = runLayoutChurnForEngine(
        allocator,
        "opentui",
        layout_opentui.OpenTUILayoutEngine.init(),
        bounded_iterations,
    ) catch |err| switch (err) {
        error.OpenTUINotIntegratedYet => null,
        else => return err,
    };

    return .{
        .native = native_stats,
        .opentui = opentui_stats,
    };
}

fn runLayoutChurnForEngine(
    allocator: std.mem.Allocator,
    backend: []const u8,
    engine: layout.LayoutEngine,
    iterations: usize,
) !BackendResult {
    var samples = try allocator.alloc(f64, iterations);
    defer allocator.free(samples);
    defer engine.deinit(allocator);

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const params = churnParams(i);
        const start = std.time.nanoTimestamp();
        const rects = try engine.compute(allocator, params);
        const end = std.time.nanoTimestamp();
        allocator.free(rects);
        samples[i] = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }

    return summarizeSamples(backend, samples);
}

fn churnParams(i: usize) layout.LayoutParams {
    const window_count: u16 = @as(u16, @intCast(1 + (i % 12)));
    const max_master: u16 = @as(u16, @intCast(@min(@as(usize, window_count), 3)));
    const master_count: u16 = @as(u16, @intCast(1 + (i % max_master)));
    return .{
        .layout = .vertical_stack,
        .screen = .{
            .x = 0,
            .y = 0,
            .width = @as(u16, @intCast(80 + (i % 41))),
            .height = @as(u16, @intCast(20 + (i % 21))),
        },
        .window_count = window_count,
        .focused_index = 0,
        .master_count = master_count,
        .master_ratio_permille = @as(u16, @intCast(450 + ((i % 5) * 100))),
        .gap = @as(u16, @intCast(i % 3)),
    };
}

fn summarizeSamples(backend: []const u8, samples: []f64) BackendResult {
    std.mem.sort(f64, samples, {}, lessThanF64);

    var sum: f64 = 0;
    for (samples) |v| sum += v;
    const avg = sum / @as(f64, @floatFromInt(samples.len));
    const p95_idx = (samples.len * 95) / 100;
    const p95 = samples[@min(p95_idx, samples.len - 1)];
    const max = samples[samples.len - 1];

    return .{
        .backend = backend,
        .iterations = samples.len,
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

test "layout churn benchmark returns native stats" {
    const testing = std.testing;
    const result = try runLayoutChurn(testing.allocator, 50);
    try testing.expectEqualStrings("native", result.native.backend);
    try testing.expectEqual(@as(usize, 50), result.native.iterations);
    try testing.expect(result.native.max_ms >= 0);
}
