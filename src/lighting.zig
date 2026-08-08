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
///
/// Directional faces (milestone 9b): every cell also records the Dir
/// the brightest wave flowed in from, so the renderer can weight a
/// face's light by how its normal aligns with the local flow — a face
/// perpendicular to the flow (e.g. light bending around a 45-degree
/// corner) shows half the air cell's light instead of all of it.
pub const Params = struct {
    attenuation: u8 = 8,
    seed_intensity: u8 = 255,
};

pub const Stats = struct {
    lit_columns: usize = 0,
    runs: usize = 0,
};

/// Direction the brightest flood wave traveled when it entered a cell
/// (offset from predecessor into the cell). The opposite direction is
/// `dir ^ 1`. none = seed cells, unreached cells, and (until milestone
/// 11 gives it a real direction) the material-derived default.
pub const Dir = enum(u8) { px, nx, py, ny, pz, nz, none };

/// Light sample at one voxel; intensity 0 = no colored light (identity
/// tint in the renderer).
pub const LightSample = struct {
    color_id: u8 = 0,
    intensity: u8 = 0,
    dir: Dir = .none,
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
        if (y <= hi and y >= lo) return .{ .color_id = run.color_id, .intensity = run.intensity, .dir = @enumFromInt(run.dir) };
        hi = lo - 1;
    }
    return .{};
}

const neighbor_offsets = .{ .{ 1, 0, 0, Dir.px }, .{ -1, 0, 0, Dir.nx }, .{ 0, 1, 0, Dir.py }, .{ 0, -1, 0, Dir.ny }, .{ 0, 0, 1, Dir.pz }, .{ 0, 0, -1, Dir.nz } };

/// Dense per-voxel scratch over a bounded XZ box at full world height;
/// the flood's working memory. floodAll covers the whole world, relight
/// only the dirty region expanded by the maximum light reach. Cells the
/// runs never lit decode as intensity 0 (the material-derived default).
const Scratch = struct {
    x0: usize,
    z0: usize,
    xd: usize,
    zd: usize,
    h: usize,
    intensity: []u8,
    color: []u8,
    dirs: []u8,

    fn init(allocator: std.mem.Allocator, x0: usize, z0: usize, x1: usize, z1: usize, h: usize) !Scratch {
        const n = (x1 - x0) * (z1 - z0) * h;
        const intensity = try allocator.alloc(u8, n);
        errdefer allocator.free(intensity);
        @memset(intensity, 0);
        const color = try allocator.alloc(u8, n);
        errdefer allocator.free(color);
        @memset(color, 0);
        const dirs = try allocator.alloc(u8, n);
        errdefer allocator.free(dirs);
        @memset(dirs, @intFromEnum(Dir.none));
        return .{ .x0 = x0, .z0 = z0, .xd = x1 - x0, .zd = z1 - z0, .h = h, .intensity = intensity, .color = color, .dirs = dirs };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        allocator.free(self.intensity);
        allocator.free(self.color);
        allocator.free(self.dirs);
    }

    fn index(self: *const Scratch, x: usize, y: usize, z: usize) usize {
        return ((x - self.x0) * self.zd + (z - self.z0)) * self.h + y;
    }

    fn coords(self: *const Scratch, vi: usize) struct { usize, usize, usize } {
        const y = vi % self.h;
        const cxz = vi / self.h;
        return .{ cxz / self.zd + self.x0, y, cxz % self.zd + self.z0 };
    }
};

/// Load the footprint columns' light runs into the scratch (relight
/// only; floodAll starts from a zeroed scratch).
fn decodeColumns(world: *World, s: *Scratch) void {
    for (s.x0..s.x0 + s.xd) |x| {
        for (s.z0..s.z0 + s.zd) |z| {
            const col = &world.columns[x * world.d + z];
            const runs = col.light orelse continue;
            var hi: i32 = col.light_base_y;
            for (runs) |run| {
                var y = hi;
                const lo = hi - @as(i32, run.count) + 1;
                while (y >= lo) : (y -= 1) {
                    const vi = s.index(x, @intCast(y), z);
                    s.intensity[vi] = run.intensity;
                    s.color[vi] = run.color_id;
                    s.dirs[vi] = run.dir;
                }
                hi = lo - 1;
            }
        }
    }
}

/// Seed every emissive voxel in the box, run-scanning the columns.
/// Seeds write only on strict improvement, so re-seeding an unchanged
/// crystal during relight is a no-op that doesn't even enqueue.
fn seedEmissiveBox(world: *World, s: *Scratch, queue: *std.ArrayList(u32), allocator: std.mem.Allocator, params: Params, bx0: usize, by0: usize, bz0: usize, bx1: usize, by1: usize, bz1: usize) !void {
    for (bx0..bx1) |x| {
        for (bz0..bz1) |z| {
            const col = &world.columns[x * world.d + z];
            var y: i32 = @intCast(world.h - 1);
            for (col.runs) |run| {
                const m = run.palette_id;
                if (m != 0 and world_mod.palette[m].emissive != 0) {
                    var yy = y;
                    const lo = y - @as(i32, run.count) + 1;
                    while (yy >= lo) : (yy -= 1) {
                        if (yy < by0 or yy >= by1) continue;
                        const vi = s.index(x, @intCast(yy), z);
                        if (params.seed_intensity > s.intensity[vi]) {
                            s.intensity[vi] = params.seed_intensity;
                            s.color[vi] = m;
                            s.dirs[vi] = @intFromEnum(Dir.none);
                            try queue.append(allocator, @intCast(vi));
                        }
                    }
                }
                y -= run.count;
            }
        }
    }
}

/// Uniform-cost BFS confined to the scratch box: a FIFO visits cells in
/// non-increasing level order, so the first write to a cell is the
/// brightest and strict `>` makes ties resolve to the earliest seed
/// (deterministic). Solid neighbors are terminal and record nothing.
fn propagate(world: *const World, s: *Scratch, queue: *std.ArrayList(u32), allocator: std.mem.Allocator, params: Params) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const vi = queue.items[head];
        const level = s.intensity[vi];
        const cid = s.color[vi];
        const x, const y, const z = s.coords(vi);
        inline for (neighbor_offsets) |off| {
            const nx = @as(i64, @intCast(x)) + off[0];
            const ny = @as(i64, @intCast(y)) + off[1];
            const nz = @as(i64, @intCast(z)) + off[2];
            if (nx >= s.x0 and ny >= 0 and nz >= s.z0 and nx < s.x0 + s.xd and ny < s.h and nz < s.z0 + s.zd) {
                const ux: usize = @intCast(nx);
                const uy: usize = @intCast(ny);
                const uz: usize = @intCast(nz);
                const nvi = s.index(ux, uy, uz);
                const nm = world.get(@intCast(nx), @intCast(ny), @intCast(nz));
                if (nm == 0) {
                    const cand = level -| params.attenuation;
                    if (cand > 0 and cand > s.intensity[nvi]) {
                        s.intensity[nvi] = cand;
                        s.color[nvi] = cid;
                        s.dirs[nvi] = @intFromEnum(off[3]);
                        try queue.append(allocator, @intCast(nvi));
                    }
                }
            }
        }
    }
}

/// Encode the footprint columns' scratch back into light runs: coverage
/// spans [lowest lit y, highest lit y] (interior unlit voxels become
/// explicit intensity-0 runs); columns with no light keep light = null.
/// Runs split when the arrival direction changes, not just the value.
/// Replaces and frees any previous runs.
fn encodeColumns(world: *World, s: *const Scratch, allocator: std.mem.Allocator) !Stats {
    var stats: Stats = .{};
    for (s.x0..s.x0 + s.xd) |x| {
        for (s.z0..s.z0 + s.zd) |z| {
            const col = &world.columns[x * world.d + z];
            if (col.light) |l| allocator.free(l);
            col.light = null;
            col.light_base_y = 0;
            var top: ?usize = null;
            var bot: usize = 0;
            for (0..s.h) |y| {
                if (s.intensity[s.index(x, y, z)] != 0) {
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
                const vi = s.index(x, y, z);
                if (runs.items.len > 0) {
                    const last = &runs.items[runs.items.len - 1];
                    if (last.color_id == s.color[vi] and last.intensity == s.intensity[vi] and last.dir == s.dirs[vi] and last.count < 255) {
                        last.count += 1;
                        continue;
                    }
                }
                try runs.append(allocator, .{ .count = 1, .color_id = s.color[vi], .intensity = s.intensity[vi], .dir = s.dirs[vi] });
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

pub fn floodAll(world: *World, allocator: std.mem.Allocator, params: Params) !Stats {
    var s = try Scratch.init(allocator, 0, 0, world.w, world.d, world.h);
    defer s.deinit(allocator);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try seedEmissiveBox(world, &s, &queue, allocator, params, 0, 0, 0, world.w, world.h, world.d);
    try propagate(world, &s, &queue, allocator, params);
    return encodeColumns(world, &s, allocator);
}

/// Incremental relight after an edit (milestone 10), consuming the
/// dirty extents World.set/fillBox accumulate. Clear-then-reflood over
/// the dirty region expanded by the maximum light reach
/// (seed_intensity / attenuation): no cell beyond that can change —
/// propagation and clear chains both lose attenuation per step from a
/// stored value <= seed_intensity.
///
/// Clear pass: a dirty cell's stored light is STALE when the edit
/// blocked or removed what produced it — the cell became a plain solid
/// over a lit cell (blocks the old chain), or it was a seed
/// (dir == none) that is gone or changed palette id. Stale cells clear
/// their dependent chain: the FIFO zeroes same-color neighbors whose
/// intensity is exactly the current level minus attenuation (the flood's
/// own propagation invariant), recording lit non-matching neighbors as
/// reflood candidates.
///
/// Add pass: re-seed emissive cells in the dirty region, re-enqueue
/// surviving candidates (a later clear may have zeroed one — re-read
/// live), and enqueue every lit cell adjacent to the dirty region so
/// carved air floods from its neighbors. One propagate finishes both.
///
/// Values (intensity, and color up to exact two-seed ties) match a full
/// reflood; arrival DIRECTIONS can differ from floodAll where a cell
/// has two equal-level predecessors, since the add queue's visit order
/// differs. Both are valid fixpoints.
pub fn relight(world: *World, allocator: std.mem.Allocator, dirty: world_mod.Region, params: Params) !Stats {
    const reach: usize = if (params.attenuation == 0)
        @max(world.w, @max(world.h, world.d))
    else
        params.seed_intensity / params.attenuation;
    const x0 = dirty.x0 -| reach;
    const z0 = dirty.z0 -| reach;
    const x1 = @min(dirty.x1 + reach, world.w);
    const z1 = @min(dirty.z1 + reach, world.d);

    var s = try Scratch.init(allocator, x0, z0, x1, z1, world.h);
    defer s.deinit(allocator);
    decodeColumns(world, &s);

    var reseeds: std.ArrayList(u32) = .empty;
    defer reseeds.deinit(allocator);
    var clear_q: std.ArrayList(u64) = .empty;
    defer clear_q.deinit(allocator);

    const none: u8 = @intFromEnum(Dir.none);
    for (dirty.x0..dirty.x1) |x| {
        for (dirty.z0..dirty.z1) |z| {
            for (dirty.y0..dirty.y1) |y| {
                const vi = s.index(x, y, z);
                if (s.intensity[vi] == 0) continue;
                const m = world.get(@intCast(x), @intCast(y), @intCast(z));
                const is_seed = m != 0 and world_mod.palette[m].emissive != 0;
                const was_seed = s.dirs[vi] == none;
                const stale = if (is_seed)
                    !(was_seed and s.color[vi] == m and s.intensity[vi] == params.seed_intensity)
                else if (m != 0)
                    true
                else
                    was_seed;
                if (stale) try clearChain(&s, vi, params, &reseeds, &clear_q, allocator);
            }
        }
    }

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try seedEmissiveBox(world, &s, &queue, allocator, params, dirty.x0, dirty.y0, dirty.z0, dirty.x1, dirty.y1, dirty.z1);
    for (reseeds.items) |vi| {
        if (s.intensity[vi] != 0) try queue.append(allocator, vi);
    }
    for (dirty.x0..dirty.x1) |x| {
        for (dirty.z0..dirty.z1) |z| {
            for (dirty.y0..dirty.y1) |y| {
                inline for (neighbor_offsets) |off| {
                    const nx = @as(i64, @intCast(x)) + off[0];
                    const ny = @as(i64, @intCast(y)) + off[1];
                    const nz = @as(i64, @intCast(z)) + off[2];
                    if (nx >= s.x0 and ny >= 0 and nz >= s.z0 and nx < s.x0 + s.xd and ny < s.h and nz < s.z0 + s.zd) {
                        const nvi = s.index(@intCast(nx), @intCast(ny), @intCast(nz));
                        if (s.intensity[nvi] != 0) try queue.append(allocator, @intCast(nvi));
                    }
                }
            }
        }
    }
    try propagate(world, &s, &queue, allocator, params);
    return encodeColumns(world, &s, allocator);
}

/// Clear one stale cell's dependent light chain. The queue packs
/// (level << 32 | vi) because cells are zeroed on enqueue but their old
/// level is still needed when popped to compute the next chain value.
/// Non-matching lit neighbors are recorded as reflood candidates.
fn clearChain(s: *Scratch, start: usize, params: Params, reseeds: *std.ArrayList(u32), q: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
    const color0 = s.color[start];
    const level0 = s.intensity[start];
    s.intensity[start] = 0;
    s.color[start] = 0;
    s.dirs[start] = @intFromEnum(Dir.none);
    q.clearRetainingCapacity();
    try q.append(allocator, (@as(u64, level0) << 32) | @as(u64, start));
    var head: usize = 0;
    while (head < q.items.len) : (head += 1) {
        const entry = q.items[head];
        const vi: usize = @intCast(entry & 0xffffffff);
        const level: u8 = @intCast(entry >> 32);
        const cand = level -| params.attenuation;
        if (cand == 0) continue;
        const x, const y, const z = s.coords(vi);
        inline for (neighbor_offsets) |off| {
            const nx = @as(i64, @intCast(x)) + off[0];
            const ny = @as(i64, @intCast(y)) + off[1];
            const nz = @as(i64, @intCast(z)) + off[2];
            if (nx >= s.x0 and ny >= 0 and nz >= s.z0 and nx < s.x0 + s.xd and ny < s.h and nz < s.z0 + s.zd) {
                const nvi = s.index(@intCast(nx), @intCast(ny), @intCast(nz));
                if (s.intensity[nvi] != 0) {
                    if (s.color[nvi] == color0 and s.intensity[nvi] == cand) {
                        s.intensity[nvi] = 0;
                        s.color[nvi] = 0;
                        s.dirs[nvi] = @intFromEnum(Dir.none);
                        try q.append(allocator, (@as(u64, cand) << 32) | @as(u64, nvi));
                    } else {
                        try reseeds.append(allocator, @intCast(nvi));
                    }
                }
            }
        }
    }
}

test "flood falloff is symmetric and attenuates per step" {
    var world = try World.init(std.testing.allocator, 9, 9, 9);
    defer world.deinit();
    try world.set(4, 4, 4, 9);
    const stats = try floodAll(&world, std.testing.allocator, .{});
    try std.testing.expect(stats.lit_columns > 0);

    const col = world.columnAt(4, 4).?;
    // The seed itself has no arrival direction; its neighbors record
    // the direction the wave flowed in from.
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 255 }, sampleLight(col, 4));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247, .dir = .py }, sampleLight(col, 5));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247, .dir = .ny }, sampleLight(col, 3));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239, .dir = .py }, sampleLight(col, 6));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239, .dir = .ny }, sampleLight(col, 2));
    try std.testing.expectEqual(@as(i32, 8), col.light_base_y);
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 223, .dir = .py }, sampleLight(col, 8));
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 223, .dir = .ny }, sampleLight(col, 0));
    try std.testing.expectEqual(LightSample{}, sampleLight(col, 9));

    const diag = world.columnAt(5, 4).?;
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247, .dir = .px }, sampleLight(diag, 4));
    // Tie between the +x and +y paths: the +x neighbor is visited
    // first (offset order), so the flow reads as arriving from below.
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239, .dir = .py }, sampleLight(diag, 5));
    const far = world.columnAt(8, 8).?;
    const far_sample = sampleLight(far, 4);
    try std.testing.expectEqual(@as(u8, 9), far_sample.color_id);
    try std.testing.expectEqual(@as(u8, 191), far_sample.intensity);
    try std.testing.expect(far_sample.dir == .px or far_sample.dir == .pz);
}

test "wall blocks the flood; solids store nothing" {
    var world = try World.init(std.testing.allocator, 5, 3, 3);
    defer world.deinit();
    try world.set(0, 1, 1, 10);
    try world.fillBox(2, 0, 0, 3, 3, 3, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});

    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 247, .dir = .px }, sampleLight(world.columnAt(1, 1).?, 1));
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

    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 247, .dir = .px }, sampleLight(world.columnAt(1, 1).?, 1));
    // Equidistant midpoint: both arrive at 239, cyan (x=0) wins the tie.
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239, .dir = .px }, sampleLight(world.columnAt(2, 1).?, 1));
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 247, .dir = .nx }, sampleLight(world.columnAt(3, 1).?, 1));
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
    try std.testing.expectEqual(LightSample{ .color_id = 9, .intensity = 239, .dir = .ny }, sampleLight(col, 7));
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 239, .dir = .py }, sampleLight(col, 2));
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
    // Above the seed the flow is +y (299 cells: 255 + 44), the seed is
    // dir-less, below it -y (300 cells: 255 + 45): runs split at both
    // the 255 cap and the direction changes.
    try std.testing.expectEqual(@as(usize, 5), runs.len);
    try std.testing.expectEqual(@as(u8, 255), runs[0].count);
    try std.testing.expectEqual(@as(u8, 44), runs[1].count);
    try std.testing.expectEqual(@as(u8, 1), runs[2].count);
    try std.testing.expectEqual(@as(u8, 255), runs[3].count);
    try std.testing.expectEqual(@as(u8, 45), runs[4].count);
    for (runs) |run| {
        try std.testing.expectEqual(@as(u8, 9), run.color_id);
        try std.testing.expectEqual(@as(u8, 255), run.intensity);
    }
    try std.testing.expectEqual(@as(u8, @intFromEnum(Dir.py)), runs[0].dir);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Dir.none)), runs[2].dir);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Dir.ny)), runs[4].dir);
    try std.testing.expectEqual(@as(i32, 599), col.light_base_y);
}

test "arrival direction splits runs at direction changes" {
    var world = try World.init(std.testing.allocator, 1, 10, 1);
    defer world.deinit();
    try world.set(0, 5, 0, 9);
    _ = try floodAll(&world, std.testing.allocator, .{ .attenuation = 0 });

    const runs = world.columnAt(0, 0).?.light.?;
    try std.testing.expectEqual(@as(usize, 3), runs.len);
    try std.testing.expectEqual(LightRun{ .count = 4, .color_id = 9, .intensity = 255, .dir = @intFromEnum(Dir.py) }, runs[0]);
    try std.testing.expectEqual(LightRun{ .count = 1, .color_id = 9, .intensity = 255, .dir = @intFromEnum(Dir.none) }, runs[1]);
    try std.testing.expectEqual(LightRun{ .count = 5, .color_id = 9, .intensity = 255, .dir = @intFromEnum(Dir.ny) }, runs[2]);
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

/// Relight verification: intensity and color match a full reflood
/// per-cell (arrival dirs can legitimately differ at equal-level ties;
/// expectDirsValid checks those separately). Test geometry avoids exact
/// two-seed equal-distance ties, which both algorithms resolve by seed
/// order but possibly different orders.
fn expectEquivalent(a: *const World, b: *const World) !void {
    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqual(a.h, b.h);
    try std.testing.expectEqual(a.d, b.d);
    for (0..a.w) |x| {
        for (0..a.d) |z| {
            const ca = a.columnAt(@intCast(x), @intCast(z)).?;
            const cb = b.columnAt(@intCast(x), @intCast(z)).?;
            for (0..a.h) |y| {
                const sa = sampleLight(ca, @intCast(y));
                const sb = sampleLight(cb, @intCast(y));
                try std.testing.expectEqual(sb.intensity, sa.intensity);
                try std.testing.expectEqual(sb.color_id, sa.color_id);
            }
        }
    }
}

/// Every lit air cell's arrival dir points at a predecessor whose level
/// is exactly one attenuation step brighter with the same color (or the
/// cell is a dir-less seed). Holds for any valid fixpoint, floodAll or
/// relight, independent of tie-break order.
fn expectDirsValid(world: *const World, params: Params) !void {
    for (0..world.w) |x| {
        for (0..world.d) |z| {
            const col = world.columnAt(@intCast(x), @intCast(z)).?;
            for (0..world.h) |y| {
                const s = sampleLight(col, @intCast(y));
                if (s.intensity == 0 or s.dir == .none) continue;
                const dx: i32, const dy: i32, const dz: i32 = switch (s.dir) {
                    .px => .{ -1, 0, 0 },
                    .nx => .{ 1, 0, 0 },
                    .py => .{ 0, -1, 0 },
                    .ny => .{ 0, 1, 0 },
                    .pz => .{ 0, 0, -1 },
                    .nz => .{ 0, 0, 1 },
                    .none => unreachable,
                };
                const pred = sampleLight(world.columnAt(@intCast(@as(i32, @intCast(x)) + dx), @intCast(@as(i32, @intCast(z)) + dz)) orelse continue, @as(i32, @intCast(y)) + dy);
                try std.testing.expectEqual(s.color_id, pred.color_id);
                try std.testing.expectEqual(@as(u8, s.intensity +| params.attenuation), pred.intensity);
            }
        }
    }
}

/// Build two identical worlds, apply the same edit to each, relight one
/// and fully reflood the other, then compare.
fn expectRelightMatchesReflood(w: usize, h: usize, d: usize, setup: *const fn (*World) anyerror!void, edit: *const fn (*World) anyerror!void) !void {
    var a = try World.init(std.testing.allocator, w, h, d);
    defer a.deinit();
    var b = try World.init(std.testing.allocator, w, h, d);
    defer b.deinit();
    try setup(&a);
    try setup(&b);
    _ = try floodAll(&a, std.testing.allocator, .{});
    _ = try floodAll(&b, std.testing.allocator, .{});
    _ = a.takeDirty();
    _ = b.takeDirty();
    try edit(&a);
    try edit(&b);
    _ = try relight(&a, std.testing.allocator, a.takeDirty().?, .{});
    _ = try floodAll(&b, std.testing.allocator, .{});
    try expectEquivalent(&a, &b);
    try expectDirsValid(&a, .{});
}

fn setupCrystalCenter(w: *World) !void {
    try w.set(4, 4, 4, 9);
}

fn setupTwoCrystals(w: *World) !void {
    try w.set(1, 4, 4, 9);
    try w.set(7, 4, 4, 10);
}

fn setupCrystalWalled(w: *World) !void {
    try w.set(2, 4, 4, 9);
    try w.fillBox(4, 0, 0, 5, 9, 9, 1);
}

test "relight: add an emissive source" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.set(7, 4, 4, 10);
        }
    }.f);
}

test "relight: remove an emissive source" {
    try expectRelightMatchesReflood(9, 9, 9, setupTwoCrystals, struct {
        fn f(w: *World) !void {
            try w.set(1, 4, 4, 0);
        }
    }.f);
}

test "relight: replace a source with a plain solid" {
    try expectRelightMatchesReflood(9, 9, 9, setupTwoCrystals, struct {
        fn f(w: *World) !void {
            try w.set(7, 4, 4, 1);
        }
    }.f);
}

test "relight: swap a source's color" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.set(4, 4, 4, 11);
        }
    }.f);
}

test "relight: add a blocker wall" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.fillBox(6, 0, 0, 7, 9, 9, 1);
        }
    }.f);
}

test "relight: carve a hole through a blocker wall" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalWalled, struct {
        fn f(w: *World) !void {
            try w.set(4, 4, 4, 0);
        }
    }.f);
}

test "relight: place a crystal into lit air" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.set(6, 4, 4, 10);
        }
    }.f);
}

test "relight: place a plain block into lit air" {
    try expectRelightMatchesReflood(9, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.set(6, 4, 4, 1);
        }
    }.f);
}

test "relight: multiple edits in one dirty region" {
    try expectRelightMatchesReflood(12, 9, 9, setupCrystalCenter, struct {
        fn f(w: *World) !void {
            try w.set(7, 4, 4, 10);
            try w.set(8, 4, 4, 1);
            try w.set(4, 4, 4, 0);
        }
    }.f);
}

test "relight: edit at the world boundary clamps the scratch box" {
    var a = try World.init(std.testing.allocator, 9, 9, 9);
    defer a.deinit();
    var b = try World.init(std.testing.allocator, 9, 9, 9);
    defer b.deinit();
    for ([_]*World{ &a, &b }) |w| {
        try w.set(0, 0, 0, 9);
        _ = try floodAll(w, std.testing.allocator, .{});
        _ = w.takeDirty();
        try w.set(0, 0, 0, 0);
    }
    _ = try relight(&a, std.testing.allocator, a.takeDirty().?, .{});
    _ = try floodAll(&b, std.testing.allocator, .{});
    try expectEquivalent(&a, &b);
}

test "relight with no material change is the identity" {
    var world = try World.init(std.testing.allocator, 9, 9, 9);
    defer world.deinit();
    try world.set(4, 4, 4, 9);
    try world.set(2, 2, 2, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});
    _ = world.takeDirty();
    try world.set(2, 2, 2, 1); // same material: run merge, no real change
    const before: LightSample = sampleLight(world.columnAt(3, 3).?, 3);
    _ = try relight(&world, std.testing.allocator, world.takeDirty().?, .{});
    try std.testing.expectEqual(before, sampleLight(world.columnAt(3, 3).?, 3));
    var b = try World.init(std.testing.allocator, 9, 9, 9);
    defer b.deinit();
    try b.set(4, 4, 4, 9);
    try b.set(2, 2, 2, 1);
    _ = try floodAll(&b, std.testing.allocator, .{});
    try expectEquivalent(&world, &b);
}

test "relight: two sources, removing one preserves the other's field" {
    var world = try World.init(std.testing.allocator, 16, 9, 9);
    defer world.deinit();
    try world.set(2, 4, 4, 9);
    try world.set(13, 4, 4, 10);
    _ = try floodAll(&world, std.testing.allocator, .{});
    _ = world.takeDirty();
    try world.set(2, 4, 4, 0);
    _ = try relight(&world, std.testing.allocator, world.takeDirty().?, .{});
    // Far side of the amber crystal is untouched by the clear.
    try std.testing.expectEqual(LightSample{ .color_id = 10, .intensity = 247, .dir = .px }, sampleLight(world.columnAt(14, 4).?, 4));
    // Nothing cyan remains anywhere.
    for (0..16) |x| {
        for (0..9) |z| {
            const col = world.columnAt(@intCast(x), @intCast(z)).?;
            for (0..9) |y| {
                const s = sampleLight(col, @intCast(y));
                if (s.intensity != 0) try std.testing.expectEqual(@as(u8, 10), s.color_id);
            }
        }
    }
    var b = try World.init(std.testing.allocator, 16, 9, 9);
    defer b.deinit();
    try b.set(2, 4, 4, 9);
    try b.set(13, 4, 4, 10);
    _ = try floodAll(&b, std.testing.allocator, .{});
    try b.set(2, 4, 4, 0);
    _ = try floodAll(&b, std.testing.allocator, .{});
    try expectEquivalent(&world, &b);
}
