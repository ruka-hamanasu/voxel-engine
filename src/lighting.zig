const std = @import("std");
const world_mod = @import("world.zig");

const World = world_mod.World;
const Column = world_mod.Column;
const LightRun = world_mod.LightRun;

/// Colored light flood (milestone 9). Emissive voxels seed a BFS
/// flood-fill with per-step attenuation, face-adjacency only. Air cells
/// propagate (level - attenuation); solid cells are terminal and store
/// nothing — render-time face light is sampled from the air cell in
/// front of the face, so light never leaks through geometry. Results
/// are encoded into the columns' lazy light runs; cells the flood never
/// reached keep the material-derived default, which until milestone
/// 11's sky seeding means "no colored light" (identity tint).
pub const Params = struct {
    attenuation: u8 = 8,
    seed_intensity: u8 = 255,
};

pub const Stats = struct {
    lit_columns: usize = 0,
    runs: usize = 0,
};

/// Light sample at one voxel; intensity 0 = no colored light (identity
/// tint in the renderer).
pub const LightSample = struct {
    color_id: u8 = 0,
    intensity: u8 = 0,
};

/// color_id is the seeding material's palette id for now; this helper
/// is the indirection point for milestone 11's dedicated light palette.
pub fn lightColor(color_id: u8) u32 {
    return world_mod.palette[color_id].rgb;
}

/// Light at world height y in a column: linear scan of the (few) light
/// runs, default outside coverage. For monotonic y walks the renderer
/// uses a lockstep LightCursor instead.
pub fn sampleLight(col: *const Column, y: i32) LightSample {
    const runs = col.light orelse return .{};
    var hi: i32 = col.light_base_y;
    for (runs) |run| {
        const lo = hi - @as(i32, run.count) + 1;
        if (y <= hi and y >= lo) return .{ .color_id = run.color_id, .intensity = run.intensity };
        hi = lo - 1;
    }
    return .{};
}

pub fn floodAll(world: *World, allocator: std.mem.Allocator, params: Params) !Stats {
    const w = world.w;
    const h = world.h;
    const d = world.d;
    const n = w * d * h;
    const intensity = try allocator.alloc(u8, n);
    defer allocator.free(intensity);
    @memset(intensity, 0);
    const color = try allocator.alloc(u8, n);
    defer allocator.free(color);
    @memset(color, 0);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);

    // Seed from emissive voxels.
    for (0..w) |x| {
        for (0..d) |z| {
            const col = &world.columns[x * d + z];
            var y: i32 = @intCast(h - 1);
            for (col.runs) |run| {
                const m = run.palette_id;
                if (m != 0 and world_mod.palette[m].emissive != 0) {
                    var yy = y;
                    while (yy > y - @as(i32, run.count)) : (yy -= 1) {
                        const vi: u32 = @intCast((x * d + z) * h + @as(usize, @intCast(yy)));
                        if (params.seed_intensity > intensity[vi]) {
                            intensity[vi] = params.seed_intensity;
                            color[vi] = m;
                        }
                        try queue.append(allocator, vi);
                    }
                }
                y -= run.count;
            }
        }
    }

    // Uniform-cost BFS: a FIFO visits cells in non-increasing level
    // order, so the first write to a cell is the brightest and strict
    // `>` makes ties resolve to the earliest seed (deterministic).
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const vi = queue.items[head];
        const level = intensity[vi];
        const cid = color[vi];
        const uv: usize = vi;
        const y: i32 = @intCast(uv % h);
        const cxz = uv / h;
        const x: i32 = @intCast(cxz / d);
        const z: i32 = @intCast(cxz % d);
        inline for (.{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } }) |off| {
            const nx = x + off[0];
            const ny = y + off[1];
            const nz = z + off[2];
            if (nx >= 0 and ny >= 0 and nz >= 0 and nx < w and ny < h and nz < d) {
                const nvi: usize = (@as(usize, @intCast(nx)) * d + @as(usize, @intCast(nz))) * h + @as(usize, @intCast(ny));
                const nm = world.get(nx, ny, nz);
                if (nm == 0) {
                    const cand = level -| params.attenuation;
                    if (cand > 0 and cand > intensity[nvi]) {
                        intensity[nvi] = cand;
                        color[nvi] = cid;
                        try queue.append(allocator, @intCast(nvi));
                    }
                }
                // Solid neighbor: terminal, records nothing.
            }
        }
    }

    // Encode per column: light runs cover [lowest lit y, highest lit y]
    // (interior unlit voxels become explicit intensity-0 runs); columns
    // with no light keep light = null. Reflooding replaces and frees
    // any previous runs, so a full reflood never leaves stale light.
    var stats: Stats = .{};
    for (0..w) |x| {
        for (0..d) |z| {
            const col = &world.columns[x * d + z];
            if (col.light) |l| allocator.free(l);
            col.light = null;
            col.light_base_y = 0;
            const base = (x * d + z) * h;
            var top: ?usize = null;
            var bot: usize = 0;
            for (0..h) |y| {
                if (intensity[base + y] != 0) {
                    if (top == null) bot = y;
                    top = y;
                }
            }
            const hi_y = top orelse continue;
            var runs: std.ArrayList(LightRun) = .empty;
            errdefer runs.deinit(allocator);
            var y: usize = hi_y + 1;
            while (y > bot) {
                y -= 1;
                const vi = base + y;
                if (runs.items.len > 0) {
                    const last = &runs.items[runs.items.len - 1];
                    if (last.color_id == color[vi] and last.intensity == intensity[vi] and last.count < 255) {
                        last.count += 1;
                        continue;
                    }
                }
                try runs.append(allocator, .{ .count = 1, .color_id = color[vi], .intensity = intensity[vi] });
            }
            const owned = try runs.toOwnedSlice(allocator);
            col.light = owned;
            col.light_base_y = @intCast(hi_y);
            stats.lit_columns += 1;
            stats.runs += owned.len;
        }
    }
    return stats;
}

test "flood falloff is symmetric and attenuates per step" {
    var world = try World.init(std.testing.allocator, 9, 9, 9);
    defer world.deinit();
    try world.set(4, 4, 4, 9);
    const stats = try floodAll(&world, std.testing.allocator, .{});
    try std.testing.expect(stats.lit_columns > 0);

    const col = world.columnAt(4, 4).?;
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 255 }, sampleLight(col, 4));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247 }, sampleLight(col, 5));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247 }, sampleLight(col, 3));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239 }, sampleLight(col, 6));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239 }, sampleLight(col, 2));
    try std.testing.expectEqual(@as(i32, 8), col.light_base_y);
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 223 }, sampleLight(col, 8));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 223 }, sampleLight(col, 0));
    try std.testing.expectEqual(LightSample{}, sampleLight(col, 9));

    const diag = world.columnAt(5, 4).?;
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247 }, sampleLight(diag, 4));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239 }, sampleLight(diag, 5));
    const far = world.columnAt(8, 8).?;
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 191 }, sampleLight(far, 4));
}

test "wall blocks the flood; solids store nothing" {
    var world = try World.init(std.testing.allocator, 5, 3, 3);
    defer world.deinit();
    try world.set(0, 1, 1, 10);
    try world.fillBox(2, 0, 0, 3, 3, 3, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});

    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 247 }, sampleLight(world.columnAt(1, 1).?, 1));
    // The solid wall stores no light, and nothing crosses it.
    try std.testing.expect(world.columnAt(2, 1).?.light == null);
    try std.testing.expect(world.columnAt(3, 1).?.light == null);
    try std.testing.expect(world.columnAt(4, 1).?.light == null);
}

test "brighter flood wins; ties go to the earlier seed" {
    var world = try World.init(std.testing.allocator, 5, 3, 3);
    defer world.deinit();
    try world.set(0, 1, 1, 9);
    try world.set(4, 1, 1, 10);
    _ = try floodAll(&world, std.testing.allocator, .{});

    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247 }, sampleLight(world.columnAt(1, 1).?, 1));
    // Equidistant midpoint: both arrive at 239, cyan (x=0) wins the tie.
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239 }, sampleLight(world.columnAt(2, 1).?, 1));
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 247 }, sampleLight(world.columnAt(3, 1).?, 1));
}

test "interior unlit voxels encode as zero runs inside coverage" {
    var world = try World.init(std.testing.allocator, 1, 10, 1);
    defer world.deinit();
    try world.set(0, 9, 0, 9);
    try world.set(0, 0, 0, 10);
    try world.fillBox(0, 3, 0, 1, 7, 1, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});

    const col = world.columnAt(0, 0).?;
    try std.testing.expectEqual(@as(i32, 9), col.light_base_y);
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 255 }, sampleLight(col, 9));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239 }, sampleLight(col, 7));
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 239 }, sampleLight(col, 2));
    // The solid blocker y=3..6 stores nothing, but coverage spans it.
    for (3..7) |y| {
        try std.testing.expectEqual(LightSample{}, sampleLight(col, @intCast(y)));
    }
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 255 }, sampleLight(col, 0));

    var total: usize = 0;
    for (col.light.?) |run| {
        try std.testing.expect(run.count > 0);
        total += run.count;
    }
    try std.testing.expectEqual(@as(usize, 10), total);
}

test "uniform floods split runs at 255" {
    var world = try World.init(std.testing.allocator, 1, 600, 1);
    defer world.deinit();
    try world.set(0, 300, 0, 9);
    _ = try floodAll(&world, std.testing.allocator, .{ .attenuation = 0 });

    const col = world.columnAt(0, 0).?;
    const runs = col.light.?;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expectEqual(@as(u8, 255), runs[0].count);
    try std.testing.expectEqual(@as(u8, 255), runs[1].count);
    try std.testing.expectEqual(@as(u8, 90), runs[2].count);
    for (runs) |run| {
        try std.testing.expectEqual(@as(u8, 9), run.color_id);
        try std.testing.expectEqual(@as(u8, 255), run.intensity);
    }
    try std.testing.expectEqual(@as(i32, 599), col.light_base_y);
}

test "world without emissive materials keeps null light" {
    var world = try World.init(std.testing.allocator, 4, 8, 4);
    defer world.deinit();
    try world.fillBox(0, 0, 0, 4, 2, 4, 1);
    const stats = try floodAll(&world, std.testing.allocator, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.lit_columns);
    try std.testing.expectEqual(@as(usize, 0), stats.runs);
    for (world.columns) |col| try std.testing.expect(col.light == null);
}

test "reflood frees and replaces previous light runs" {
    var world = try World.init(std.testing.allocator, 3, 8, 3);
    defer world.deinit();
    try world.set(1, 4, 1, 9);
    _ = try floodAll(&world, std.testing.allocator, .{});
    try std.testing.expect(world.columnAt(1, 1).?.light != null);
    try world.set(1, 4, 1, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});
    for (world.columns) |col| try std.testing.expect(col.light == null);
}
