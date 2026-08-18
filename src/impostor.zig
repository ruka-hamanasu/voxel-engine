const std = @import("std");
const gen = @import("gen.zig");
const pool_mod = @import("pool.zig");
const terrain = @import("gen/terrain.zig");
const world_mod = @import("world.zig");
const Camera = @import("camera.zig").Camera;

/// Far-tier heightfield impostor (plans/DISTANCE.md D3/D3.1): past
/// the near/mid cascade, a set of streamed 2D heightmap grids — one
/// solid interval [0, top_y] per cell — replaces every deeper LOD
/// level. The impostor is itself a cascade: level i has cells of
/// base_cell * 2^i voxels and hands off at 72 * cell voxels, the same
/// pixels-per-cell invariant the coarse cascade keeps ({144, 288,
/// 576, ...} = 72 * {2, 4, 8, ...}), so every seam is a 2x-granularity
/// handoff and per-level march stays ~72 cells. Cells synthesize from
/// the pure generator heightfield (gen.impostorCell): no fine data,
/// no flood, render-only. The per-cell stamp is the dirty/version
/// hook for the persistence milestone's edited-column overlay
/// (DISTANCE.md D3 edits note); nothing consumes it yet.
///
/// Residency mirrors the chunk streamer: per level, a Chebyshev tile
/// disc around the camera (radius = the level's outer handoff in
/// tiles + 1), one tile of unload hysteresis, synthesis budgeted per
/// update in cell units (a tile commits to its map only when
/// complete, so renders never read a partial tile). Render threads
/// read via cellAt; synthesis batches ride the shared pool as
/// disjoint cell-range items over the in-flight tile (D4; null pool =
/// inline), with tile commit/unload on the calling thread, so pooled
/// and inline rings are byte-identical.
pub const tile_shift = 5;
pub const tile_cells = 1 << tile_shift; // 32x32 cells per tile
const cells_per_tile = tile_cells * tile_cells;
pub const max_levels = 8;
/// Handoff schedule invariant (plans/DISTANCE.md D3.1 F2): every tier
/// — cascade or impostor — hands off where its cell covers f/72 px,
/// i.e. at 72 * cell_size voxels.
pub const handoff_per_cell: f32 = 72.0;

pub const Cell = struct { top_y: u16, mat: u8, stamp: u8 = 0 };

const Tile = struct { cells: [cells_per_tile]Cell };

/// Hash-map key for the tile at tile coords (tx, tz): packed i32 pair
/// (arithmetic-shift tile coords, so negatives work), same scheme as
/// world.zig's chunkKey.
fn tileKey(tx: i32, tz: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(tx))) << 32) | @as(u32, @bitCast(tz));
}

fn unpackKey(key: u64) [2]i32 {
    return .{ @bitCast(@as(u32, @truncate(key >> 32))), @bitCast(@as(u32, @truncate(key))) };
}

/// Multiplicative-mix hash, same rationale as world.zig's ChunkMap:
/// the march pays a lookup per cell-tile crossing.
const TileMap = std.HashMap(u64, *Tile, struct {
    pub fn hash(_: @This(), k: u64) u64 {
        return k *% 0x9E3779B97F4A7C15;
    }
    pub fn eql(_: @This(), a: u64, b: u64) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

/// Last-lookup memo, sharded per render-pool participant exactly like
/// world.zig's (reuses its threadlocal slot; padded to its own cache
/// line). Mutated through the const accessor via @constCast.
const Memo = struct {
    key: u64 = 0,
    tile: ?*Tile = null,
    _pad: [48]u8 = @splat(0),
};

pub const Level = struct {
    shift: u5,
    /// 1 / cell_size: the level's scaled-frame factor.
    inv_cell: f32,
    /// Ray distance where this level takes over (72 * cell_size by
    /// default), snapped to a cell plane per ray by render.lodBoundary.
    handoff: f32,
    /// Load radius in tiles (Chebyshev) around the camera's tile.
    radius: i32,
    tiles: TileMap,
    memo: [world_mod.World.memo_slots]Memo = @splat(.{}),
};

pub const Impostor = struct {
    allocator: std.mem.Allocator,
    kind: gen.Generator,
    tctx: terrain.Ctx,
    /// Bounded world's XZ extent (cells fully outside are never
    /// synthesized and read as absent); null when unbounded.
    bounds: ?[2]usize,
    levels: [max_levels]Level,
    n_levels: usize,
    /// Cells synthesized per update (partial tiles stay invisible
    /// until complete).
    budget: usize,
    /// Borrowed synthesis pool; null runs inline (tests).
    pool: ?*pool_mod.Pool = null,
    in_flight: ?InFlight = null,

    const InFlight = struct {
        level: usize,
        key: u64,
        tx: i32,
        tz: i32,
        tile: *Tile,
        next: usize,
    };

    /// Levels: cell_size * 2^i vox/cell, handoff doubling from
    /// base_handoff, while the handoff is inside the cutoff. The last
    /// level's ring reaches the cutoff (its march range truncates
    /// there, like the cascade's last level).
    pub fn init(allocator: std.mem.Allocator, kind: gen.Generator, seed: u64, h: usize, cell_size: u32, base_handoff: f32, cutoff: f32, bounds: ?[2]usize, pool: ?*pool_mod.Pool) !Impostor {
        std.debug.assert(cell_size >= 16 and cell_size <= 4096 and std.math.isPowerOfTwo(cell_size));
        var self: Impostor = .{
            .allocator = allocator,
            .kind = kind,
            .tctx = terrain.Ctx.init(seed, h),
            .bounds = bounds,
            .levels = undefined,
            .n_levels = 0,
            .budget = 512,
            .pool = pool,
        };
        errdefer self.deinit();
        var handoff = base_handoff;
        var size = cell_size;
        while (self.n_levels < max_levels and handoff < cutoff) : ({
            handoff *= 2;
            size *= 2;
        }) {
            const shift: u5 = @intCast(std.math.log2_int(u32, size));
            const tile_vox: f32 = @floatFromInt(@as(i32, tile_cells) << shift);
            self.levels[self.n_levels] = .{
                .shift = shift,
                .inv_cell = 1.0 / @as(f32, @floatFromInt(size)),
                .handoff = handoff,
                .radius = @as(i32, @intFromFloat(@ceil(@min(cutoff, handoff * 2) / tile_vox))) + 1,
                .tiles = TileMap.init(allocator),
            };
            self.n_levels += 1;
        }
        return self;
    }

    pub fn deinit(self: *Impostor) void {
        self.dropInFlight();
        for (self.levels[0..self.n_levels]) |*lvl| {
            var it = lvl.tiles.valueIterator();
            while (it.next()) |tile| self.allocator.destroy(tile.*);
            lvl.tiles.deinit();
        }
    }

    fn dropInFlight(self: *Impostor) void {
        if (self.in_flight) |*f| {
            self.allocator.destroy(f.tile);
            self.in_flight = null;
        }
    }

    fn gctx(self: *const Impostor) gen.ImpostorCtx {
        return switch (self.kind) {
            .terrain => .{ .terrain = &self.tctx },
        };
    }

    /// Cell at cell coords (ix, iz) of the given level, or null when
    /// its tile is not resident (beyond the ring, mid-synthesis) or
    /// fully outside a bounded world — all read as fogged sky by the
    /// march.
    pub inline fn cellAt(self: *const Impostor, level: usize, ix: i32, iz: i32) ?Cell {
        const lvl = &self.levels[level];
        if (self.bounds) |b| {
            const s: i32 = @as(i32, 1) << lvl.shift;
            const x0 = ix << lvl.shift;
            const z0 = iz << lvl.shift;
            if (x0 >= @as(i32, @intCast(b[0])) or z0 >= @as(i32, @intCast(b[1])) or x0 + s <= 0 or z0 + s <= 0) return null;
        }
        const key = tileKey(ix >> tile_shift, iz >> tile_shift);
        const m = &lvl.memo[world_mod.World.memo_slot];
        var tile = m.tile;
        if (tile == null or m.key != key) {
            tile = lvl.tiles.get(key);
            const mut: *Memo = @constCast(m);
            mut.key = key;
            mut.tile = tile;
        }
        const t = tile orelse return null;
        const lx: usize = @intCast(ix & (tile_cells - 1));
        const lz: usize = @intCast(iz & (tile_cells - 1));
        return t.cells[lx * tile_cells + lz];
    }

    /// True when the tile's whole voxel footprint falls outside a
    /// bounded world (never synthesized).
    fn tileOutside(self: *const Impostor, lvl: *const Level, tx: i32, tz: i32) bool {
        const b = self.bounds orelse return false;
        const extent: i32 = @as(i32, tile_cells) << lvl.shift;
        const x0 = tx * extent;
        const z0 = tz * extent;
        return x0 >= @as(i32, @intCast(b[0])) or z0 >= @as(i32, @intCast(b[1])) or x0 + extent <= 0 or z0 + extent <= 0;
    }

    /// Nearest missing in-bounds tile within the level's load ring,
    /// if any.
    fn nearestMissing(self: *Impostor, level: usize, txc: i32, tzc: i32) ?[2]i32 {
        const lvl = &self.levels[level];
        var best: ?[2]i32 = null;
        var best_d: i32 = std.math.maxInt(i32);
        var dz = -lvl.radius;
        while (dz <= lvl.radius) : (dz += 1) {
            var dx = -lvl.radius;
            while (dx <= lvl.radius) : (dx += 1) {
                const d: i32 = @intCast(@max(@abs(dx), @abs(dz)));
                if (d >= best_d) continue;
                const tx = txc + dx;
                const tz = tzc + dz;
                if (lvl.tiles.contains(tileKey(tx, tz))) continue;
                if (self.in_flight) |f| {
                    if (f.level == level and f.tx == tx and f.tz == tz) continue;
                }
                if (self.tileOutside(lvl, tx, tz)) continue;
                best = .{ tx, tz };
                best_d = d;
            }
        }
        return best;
    }

    /// One streaming step: unload past the hysteresis radius at every
    /// level, then synthesize up to `budget` cells, level-first
    /// (finer levels first, like the chunk streamer) then
    /// nearest-first. Returns true while work remains.
    pub fn updateBudgeted(self: *Impostor, cam: Camera, budget: usize) !bool {
        const cx: i32 = @intFromFloat(@floor(cam.x));
        const cz: i32 = @intFromFloat(@floor(cam.z));

        // Unload pass per level (one tile of hysteresis).
        for (0..self.n_levels) |li| {
            const lvl = &self.levels[li];
            const extent: i32 = @as(i32, tile_cells) << lvl.shift;
            const txc = @divFloor(cx, extent);
            const tzc = @divFloor(cz, extent);
            var drop: std.ArrayList(u64) = .empty;
            defer drop.deinit(self.allocator);
            var it = lvl.tiles.keyIterator();
            while (it.next()) |k| {
                const tc = unpackKey(k.*);
                const d = @max(@abs(tc[0] - txc), @abs(tc[1] - tzc));
                if (d > lvl.radius + 1) try drop.append(self.allocator, k.*);
            }
            for (drop.items) |key| {
                if (self.in_flight) |f| {
                    if (f.level == li and f.key == key) self.dropInFlight();
                }
                const kv = lvl.tiles.fetchRemove(key) orelse continue;
                for (&lvl.memo) |*m| {
                    if (m.tile == kv.value) m.* = .{};
                }
                self.allocator.destroy(kv.value);
            }
        }
        if (self.in_flight) |f| {
            // The camera may have moved far since the tile started.
            const lvl = &self.levels[f.level];
            const extent: i32 = @as(i32, tile_cells) << lvl.shift;
            const d = @max(@abs(f.tx - @divFloor(cx, extent)), @abs(f.tz - @divFloor(cz, extent)));
            if (d > lvl.radius + 1) self.dropInFlight();
        }

        var remaining = budget;
        while (remaining > 0) {
            if (self.in_flight == null) {
                var started = false;
                for (0..self.n_levels) |li| {
                    const lvl = &self.levels[li];
                    const extent: i32 = @as(i32, tile_cells) << lvl.shift;
                    const missing = self.nearestMissing(li, @divFloor(cx, extent), @divFloor(cz, extent)) orelse continue;
                    const tile = try self.allocator.create(Tile);
                    errdefer self.allocator.destroy(tile);
                    self.in_flight = .{ .level = li, .key = tileKey(missing[0], missing[1]), .tx = missing[0], .tz = missing[1], .tile = tile, .next = 0 };
                    started = true;
                    break;
                }
                if (!started) break;
            }
            const f = &self.in_flight.?;
            const lvl = &self.levels[f.level];
            const n = @min(remaining, cells_per_tile - f.next);
            const size = @as(u32, 1) << lvl.shift;
            const job: CellJob = .{ .gctx = self.gctx(), .tile = f.tile, .base_cx = f.tx * tile_cells, .base_cz = f.tz * tile_cells, .shift = lvl.shift, .size = size, .first = f.next, .last = f.next + n };
            pool_mod.dispatch(self.pool, &job, CellJob.run, job.items());
            f.next += n;
            remaining -= n;
            if (f.next == cells_per_tile) {
                const key = f.key;
                const tile = f.tile;
                self.in_flight = null;
                try lvl.tiles.put(key, tile);
            }
        }
        // Work remains if any level still has a missing tile.
        if (self.in_flight != null) return true;
        for (0..self.n_levels) |li| {
            const lvl = &self.levels[li];
            const extent: i32 = @as(i32, tile_cells) << lvl.shift;
            if (self.nearestMissing(li, @divFloor(cx, extent), @divFloor(cz, extent)) != null) return true;
        }
        return false;
    }

    pub fn update(self: *Impostor, cam: Camera) !void {
        _ = try self.updateBudgeted(cam, self.budget);
    }

    /// Synchronous warm-up (startup, headless, bench): the resident
    /// ring is then deterministic.
    pub fn runToCompletion(self: *Impostor, cam: Camera) !void {
        while (try self.updateBudgeted(cam, std.math.maxInt(usize))) {}
    }
};

/// Synthesis batch job (D4): item i fills cells [first + i*gran, ...)
/// of the in-flight tile. gen.impostorCell is a pure function of the
/// generator context and cell origin, and items write disjoint cells,
/// so pooled and inline fills produce identical tiles.
const CellJob = struct {
    const gran = 128;

    gctx: gen.ImpostorCtx,
    tile: *Tile,
    base_cx: i32, // tile origin in cell coords
    base_cz: i32,
    shift: u5,
    size: u32,
    first: usize,
    last: usize,

    fn items(self: *const CellJob) usize {
        return (self.last - self.first + gran - 1) / gran;
    }

    fn run(self: *const CellJob, item: usize) void {
        const begin = self.first + item * gran;
        for (begin..@min(begin + gran, self.last)) |idx| {
            const lx: i32 = @intCast(idx / tile_cells);
            const lz: i32 = @intCast(idx % tile_cells);
            const c = gen.impostorCell(self.gctx, (self.base_cx + lx) << self.shift, (self.base_cz + lz) << self.shift, self.size);
            self.tile.cells[idx] = .{ .top_y = c.top_y, .mat = c.mat };
        }
    }
};

test "budgeted synthesis matches run-to-completion and the ring tracks the camera" {
    const cam: Camera = .{ .x = 100.5, .y = 40, .z = -200.5, .yaw = 0 };
    // Budgeted: one cell at a time must produce the same cells.
    var a = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 4096, null, null);
    defer a.deinit();
    var b = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 4096, null, null);
    defer b.deinit();
    try a.runToCompletion(cam);
    while (try b.updateBudgeted(cam, 1)) {}
    try std.testing.expectEqual(a.n_levels, b.n_levels);
    for (0..a.n_levels) |li| {
        try std.testing.expectEqual(a.levels[li].tiles.count(), b.levels[li].tiles.count());
        var it = a.levels[li].tiles.iterator();
        while (it.next()) |e| {
            const bt = b.levels[li].tiles.get(e.key_ptr.*).?;
            try std.testing.expectEqualSlices(Cell, &e.value_ptr.*.cells, &bt.cells);
        }
    }
    // Every in-ring cell answers; a far-away cell does not.
    const cs: i32 = 32;
    const ccx: i32 = @intFromFloat(@floor(cam.x / cs));
    const ccz: i32 = @intFromFloat(@floor(cam.z / cs));
    try std.testing.expect(a.cellAt(0, ccx, ccz) != null);
    try std.testing.expect(a.cellAt(0, ccx + 10000, ccz) == null);
    // Camera move: after updating around a distant point, cells there
    // become resident.
    try a.runToCompletion(.{ .x = cam.x + 20000, .y = 40, .z = cam.z, .yaw = 0 });
    try std.testing.expect(a.cellAt(0, ccx + 625, ccz) != null);
}

test "pooled synthesis matches inline (plans/DISTANCE.md D4)" {
    const cam: Camera = .{ .x = 100.5, .y = 40, .z = -200.5, .yaw = 0 };
    var a = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 10240, null, null);
    defer a.deinit();
    try a.runToCompletion(cam);

    var pool: pool_mod.Pool = .{};
    try pool.start(pool_mod.max_participants - 1);
    defer pool.deinit();
    var b = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 10240, null, &pool);
    defer b.deinit();
    // Odd budget so tile fills slice mid-batch across updates.
    while (try b.updateBudgeted(cam, 333)) {}

    try std.testing.expectEqual(a.n_levels, b.n_levels);
    for (0..a.n_levels) |li| {
        try std.testing.expectEqual(a.levels[li].tiles.count(), b.levels[li].tiles.count());
        var it = a.levels[li].tiles.iterator();
        while (it.next()) |e| {
            const bt = b.levels[li].tiles.get(e.key_ptr.*).?;
            try std.testing.expectEqualSlices(Cell, &e.value_ptr.*.cells, &bt.cells);
        }
    }
}

test "bounded worlds never synthesize outside the bounds" {
    var imp = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 4096, .{ 300, 300 }, null);
    defer imp.deinit();
    try imp.runToCompletion(.{ .x = 150, .y = 40, .z = 150, .yaw = 0 });
    // Cell (9, 4) covers voxels x in [288, 320): partially inside.
    try std.testing.expect(imp.cellAt(0, 9, 4) != null);
    // Cell (10, 4) covers [320, 352): fully outside w=300.
    try std.testing.expect(imp.cellAt(0, 10, 4) == null);
    try std.testing.expect(imp.cellAt(0, -1, 4) == null);
}

test "levels follow the 72x pixel-matched schedule" {
    var imp = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 10240, null, null);
    defer imp.deinit();
    // 2304, 4608, 9216 inside the 10240 cutoff; 18432 beyond.
    try std.testing.expectEqual(@as(usize, 3), imp.n_levels);
    try std.testing.expectEqual(@as(f32, 2304), imp.levels[0].handoff);
    try std.testing.expectEqual(@as(f32, 9216), imp.levels[2].handoff);
    try std.testing.expectEqual(@as(u5, 5), imp.levels[0].shift); // 32 vox
    try std.testing.expectEqual(@as(u5, 7), imp.levels[2].shift); // 128 vox
    var big = try Impostor.init(std.testing.allocator, .terrain, 7, 96, 32, 2304, 100000, null, null);
    defer big.deinit();
    try std.testing.expectEqual(@as(usize, 6), big.n_levels); // 32..1024
}
