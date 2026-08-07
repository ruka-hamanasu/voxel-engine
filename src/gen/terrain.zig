const std = @import("std");
const gen = @import("../gen.zig");
const world_mod = @import("../world.zig");
const camera_mod = @import("../camera.zig");
const Noise = @import("noise.zig").Noise;
const Builder = @import("builder.zig").Builder;

const World = world_mod.World;

pub const mat = struct {
    pub const bedrock: u8 = 8;
    pub const stone: u8 = 1;
    pub const dirt: u8 = 7;
    pub const grass: u8 = 4;
    pub const sand: u8 = 3;
    pub const arch: u8 = 6;
    pub const crystal_cyan: u8 = 9;
    pub const crystal_magenta: u8 = 10;
    pub const crystal_amber: u8 = 11;
};

const Span = struct { min: u16, max: u16 };

fn heightSpan(heights: []const u16, d: usize, x0: usize, z0: usize, wx: usize, wz: usize) Span {
    var lo: u16 = std.math.maxInt(u16);
    var hi: u16 = 0;
    for (x0..x0 + wx) |x| {
        for (z0..z0 + wz) |z| {
            const v = heights[x * d + z];
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
    }
    return .{ .min = lo, .max = hi };
}

fn box(world: *World, a0: usize, y0: usize, b0: usize, a1: usize, y1: usize, b1: usize, along_x: bool, m: u8) !void {
    if (along_x) {
        try world.fillBox(a0, y0, b0, a1, y1, b1, m);
    } else {
        try world.fillBox(b0, y0, a0, b1, y1, a1, m);
    }
}

fn buildArch(world: *World, a0: usize, y0: usize, b0: usize, along_x: bool) !void {
    try box(world, a0, y0 - 1, b0, a0 + 9, y0 + 10, b0 + 2, along_x, mat.arch);
    try box(world, a0 + 2, y0, b0, a0 + 7, y0 + 6, b0 + 2, along_x, 0);
    try box(world, a0 + 3, y0 + 6, b0, a0 + 6, y0 + 8, b0 + 2, along_x, 0);
    try box(world, a0 + 4, y0 + 8, b0, a0 + 5, y0 + 9, b0 + 2, along_x, 0);
}

fn farFromLandmarks(landmarks: []const gen.Landmark, x: usize, z: usize, min_dist: i32) bool {
    for (landmarks) |lm| {
        const dx: i32 = @as(i32, @intCast(x)) - lm.x;
        const dz: i32 = @as(i32, @intCast(z)) - lm.z;
        if (dx * dx + dz * dz < min_dist * min_dist) return false;
    }
    return true;
}

pub fn generate(allocator: std.mem.Allocator, opts: gen.Options) !gen.Result {
    std.debug.assert(opts.w >= 32 and opts.h >= 24 and opts.d >= 32);

    var world = try World.init(allocator, opts.w, opts.h, opts.d);
    errdefer world.deinit();

    var builder = try Builder.init(allocator, &world);
    defer builder.deinit();

    const n_terrain = Noise.init(opts.seed);
    const n_mask = n_terrain.reseed(0x51ED);
    const n_cave_a = n_terrain.reseed(0xCA0EA);
    const n_cave_b = n_terrain.reseed(0xCA0EB);

    var rng = std.Random.DefaultPrng.init(opts.seed ^ 0x9E3779B97F4A7C15);

    const heights = try allocator.alloc(u16, opts.w * opts.d);
    defer allocator.free(heights);

    const hf: f32 = @floatFromInt(opts.h);
    const base: f32 = hf * 0.30;
    const amp: f32 = hf * 0.16;
    const sand_level: f32 = base - amp * 0.45;
    const hi_cap: i32 = @intCast(opts.h - 12);

    for (0..opts.w) |x| {
        for (0..opts.d) |z| {
            const xf: f32 = @floatFromInt(x);
            const zf: f32 = @floatFromInt(z);
            const hn = n_terrain.fbm2(xf / 36.0, zf / 36.0, 4);
            const hi: i32 = std.math.clamp(@as(i32, @intFromFloat(base + hn * amp)), 6, hi_cap);
            heights[x * opts.d + z] = @intCast(hi);
            const surface: usize = @intCast(hi);

            const dense = builder.column();
            const sandy = @as(f32, @floatFromInt(hi)) < sand_level;
            for (0..surface + 1) |y| {
                dense[y] = if (y == 0)
                    mat.bedrock
                else if (y + 4 < surface)
                    mat.stone
                else if (sandy)
                    mat.sand
                else if (y == surface)
                    mat.grass
                else
                    mat.dirt;
            }

            if (n_mask.noise2(xf / 40.0, zf / 40.0) > -0.1) {
                var y: usize = 2;
                while (y + 1 < surface) : (y += 1) {
                    const yf: f32 = @floatFromInt(y);
                    const a = n_cave_a.fbm3(xf / 13.0, yf / 9.0, zf / 13.0, 2);
                    const b = n_cave_b.fbm3(xf / 13.0, yf / 9.0, zf / 13.0, 2);
                    if (a * a + b * b < 0.05) dense[y] = 0;
                }

                y = 3;
                while (y + 3 < surface) : (y += 1) {
                    if (dense[y] == 0 and dense[y - 1] != 0 and dense[y + 1] == 0 and dense[y + 2] == 0) {
                        if (rng.random().uintLessThan(u32, 48) == 0) {
                            const crystal = switch (rng.random().uintLessThan(u8, 3)) {
                                0 => mat.crystal_cyan,
                                1 => mat.crystal_magenta,
                                else => mat.crystal_amber,
                            };
                            dense[y] = crystal;
                            dense[y + 1] = crystal;
                        }
                    }
                }
            }

            try builder.emit(x, z);
        }
    }

    var landmarks: std.ArrayList(gen.Landmark) = .empty;
    errdefer landmarks.deinit(allocator);

    const arch_target: usize = @max(2, opts.w * opts.d / 8192);
    var attempts: usize = 0;
    while (landmarks.items.len < arch_target and attempts < 128) : (attempts += 1) {
        const ax = rng.random().intRangeAtMost(usize, 10, opts.w - 22);
        const az = rng.random().intRangeAtMost(usize, 10, opts.d - 22);
        const span = heightSpan(heights, opts.d, ax, az, 11, 11);
        if (span.max - span.min > 3) continue;
        if (!farFromLandmarks(landmarks.items, ax, az, 18)) continue;
        const along_x = rng.random().boolean();
        try buildArch(&world, ax, span.min, az, along_x);
        try landmarks.append(allocator, .{ .x = @intCast(ax), .y = @intCast(span.min), .z = @intCast(az) });
    }

    var spawn_x: usize = opts.w / 2;
    var spawn_z: usize = opts.d / 2;
    attempts = 0;
    while (attempts < 128) : (attempts += 1) {
        const sx = rng.random().intRangeAtMost(usize, 6, opts.w - 12);
        const sz = rng.random().intRangeAtMost(usize, 6, opts.d - 12);
        const span = heightSpan(heights, opts.d, sx, sz, 6, 6);
        if (span.max - span.min > 2) continue;
        if (!farFromLandmarks(landmarks.items, sx, sz, 10)) continue;
        spawn_x = sx;
        spawn_z = sz;
        break;
    }

    const spawn_ground: f32 = @floatFromInt(heights[spawn_x * opts.d + spawn_z]);
    var yaw: f32 = std.math.pi / 4.0;
    var best_dist: i32 = std.math.maxInt(i32);
    for (landmarks.items) |lm| {
        const dx: i32 = lm.x - @as(i32, @intCast(spawn_x));
        const dz: i32 = lm.z - @as(i32, @intCast(spawn_z));
        const dist = dx * dx + dz * dz;
        if (dist < best_dist) {
            best_dist = dist;
            yaw = std.math.atan2(@as(f32, @floatFromInt(dz)), @as(f32, @floatFromInt(dx)));
        }
    }

    return .{
        .world = world,
        .spawn = .{
            .x = @as(f32, @floatFromInt(spawn_x)) + 0.5,
            .y = spawn_ground + 2.5,
            .z = @as(f32, @floatFromInt(spawn_z)) + 0.5,
            .yaw = yaw,
        },
        .landmarks = try landmarks.toOwnedSlice(allocator),
    };
}

fn expectCoverage(world: *const World, x: i32, z: i32) !void {
    const col = world.columnAt(x, z).?;
    var total: usize = 0;
    for (col.runs) |run| {
        try std.testing.expect(run.count > 0);
        total += run.count;
    }
    try std.testing.expectEqual(world.h, total);
}

fn worldsEqual(a: *const World, b: *const World) bool {
    if (a.w != b.w or a.h != b.h or a.d != b.d) return false;
    for (a.columns, b.columns) |ca, cb| {
        if (!std.mem.eql(world_mod.MatRun, ca.runs, cb.runs)) return false;
    }
    return true;
}

const test_opts: gen.Options = .{ .seed = 7, .w = 64, .h = 32, .d = 64 };

test "generation is deterministic per seed" {
    var r1 = try generate(std.testing.allocator, test_opts);
    defer r1.deinit(std.testing.allocator);
    var r2 = try generate(std.testing.allocator, test_opts);
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(worldsEqual(&r1.world, &r2.world));
    try std.testing.expectEqual(r1.spawn, r2.spawn);

    var r3 = try generate(std.testing.allocator, .{ .seed = 8, .w = 64, .h = 32, .d = 64 });
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(!worldsEqual(&r1.world, &r3.world));
}

test "columns stay covered and terrain in bounds" {
    var r = try generate(std.testing.allocator, test_opts);
    defer r.deinit(std.testing.allocator);
    for (0..r.world.w) |x| {
        for (0..r.world.d) |z| {
            try expectCoverage(&r.world, @intCast(x), @intCast(z));
            try std.testing.expect(r.world.get(@intCast(x), 0, @intCast(z)) != 0);
        }
    }
}

test "caves and arches exist" {
    var r = try generate(std.testing.allocator, test_opts);
    defer r.deinit(std.testing.allocator);

    var underground_air: usize = 0;
    for (0..r.world.w) |x| {
        for (0..r.world.d) |z| {
            var y: i32 = 3;
            while (y < 9) : (y += 1) {
                if (r.world.get(@intCast(x), y, @intCast(z)) == 0) underground_air += 1;
            }
        }
    }
    try std.testing.expect(underground_air > 64);

    try std.testing.expect(r.landmarks.len > 0);
    for (r.landmarks) |lm| {
        try std.testing.expectEqual(mat.arch, r.world.get(lm.x, lm.y, lm.z));
        const along_x = r.world.get(lm.x + 4, lm.y + 4, lm.z) == 0;
        const along_z = r.world.get(lm.x, lm.y + 4, lm.z + 4) == 0;
        try std.testing.expect(along_x != along_z);
        const lintel = if (along_x)
            r.world.get(lm.x + 4, lm.y + 9, lm.z)
        else
            r.world.get(lm.x, lm.y + 9, lm.z + 4);
        try std.testing.expectEqual(mat.arch, lintel);
    }
}
