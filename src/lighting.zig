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

/// Sparse per-voxel scratch over a bounded XZ box at full world height;
/// the flood's working memory. floodAll covers the whole world, relight
/// only the dirty region expanded by the maximum light reach. Only lit
/// cells occupy memory (map value = intensity | color << 8 | dir << 16),
/// so floodAll over a large world costs memory proportional to the lit
/// volume, not the world volume. Cells absent from the map decode as
/// intensity 0 (the material-derived default).
///
/// Keys are BOX-LOCAL: ((x-x0)*zd + (z-z0))*h + y, so the u32 key cap
/// bounds one flood box (a chunk plus its reach ring once streaming
/// lands, plans/STREAMING.md), not the world volume. Origins are i32 so
/// chunk boxes at negative coords work in the unbounded world.
///
/// The map uses a multiplicative-mix hash (the ChunkMap trick): box-
/// local keys are near-sequential, and Wyhash on them cost ~45% of a
/// chunk load's flood. Hash choice doesn't affect flood OUTPUT — the
/// BFS visit order and first-write-wins tie rule are independent of
/// the map's internal layout.
const CellMap = std.HashMap(u32, u32, struct {
    pub fn hash(_: @This(), k: u32) u64 {
        return @as(u64, k) *% 0x9E3779B97F4A7C15;
    }
    pub fn eql(_: @This(), a: u32, b: u32) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

const Scratch = struct {
    x0: i32,
    z0: i32,
    xd: usize,
    zd: usize,
    h: usize, // world height (key modulus)
    map: CellMap,

    fn init(allocator: std.mem.Allocator, x0: i32, z0: i32, x1: i32, z1: i32, world: *const World) Scratch {
        std.debug.assert(x1 > x0 and z1 > z0);
        std.debug.assert(@as(u64, @intCast(x1 - x0)) * @as(u64, @intCast(z1 - z0)) * world.h < std.math.maxInt(u32));
        return .{
            .x0 = x0,
            .z0 = z0,
            .xd = @intCast(x1 - x0),
            .zd = @intCast(z1 - z0),
            .h = world.h,
            .map = CellMap.init(allocator),
        };
    }

    fn deinit(self: *Scratch) void {
        self.map.deinit();
    }

    fn pack(level: u8, color: u8, dir: u8) u32 {
        return @as(u32, level) | @as(u32, color) << 8 | @as(u32, dir) << 16;
    }

    fn index(self: *const Scratch, x: i32, y: i32, z: i32) u32 {
        const lx: u32 = @intCast(x - self.x0);
        const lz: u32 = @intCast(z - self.z0);
        return (lx * @as(u32, @intCast(self.zd)) + lz) * @as(u32, @intCast(self.h)) + @as(u32, @intCast(y));
    }

    fn contains(self: *const Scratch, nx: i64, ny: i64, nz: i64) bool {
        return nx >= self.x0 and ny >= 0 and nz >= self.z0 and
            nx < self.x0 + @as(i64, @intCast(self.xd)) and ny < self.h and nz < self.z0 + @as(i64, @intCast(self.zd));
    }

    fn coords(self: *const Scratch, vi: u32) struct { i32, i32, i32 } {
        const h: u32 = @intCast(self.h);
        const zd: u32 = @intCast(self.zd);
        const y = vi % h;
        const cxz = vi / h;
        return .{ @as(i32, @intCast(cxz / zd)) + self.x0, @intCast(y), @as(i32, @intCast(cxz % zd)) + self.z0 };
    }

    fn get(self: *const Scratch, vi: u32) LightSample {
        const v = self.map.get(vi) orelse return .{};
        return .{
            .intensity = @truncate(v),
            .color_id = @truncate(v >> 8),
            .dir = @enumFromInt(@as(u8, @truncate(v >> 16))),
        };
    }

    fn intensity(self: *const Scratch, vi: u32) u8 {
        return @truncate(self.map.get(vi) orelse 0);
    }

    fn set(self: *Scratch, vi: u32, level: u8, color: u8, dir: u8) !void {
        try self.map.put(vi, pack(level, color, dir));
    }

    fn clear(self: *Scratch, vi: u32) void {
        _ = self.map.remove(vi);
    }
};

/// Load the footprint columns' light runs into the scratch (relight
/// only; floodAll starts from an empty scratch). Zero-intensity
/// interior runs are not inserted; the map's absence decodes as 0.
/// Unloaded columns (chunk map, plans/STREAMING.md) are skipped — their
/// absence also decodes as 0.
fn decodeColumns(world: *World, s: *Scratch) !void {
    var x = s.x0;
    while (x < s.x0 + @as(i32, @intCast(s.xd))) : (x += 1) {
        var z = s.z0;
        while (z < s.z0 + @as(i32, @intCast(s.zd))) : (z += 1) {
            const col = world.columnAtMut(x, z) orelse continue;
            const runs = col.light orelse continue;
            var hi: i32 = col.light_base_y;
            for (runs) |run| {
                var y = hi;
                const lo = hi - @as(i32, run.count) + 1;
                while (y >= lo) : (y -= 1) {
                    if (run.intensity == 0) continue;
                    try s.set(s.index(x, y, z), run.intensity, run.color_id, run.dir);
                }
                hi = lo - 1;
            }
        }
    }
}

/// Seed every emissive voxel in the box, run-scanning the columns.
/// Seeds write only on strict improvement, so re-seeding an unchanged
/// crystal during relight is a no-op that doesn't even enqueue.
fn seedEmissiveBox(world: *World, s: *Scratch, queue: *std.ArrayList(u32), allocator: std.mem.Allocator, params: Params, bx0: i32, by0: i32, bz0: i32, bx1: i32, by1: i32, bz1: i32) !void {
    var x = bx0;
    while (x < bx1) : (x += 1) {
        var z = bz0;
        while (z < bz1) : (z += 1) {
            const col = world.columnAtMut(x, z) orelse continue;
            var y: i32 = @intCast(world.h - 1);
            for (col.runs) |run| {
                const m = run.palette_id;
                if (m != 0 and world_mod.palette[m].emissive != 0) {
                    var yy = y;
                    const lo = y - @as(i32, run.count) + 1;
                    while (yy >= lo) : (yy -= 1) {
                        if (yy < by0 or yy >= by1) continue;
                        const vi = s.index(x, yy, z);
                        if (params.seed_intensity > s.intensity(vi)) {
                            try s.set(vi, params.seed_intensity, m, @intFromEnum(Dir.none));
                            try queue.append(allocator, vi);
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
/// Non-resident columns (chunk map, plans/STREAMING.md) are terminal too:
/// confining propagation to resident cells means no stored chain can
/// route through an unloaded chunk, so chunk loads never invalidate
/// existing light (chunk.loadChunk floods as a pure add pass), and
/// unloaded chunks' relights converge the resident set to the same
/// fixpoint a full flood over it would compute.
fn propagate(world: *const World, s: *Scratch, queue: *std.ArrayList(u32), allocator: std.mem.Allocator, params: Params) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const vi = queue.items[head];
        const cur = s.get(vi);
        const x, const y, const z = s.coords(vi);
        inline for (neighbor_offsets) |off| {
            const nx = @as(i64, x) + off[0];
            const ny = @as(i64, y) + off[1];
            const nz = @as(i64, z) + off[2];
            if (s.contains(nx, ny, nz)) {
                const nvi = s.index(@intCast(nx), @intCast(ny), @intCast(nz));
                const nm = world.getResident(@intCast(nx), @intCast(ny), @intCast(nz));
                if (nm != null and nm.? == 0) {
                    const cand = cur.intensity -| params.attenuation;
                    if (cand > 0 and cand > s.intensity(nvi)) {
                        try s.set(nvi, cand, cur.color_id, @intFromEnum(off[3]));
                        try queue.append(allocator, nvi);
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
    var x = s.x0;
    while (x < s.x0 + @as(i32, @intCast(s.xd))) : (x += 1) {
        var z = s.z0;
        while (z < s.z0 + @as(i32, @intCast(s.zd))) : (z += 1) {
            const col = world.columnAtMut(x, z) orelse continue;
            if (col.light) |l| allocator.free(l);
            col.light = null;
            col.light_base_y = 0;
            col.light_lo = 0;
        }
    }
    // Column y-extents of lit cells: value = lo | hi << 16.
    var extents = CellMap.init(allocator);
    defer extents.deinit();
    var it = s.map.iterator();
    while (it.next()) |e| {
        const y, const ci = blk: {
            const h: u32 = @intCast(s.h);
            break :blk .{ e.key_ptr.* % h, e.key_ptr.* / h };
        };
        const gop = try extents.getOrPut(ci);
        if (!gop.found_existing) {
            gop.value_ptr.* = y | (y << 16);
        } else {
            const v = gop.value_ptr.*;
            gop.value_ptr.* = @min(v & 0xffff, y) | (@max(v >> 16, y) << 16);
        }
    }
    const h32: u32 = @intCast(s.h);
    x = s.x0;
    while (x < s.x0 + @as(i32, @intCast(s.xd))) : (x += 1) {
        var z = s.z0;
        while (z < s.z0 + @as(i32, @intCast(s.zd))) : (z += 1) {
            const ci: u32 = @as(u32, @intCast(x - s.x0)) * @as(u32, @intCast(s.zd)) + @as(u32, @intCast(z - s.z0));
            const ext = extents.get(ci) orelse continue;
            const col = world.columnAtMut(x, z) orelse continue;
            const bot: u32 = ext & 0xffff;
            const hi_y: u32 = ext >> 16;
            var runs: std.ArrayList(LightRun) = .empty;
            errdefer runs.deinit(allocator);
            var y: u32 = hi_y + 1;
            while (y > bot) {
                y -= 1;
                const smp = s.get(ci * h32 + y);
                if (runs.items.len > 0) {
                    const last = &runs.items[runs.items.len - 1];
                    if (last.color_id == smp.color_id and last.intensity == smp.intensity and last.dir == @intFromEnum(smp.dir) and last.count < 255) {
                        last.count += 1;
                        continue;
                    }
                }
                try runs.append(allocator, .{ .count = 1, .color_id = smp.color_id, .intensity = smp.intensity, .dir = @intFromEnum(smp.dir) });
            }
            const owned = try runs.toOwnedSlice(allocator);
            col.light = owned;
            col.light_base_y = @intCast(hi_y);
            col.light_lo = @intCast(bot);
            stats.lit_columns += 1;
            stats.runs += owned.len;
        }
    }
    return stats;
}

/// Full-world flood; bounded worlds only (the chunk streaming path
/// floods per chunk on load, plans/STREAMING.md phase 2).
pub fn floodAll(world: *World, allocator: std.mem.Allocator, params: Params) !Stats {
    const w: i32 = @intCast(world.w orelse unreachable);
    const d: i32 = @intCast(world.d orelse unreachable);
    var s = Scratch.init(allocator, 0, 0, w, d, world);
    defer s.deinit();
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try seedEmissiveBox(world, &s, &queue, allocator, params, 0, 0, 0, w, @intCast(world.h), d);
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
    const reach: i32 = if (params.attenuation == 0)
        // Unattenuated floods are a bounded-world test mode only.
        @intCast(@max(world.w orelse unreachable, @max(world.h, world.d orelse unreachable)))
    else
        params.seed_intensity / params.attenuation;
    const x0 = if (world.w != null) @max(dirty.x0 - reach, 0) else dirty.x0 - reach;
    const z0 = if (world.d != null) @max(dirty.z0 - reach, 0) else dirty.z0 - reach;
    const x1 = if (world.w) |w| @min(dirty.x1 + reach, @as(i32, @intCast(w))) else dirty.x1 + reach;
    const z1 = if (world.d) |d| @min(dirty.z1 + reach, @as(i32, @intCast(d))) else dirty.z1 + reach;

    var s = Scratch.init(allocator, x0, z0, x1, z1, world);
    defer s.deinit();
    try decodeColumns(world, &s);

    var reseeds: std.ArrayList(u32) = .empty;
    defer reseeds.deinit(allocator);
    var clear_q: std.ArrayList(u64) = .empty;
    defer clear_q.deinit(allocator);
    var any_clear = false;

    // The stale scan only acts on cells with decoded light, so it
    // iterates the scratch map (the lit cells) filtered to the dirty
    // region, not the region's half-million cells (chunk loads,
    // plans/STREAMING.md phase 2). Start cells are collected first —
    // clearChain mutates the map.
    if (s.map.count() != 0) {
        var starts: std.ArrayList(u32) = .empty;
        defer starts.deinit(allocator);
        var it = s.map.iterator();
        while (it.next()) |e| {
            const x, const y, const z = s.coords(e.key_ptr.*);
            if (x < dirty.x0 or x >= dirty.x1 or y < dirty.y0 or y >= dirty.y1 or z < dirty.z0 or z >= dirty.z1) continue;
            const cur = s.get(e.key_ptr.*);
            const m = world.get(x, y, z);
            const is_seed = m != 0 and world_mod.palette[m].emissive != 0;
            const was_seed = cur.dir == .none;
            const stale = if (is_seed)
                !(was_seed and cur.color_id == m and cur.intensity == params.seed_intensity)
            else if (m != 0)
                true
            else
                was_seed;
            if (stale) try starts.append(allocator, e.key_ptr.*);
        }
        for (starts.items) |vi| {
            any_clear = true;
            try clearChain(&s, vi, params, &reseeds, &clear_q, allocator);
        }
    }

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try seedEmissiveBox(world, &s, &queue, allocator, params, dirty.x0, dirty.y0, dirty.z0, dirty.x1, dirty.y1, dirty.z1);
    for (reseeds.items) |vi| {
        if (s.intensity(vi) != 0) try queue.append(allocator, vi);
    }
    // Fast path (the common chunk load, plans/STREAMING.md phase 2): no
    // decoded light, no stale clears, no seeds — nothing can change.
    // Skipping encodeColumns is valid because it would only clear and
    // re-encode the box's (all-null) light runs.
    if (!any_clear and s.map.count() == 0 and queue.items.len == 0) return .{};
    // Enqueue every lit cell face-adjacent to the dirty region so
    // carved air floods from its neighbors: the one-cell shell around
    // the region (~26k cells on a chunk box), not the region's whole
    // volume (~524k map probes).
    if (s.map.count() != 0) {
        const sx0 = @max(dirty.x0 - 1, s.x0);
        const sy0 = @max(dirty.y0 - 1, 0);
        const sz0 = @max(dirty.z0 - 1, s.z0);
        const sx1 = @min(dirty.x1 + 1, s.x0 + @as(i32, @intCast(s.xd)));
        const sy1 = @min(dirty.y1 + 1, @as(i32, @intCast(s.h)));
        const sz1 = @min(dirty.z1 + 1, s.z0 + @as(i32, @intCast(s.zd)));
        var x = sx0;
        while (x < sx1) : (x += 1) {
            const in_x = x >= dirty.x0 and x < dirty.x1;
            var z = sz0;
            while (z < sz1) : (z += 1) {
                const in_z = z >= dirty.z0 and z < dirty.z1;
                var y = sy0;
                while (y < sy1) : (y += 1) {
                    const in_y = y >= dirty.y0 and y < dirty.y1;
                    if (in_x and in_y and in_z) continue;
                    const adjacent = (in_y and in_z and (x == dirty.x0 - 1 or x == dirty.x1)) or
                        (in_x and in_z and (y == dirty.y0 - 1 or y == dirty.y1)) or
                        (in_x and in_y and (z == dirty.z0 - 1 or z == dirty.z1));
                    if (!adjacent) continue;
                    const vi = s.index(x, y, z);
                    if (s.intensity(vi) != 0) try queue.append(allocator, vi);
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
fn clearChain(s: *Scratch, start: u32, params: Params, reseeds: *std.ArrayList(u32), q: *std.ArrayList(u64), allocator: std.mem.Allocator) !void {
    const first = s.get(start);
    const color0 = first.color_id;
    const level0 = first.intensity;
    s.clear(start);
    q.clearRetainingCapacity();
    try q.append(allocator, (@as(u64, level0) << 32) | @as(u64, start));
    var head: usize = 0;
    while (head < q.items.len) : (head += 1) {
        const entry = q.items[head];
        const vi: u32 = @intCast(entry & 0xffffffff);
        const level: u8 = @intCast(entry >> 32);
        const cand = level -| params.attenuation;
        if (cand == 0) continue;
        const x, const y, const z = s.coords(vi);
        inline for (neighbor_offsets) |off| {
            const nx = @as(i64, x) + off[0];
            const ny = @as(i64, y) + off[1];
            const nz = @as(i64, z) + off[2];
            if (s.contains(nx, ny, nz)) {
                const nvi = s.index(@intCast(nx), @intCast(ny), @intCast(nz));
                const n = s.get(nvi);
                if (n.intensity != 0) {
                    if (n.color_id == color0 and n.intensity == cand) {
                        s.clear(nvi);
                        try q.append(allocator, (@as(u64, cand) << 32) | @as(u64, nvi));
                    } else {
                        try reseeds.append(allocator, nvi);
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
    for (0..4) |x| {
        for (0..4) |z| {
            try std.testing.expect(world.columnAt(@intCast(x), @intCast(z)).?.light == null);
        }
    }
}

test "reflood frees and replaces previous light runs" {
    var world = try World.init(std.testing.allocator, 3, 8, 3);
    defer world.deinit();
    try world.set(1, 4, 1, 9);
    _ = try floodAll(&world, std.testing.allocator, .{});
    try std.testing.expect(world.columnAt(1, 1).?.light != null);
    try world.set(1, 4, 1, 1);
    _ = try floodAll(&world, std.testing.allocator, .{});
    for (0..3) |x| {
        for (0..3) |z| {
            try std.testing.expect(world.columnAt(@intCast(x), @intCast(z)).?.light == null);
        }
    }
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
    for (0..a.w.?) |x| {
        for (0..a.d.?) |z| {
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
    for (0..world.w.?) |x| {
        for (0..world.d.?) |z| {
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
