const std = @import("std");
const world_mod = @import("world.zig");
const chunk_mod = @import("chunk.zig");
const terrain = @import("gen/terrain.zig");
const lighting = @import("lighting.zig");
const lod_mod = @import("lod.zig");
const Builder = @import("gen/builder.zig").Builder;
const Camera = @import("camera.zig").Camera;

const World = world_mod.World;
const chunk_w = world_mod.chunk_w;

/// Chunk streamer (STREAMING.md phase 2 item 11): keeps a per-level
/// Chebyshev disc of chunks resident around the camera — level i's
/// radius = its max render distance (the handoff into level i+1, or
/// the fog cutoff for the last level) in level voxels plus a small
/// margin (4 for the light/sky reads past the march, one coarse voxel
/// for the handoff boundary cell's fine shading), rounded up to whole
/// chunks. Unloads use one chunk of hysteresis past the load radius;
/// both sit deep in fog, so load/unload relights are invisible.
///
/// Generation cost concentrates in the dense fill, so the per-update
/// budget slices column ranges of the fill stage; arch stamps, the
/// coarse pyramid, run-encoding, and the load flood run as one
/// finishing step (commitChunk). An in-flight chunk keeps its partial
/// tile as streamer state and is not resident until it commits — the
/// flood's resident-cell confinement makes that read as blocked, and
/// the commit flood is a pure add pass.
///
/// Coarse levels synthesize from generation (never from resident fine
/// chunks), so the levels are independent: no load ordering or
/// residency dependencies between them. Edits patch resident coarse
/// columns via lod.rebuildRegion (onEdit); when a fine chunk with
/// live edits unloads, the covering coarse columns are re-synthesized
/// from generation (repair queue) so lost edits leave the coarse
/// tiers. Unedited fine chunks need no repair — their coarse content
/// already matches generation.
pub const Streamer = struct {
    allocator: std.mem.Allocator,
    ctx: terrain.Ctx,
    fine: *World,
    lods: []World,
    light: ?lighting.Params,
    /// false = approx coarse synthesis (genColumnFast: no sub-skin
    /// caves/crystals — the default, ~10x cheaper); true = exact.
    coarse_caves: bool,
    budget: usize, // dense-fill columns per update
    fine_builder: Builder,
    coarse_builders: []Builder,
    tile_pyr: [][]u8, // per coarse level: the level's dense tile scratch
    rep_grid: []u8, // repair scratch: dense fine grid (max span)
    rep_pyr: []u8, // repair scratch: flat pyramid (sliced per level)
    rep_col: []u8, // repair scratch: one coarse column (max coarse h)
    arches: std.ArrayList(terrain.Arch),
    edited: std.AutoHashMap(u64, void), // fine chunk keys holding live edits
    load_r: []i32, // per level (0 = fine): load radius in chunks
    unload_r: []i32,
    queue: std.ArrayList(Work), // pending loads, sorted level/dist first
    repairs: std.ArrayList(Work), // pending coarse re-syntheses
    in_flight: ?InFlight,

    const Work = struct {
        level: u32, // 0 = fine; repairs always coarse
        cx: i32,
        cz: i32, // load: chunk coords at its level; repair: FINE chunk coords
        dist: i32 = 0, // Chebyshev distance from the level's center chunk
    };

    const InFlight = struct {
        level: u32,
        cx: i32,
        cz: i32,
        tile: usize, // next fine tile within the footprint
        col: usize, // next dense-fill column within the current tile
    };

    /// lod_dists is the resolved increasing handoff prefix (one entry
    /// per coarse level, matching render.RenderParams). The fine world
    /// must be unbounded.
    pub fn init(allocator: std.mem.Allocator, fine: *World, seed: u64, lod_dists: []const f32, fog_cutoff: f32, light: ?lighting.Params, budget: usize, coarse_caves: bool) !Streamer {
        std.debug.assert(fine.w == null); // streaming implies unbounded
        const n = lod_dists.len;
        std.debug.assert(n <= 8);
        var s: Streamer = undefined;
        s.allocator = allocator;
        s.ctx = terrain.Ctx.init(seed, fine.h);
        s.fine = fine;
        s.light = light;
        s.budget = budget;
        s.coarse_caves = coarse_caves;
        s.lods = &.{};
        s.coarse_builders = &.{};
        s.tile_pyr = &.{};
        s.rep_grid = &.{};
        s.rep_pyr = &.{};
        s.rep_col = &.{};
        s.load_r = &.{};
        s.unload_r = &.{};
        s.arches = .empty;
        s.edited = std.AutoHashMap(u64, void).init(allocator);
        s.queue = .empty;
        s.repairs = .empty;
        s.in_flight = null;
        var lods_built: usize = 0;
        var builders_built: usize = 0;
        var pyr_built: usize = 0;
        var builder_built = false;
        errdefer {
            if (builder_built) s.fine_builder.deinit();
            for (s.lods[0..lods_built]) |*w| w.deinit();
            for (s.coarse_builders[0..builders_built]) |*b| b.deinit();
            for (s.tile_pyr[0..pyr_built]) |p| allocator.free(p);
            if (s.lods.len > 0) allocator.free(s.lods);
            if (s.coarse_builders.len > 0) allocator.free(s.coarse_builders);
            if (s.tile_pyr.len > 0) allocator.free(s.tile_pyr);
            if (s.rep_grid.len > 0) allocator.free(s.rep_grid);
            if (s.rep_pyr.len > 0) allocator.free(s.rep_pyr);
            if (s.rep_col.len > 0) allocator.free(s.rep_col);
            if (s.load_r.len > 0) allocator.free(s.load_r);
            if (s.unload_r.len > 0) allocator.free(s.unload_r);
            s.arches.deinit(allocator);
            s.edited.deinit();
            s.queue.deinit(allocator);
            s.repairs.deinit(allocator);
        }
        s.fine_builder = try Builder.init(allocator, fine, chunk_w, chunk_w);
        builder_built = true;
        s.lods = try allocator.alloc(World, n);
        s.coarse_builders = try allocator.alloc(Builder, n);
        s.tile_pyr = try allocator.alloc([]u8, n);
        var h = fine.h;
        for (0..n) |i| {
            h = (h + 1) / 2;
            s.lods[i] = try World.init(allocator, null, h, null);
            lods_built += 1;
            s.coarse_builders[i] = try Builder.init(allocator, &s.lods[i], chunk_w, chunk_w);
            builders_built += 1;
            const dim = chunk_mod.levelDims(fine.h, @intCast(i + 1));
            s.tile_pyr[i] = try allocator.alloc(u8, dim.side * dim.side * dim.h);
            pyr_built += 1;
        }
        s.load_r = try allocator.alloc(i32, n + 1);
        s.unload_r = try allocator.alloc(i32, n + 1);
        for (0..n + 1) |i| {
            const dist = if (i < n) lod_dists[i] else fog_cutoff;
            s.load_r[i] = chunkRadius(dist, @intCast(i));
            s.unload_r[i] = s.load_r[i] + 1;
        }
        const max_span = @as(usize, 1) << @intCast(n);
        s.rep_grid = try allocator.alloc(u8, max_span * max_span * fine.h);
        var pyr_total: usize = 0;
        for (1..n + 1) |j| {
            const dim = chunk_mod.levelDims(fine.h, @intCast(j));
            pyr_total += (max_span >> @intCast(j)) * (max_span >> @intCast(j)) * dim.h;
        }
        s.rep_pyr = try allocator.alloc(u8, pyr_total);
        s.rep_col = try allocator.alloc(u8, if (n > 0) s.lods[0].h else 0);
        return s;
    }

    pub fn deinit(self: *Streamer) void {
        for (self.lods) |*w| w.deinit();
        for (self.coarse_builders) |*b| b.deinit();
        for (self.tile_pyr) |p| self.allocator.free(p);
        self.allocator.free(self.rep_grid);
        self.allocator.free(self.rep_pyr);
        self.allocator.free(self.rep_col);
        self.allocator.free(self.lods);
        self.allocator.free(self.coarse_builders);
        self.allocator.free(self.tile_pyr);
        self.allocator.free(self.load_r);
        self.allocator.free(self.unload_r);
        self.fine_builder.deinit();
        self.arches.deinit(self.allocator);
        self.edited.deinit();
        self.queue.deinit(self.allocator);
        self.repairs.deinit(self.allocator);
    }

    /// Load radius in level-i chunks: the level's render distance in
    /// level voxels (dist / 2^i) plus margin (4 for light/sky reads
    /// past the march + one coarse voxel for the handoff boundary
    /// cell's fine shading), rounded up to whole chunks.
    fn chunkRadius(dist_fine: f32, level: u32) i32 {
        const scale: f32 = @floatFromInt(@as(usize, 1) << @intCast(level));
        const voxels = dist_fine / scale + 4.0 / scale + 1.0;
        return @intFromFloat(@ceil(voxels / @as(f32, chunk_w)));
    }

    fn levelWorld(self: *Streamer, level: u32) *World {
        return if (level == 0) self.fine else &self.lods[level - 1];
    }

    /// Chunk coords of a fine-coords position at the given level.
    fn chunkAtLevel(x: f32, level: u32) i32 {
        const fx: i32 = @intFromFloat(@floor(x));
        return @divFloor(fx, @as(i32, chunk_w) << @as(u5, @intCast(level)));
    }

    fn unpackKey(key: u64) [2]i32 {
        return .{ @bitCast(@as(u32, @truncate(key >> 32))), @bitCast(@as(u32, @truncate(key))) };
    }

    /// One streaming step: unload past the hysteresis radius, refresh
    /// the load queue, and fill up to `budget` columns. Returns true
    /// while work (queued, repairing, or in flight) remains.
    pub fn updateBudgeted(self: *Streamer, cam: Camera, budget: usize) !bool {
        const n_levels: u32 = @intCast(self.lods.len + 1);

        // Unload pass.
        for (0..n_levels) |li| {
            const level: u32 = @intCast(li);
            const w = self.levelWorld(level);
            const ccx = chunkAtLevel(cam.x, level);
            const ccz = chunkAtLevel(cam.z, level);
            var drop: std.ArrayList(u64) = .empty;
            defer drop.deinit(self.allocator);
            var it = w.chunks.keyIterator();
            while (it.next()) |k| {
                const cc = unpackKey(k.*);
                const d = @max(@abs(cc[0] - ccx), @abs(cc[1] - ccz));
                if (d > self.unload_r[li]) try drop.append(self.allocator, k.*);
            }
            for (drop.items) |key| {
                const cc = unpackKey(key);
                if (level == 0 and self.edited.remove(key)) {
                    // The chunk's edits vanish with it: re-synthesize
                    // the covering coarse columns from generation.
                    for (1..n_levels) |rl| {
                        try self.repairs.append(self.allocator, .{ .level = @intCast(rl), .cx = cc[0], .cz = cc[1] });
                    }
                }
                try chunk_mod.unloadChunk(w, cc[0], cc[1], self.light);
            }
        }

        // Load queue rebuild: every missing chunk in the discs,
        // nearest-first within each level, finer levels first.
        self.queue.clearRetainingCapacity();
        for (0..n_levels) |li| {
            const level: u32 = @intCast(li);
            const w = self.levelWorld(level);
            const ccx = chunkAtLevel(cam.x, level);
            const ccz = chunkAtLevel(cam.z, level);
            const r = self.load_r[li];
            var dz = -r;
            while (dz <= r) : (dz += 1) {
                var dx = -r;
                while (dx <= r) : (dx += 1) {
                    const cx = ccx + dx;
                    const cz = ccz + dz;
                    if (w.chunks.contains(world_mod.chunkKey(cx, cz))) continue;
                    if (self.in_flight) |f| {
                        if (f.level == level and f.cx == cx and f.cz == cz) continue;
                    }
                    try self.queue.append(self.allocator, .{ .level = level, .cx = cx, .cz = cz, .dist = @intCast(@max(@abs(dx), @abs(dz))) });
                }
            }
        }
        std.mem.sort(Work, self.queue.items, {}, struct {
            fn less(_: void, a: Work, b: Work) bool {
                if (a.level != b.level) return a.level < b.level;
                if (a.dist != b.dist) return a.dist < b.dist;
                if (a.cx != b.cx) return a.cx < b.cx;
                return a.cz < b.cz;
            }
        }.less);

        // Work the queue under the column budget: fine loads, then
        // repairs, then coarse loads.
        var remaining = budget;
        while (remaining > 0) {
            if (self.in_flight == null) {
                if (self.queue.items.len > 0 and self.queue.items[0].level == 0) {
                    self.startLoad(self.queue.orderedRemove(0));
                } else if (self.repairs.items.len > 0) {
                    try self.execRepair(self.repairs.orderedRemove(0));
                    continue;
                } else if (self.queue.items.len > 0) {
                    self.startLoad(self.queue.orderedRemove(0));
                } else {
                    break;
                }
            }
            if (self.in_flight) |*f| {
                try self.progressLoad(f, &remaining);
                if (f.tile == self.tilesTotal(f.level)) self.in_flight = null;
            }
        }
        return self.in_flight != null or self.queue.items.len > 0 or self.repairs.items.len > 0;
    }

    pub fn update(self: *Streamer, cam: Camera) !void {
        _ = try self.updateBudgeted(cam, self.budget);
    }

    /// Run the streamer to completion around the camera (startup and
    /// headless/bench warm-up; the resident set is then deterministic).
    pub fn runToCompletion(self: *Streamer, cam: Camera) !void {
        while (try self.updateBudgeted(cam, std.math.maxInt(usize))) {}
    }

    /// Synchronously generate the fine chunks overlapping the
    /// fine-coords box [x0,x1)x[z0,z1) — the chunk under the player
    /// must be resident before physics (collision reads air as
    /// fall-through). An in-flight load of another chunk is dropped
    /// (its partial tile is streamer scratch; generation restarts).
    pub fn forceResident(self: *Streamer, x0: i32, z0: i32, x1: i32, z1: i32) !void {
        const cx0 = @divFloor(x0, chunk_w);
        const cz0 = @divFloor(z0, chunk_w);
        const cx1 = @divFloor(x1 - 1, chunk_w);
        const cz1 = @divFloor(z1 - 1, chunk_w);
        var cx = cx0;
        while (cx <= cx1) : (cx += 1) {
            var cz = cz0;
            while (cz <= cz1) : (cz += 1) {
                if (self.fine.chunks.contains(world_mod.chunkKey(cx, cz))) continue;
                if (self.in_flight) |*f| {
                    if (f.level == 0 and f.cx == cx and f.cz == cz) {
                        var all: usize = std.math.maxInt(usize);
                        try self.progressLoad(f, &all);
                        self.in_flight = null;
                        continue;
                    }
                    self.in_flight = null;
                }
                try chunk_mod.loadChunk(self.fine, &self.ctx, &self.fine_builder, cx, cz, null, self.light);
            }
        }
    }

    /// Edit propagation: fine relight, then per level a resident-only
    /// rebuildRegion + coarse relight — the eager loop's streaming
    /// form. Fine chunks covering the edit are marked so their unload
    /// schedules a coarse re-synthesis (the edit is lost with them).
    pub fn onEdit(self: *Streamer, r: world_mod.Region) !void {
        const cx0 = @divFloor(r.x0, chunk_w);
        const cz0 = @divFloor(r.z0, chunk_w);
        const cx1 = @divFloor(r.x1 - 1, chunk_w);
        const cz1 = @divFloor(r.z1 - 1, chunk_w);
        var cx = cx0;
        while (cx <= cx1) : (cx += 1) {
            var cz = cz0;
            while (cz <= cz1) : (cz += 1) {
                try self.edited.put(world_mod.chunkKey(cx, cz), {});
            }
        }
        if (self.light) |params| {
            _ = try lighting.relight(self.fine, self.allocator, r, params);
        }
        var rr = r;
        var finer: *const World = self.fine;
        for (self.lods) |*lw| {
            try lod_mod.rebuildRegion(self.allocator, finer, lw, rr);
            if (self.light) |params| {
                _ = try lighting.relight(lw, self.allocator, lod_mod.coarseRegion(lw, rr), params);
            }
            rr = lod_mod.coarseRegion(lw, rr);
            finer = lw;
        }
    }

    fn tilesTotal(self: *const Streamer, level: u32) usize {
        _ = self;
        const side = @as(usize, 1) << @intCast(level);
        return side * side;
    }

    fn startLoad(self: *Streamer, w: Work) void {
        // May have become resident while queued (forceResident).
        if (self.levelWorld(w.level).chunks.contains(world_mod.chunkKey(w.cx, w.cz))) return;
        self.in_flight = .{ .level = w.level, .cx = w.cx, .cz = w.cz, .tile = 0, .col = 0 };
    }

    /// Fill up to `remaining` columns of the in-flight chunk's current
    /// tile; a completed tile gets its arch stamps and (coarse levels)
    /// its pyramid downsample into the coarse builder. On the last
    /// tile the chunk commits (encode + flood) as one step.
    fn progressLoad(self: *Streamer, f: *InFlight, remaining: *usize) !void {
        const shift: u6 = @intCast(f.level);
        const tiles_side = @as(usize, 1) << shift;
        const total_cols = chunk_w * chunk_w;
        while (remaining.* > 0) {
            if (f.tile == tiles_side * tiles_side) {
                const w = self.levelWorld(f.level);
                const b = if (f.level == 0) &self.fine_builder else &self.coarse_builders[f.level - 1];
                try chunk_mod.commitChunk(w, b, f.cx, f.cz, self.light);
                return;
            }
            const take = @min(remaining.*, total_cols - f.col);
            const ttx = f.tile / tiles_side;
            const ttz = f.tile % tiles_side;
            const tx0 = (f.cx * chunk_w << @as(u5, @intCast(f.level))) + @as(i32, @intCast(ttx * chunk_w));
            const tz0 = (f.cz * chunk_w << @as(u5, @intCast(f.level))) + @as(i32, @intCast(ttz * chunk_w));
            terrain.genTileFill(&self.ctx, &self.fine_builder, tx0, tz0, chunk_w, f.col, f.col + take, f.level == 0 or self.coarse_caves);
            f.col += take;
            remaining.* -= take;
            if (f.col == total_cols) {
                try terrain.genTileArches(&self.ctx, &self.fine_builder, tx0, tz0, chunk_w, chunk_w, null);
                if (f.level > 0) {
                    // Pyramid the fine tile down to the target level
                    // and copy its coarse columns into the coarse tile.
                    var src = self.fine_builder.dense;
                    var ss: usize = chunk_w;
                    var sh: usize = self.fine.h;
                    for (0..f.level) |l| {
                        chunk_mod.downsampleDense(src, ss, sh, self.tile_pyr[l]);
                        src = self.tile_pyr[l];
                        ss /= 2;
                        sh = (sh + 1) / 2;
                    }
                    const dim = chunk_mod.levelDims(self.fine.h, f.level);
                    const cper = @as(usize, chunk_w) >> shift;
                    const cb = &self.coarse_builders[f.level - 1];
                    for (0..dim.side) |lx| {
                        for (0..dim.side) |lz| {
                            @memcpy(cb.at(ttx * cper + lx, ttz * cper + lz), src[(lx * dim.side + lz) * dim.h ..][0..dim.h]);
                        }
                    }
                }
                f.tile += 1;
                f.col = 0;
            }
        }
    }

    /// Re-synthesize the covering coarse columns for an unloaded fine
    /// chunk that held edits (level >= 1; cx/cz are FINE chunk coords).
    fn execRepair(self: *Streamer, w: Work) !void {
        const r: world_mod.Region = .{
            .x0 = w.cx * chunk_w,
            .y0 = 0,
            .z0 = w.cz * chunk_w,
            .x1 = w.cx * chunk_w + chunk_w,
            .y1 = @intCast(self.fine.h),
            .z1 = w.cz * chunk_w + chunk_w,
        };
        const shift: u6 = @intCast(w.level);
        const span = @as(usize, 1) << shift;
        const grid = self.rep_grid[0 .. span * span * self.fine.h];
        var pyr_slices: [8][]u8 = undefined;
        var off: usize = 0;
        for (1..w.level + 1) |j| {
            const dim = chunk_mod.levelDims(self.fine.h, @intCast(j));
            const side = span >> @intCast(j);
            pyr_slices[j - 1] = self.rep_pyr[off .. off + side * side * dim.h];
            off += side * side * dim.h;
        }
        const col = self.rep_col[0..self.lods[w.level - 1].h];
        try chunk_mod.resynthCoarseRegion(&self.lods[w.level - 1], &self.ctx, w.level, self.fine.h, r, null, self.light, self.coarse_caves, grid, pyr_slices[0..w.level], col, &self.arches, self.allocator);
    }
};

/// Per-chunk content hash: material runs strictly; light per cell as
/// (intensity, color) — arrival dirs and two-seed tie colors may
/// legitimately differ across load orders.
fn snapshot(allocator: std.mem.Allocator, world: *const World) !std.AutoHashMap(u64, u64) {
    var map = std.AutoHashMap(u64, u64).init(allocator);
    errdefer map.deinit();
    var it = world.chunks.iterator();
    while (it.next()) |e| {
        var h = std.hash.Wyhash.init(0);
        for (&e.value_ptr.*.columns) |*col| {
            h.update(std.mem.sliceAsBytes(col.runs));
            h.update(std.mem.asBytes(&col.top_solid_y));
            var y: i32 = 0;
            while (y < world.h) : (y += 1) {
                const s = lighting.sampleLight(col, y);
                h.update(std.mem.asBytes(&s.intensity));
                h.update(std.mem.asBytes(&s.color_id));
            }
        }
        try map.put(e.key_ptr.*, h.final());
    }
    return map;
}

/// Equal chunk sets, equal material runs; light compared per cell:
/// intensity strictly, color mismatches only as equal-intensity
/// two-seed ties (see the chunk.zig parity tests). Returns the tie
/// count.
fn expectSnapshotsEqual(a: *std.AutoHashMap(u64, u64), b: *std.AutoHashMap(u64, u64)) !void {
    try std.testing.expectEqual(a.count(), b.count());
    var it = a.iterator();
    while (it.next()) |e| {
        try std.testing.expectEqual(e.value_ptr.*, b.get(e.key_ptr.*) orelse 0);
    }
}

test "streamer: warm-up residency, budgeted equals completion, unload/reload round-trip" {
    const allocator = std.testing.allocator;
    const lod_dists = [_]f32{ 96, 192 };
    const cam_a: Camera = .{ .x = 32.5, .y = 60, .z = -200.5, .yaw = 0 }; // fine chunk (0, -4)
    // Far enough that no hysteresis-trail chunk survives the return:
    // a trail persists within unload_r of a disc, so the excursion
    // must clear (load_r + 1 + unload_r) * 2^level chunks per level.
    const cam_b: Camera = .{ .x = 32.5 + 48 * 64, .y = 60, .z = -200.5, .yaw = 0 };

    var fine = try World.init(allocator, null, 96, null);
    defer fine.deinit();
    var st = try Streamer.init(allocator, &fine, 7, &lod_dists, 448, .{}, 200, false);
    defer st.deinit();
    try st.runToCompletion(cam_a);

    // Disc residency: radius 2 around (0, -4) at every level.
    try std.testing.expect(fine.chunks.contains(world_mod.chunkKey(0, -4)));
    try std.testing.expect(fine.chunks.contains(world_mod.chunkKey(2, -2)));
    try std.testing.expect(fine.chunks.contains(world_mod.chunkKey(-2, -6)));
    try std.testing.expect(!fine.chunks.contains(world_mod.chunkKey(3, -4)));
    try std.testing.expect(st.lods[0].chunks.contains(world_mod.chunkKey(0, -2)));
    try std.testing.expect(st.lods[1].chunks.count() > 0);
    // Terrain actually generated (bedrock everywhere).
    try std.testing.expect(fine.get(32, 0, -201) != 0);

    var snap_a = try snapshot(allocator, &fine);
    defer snap_a.deinit();
    var snap_a1 = try snapshot(allocator, &st.lods[0]);
    defer snap_a1.deinit();

    // Budgeted streaming from scratch reaches the same state.
    var fine2 = try World.init(allocator, null, 96, null);
    defer fine2.deinit();
    var st2 = try Streamer.init(allocator, &fine2, 7, &lod_dists, 448, .{}, 200, false);
    defer st2.deinit();
    while (try st2.updateBudgeted(cam_a, 200)) {}
    var snap_b = try snapshot(allocator, &fine2);
    defer snap_b.deinit();
    try expectSnapshotsEqual(&snap_a, &snap_b);

    // Excursion far away unloads the A disc; returning regenerates it
    // identically (materials strictly; light up to ties).
    try st.runToCompletion(cam_b);
    try std.testing.expect(!fine.chunks.contains(world_mod.chunkKey(0, -4)));
    try st.runToCompletion(cam_a);
    var snap_a2 = try snapshot(allocator, &fine);
    defer snap_a2.deinit();
    var snap_a1b = try snapshot(allocator, &st.lods[0]);
    defer snap_a1b.deinit();
    try expectSnapshotsEqual(&snap_a, &snap_a2);
    try expectSnapshotsEqual(&snap_a1, &snap_a1b);
}

test "streamer: forceResident generates the player chunk synchronously" {
    const allocator = std.testing.allocator;
    const lod_dists = [_]f32{ 96, 192 };
    var fine = try World.init(allocator, null, 96, null);
    defer fine.deinit();
    var st = try Streamer.init(allocator, &fine, 7, &lod_dists, 448, .{}, 1, false);
    defer st.deinit();
    try std.testing.expect(!fine.chunks.contains(world_mod.chunkKey(-1, 0)));
    try st.forceResident(-5, 3, 1, 4); // straddles chunks (-1,0) and (0,0)
    try std.testing.expect(fine.chunks.contains(world_mod.chunkKey(-1, 0)));
    try std.testing.expect(fine.chunks.contains(world_mod.chunkKey(0, 0)));
    try std.testing.expect(fine.get(-1, 0, 3) != 0); // bedrock
}

test "streamer: edited fine chunk unload re-synthesizes the coarse tiers" {
    const allocator = std.testing.allocator;
    const lod_dists = [_]f32{ 96, 192 };
    const cam_a: Camera = .{ .x = 32.5, .y = 60, .z = -200.5, .yaw = 0 };
    // Fine chunk (0,-3) unloads past unload_r = 3 fine chunks; its
    // coarse chunks stay resident (their worlds' discs reach farther
    // in fine units), so the repair's effect is observable there.
    const cam_b: Camera = .{ .x = 32.5 + 4 * 64, .y = 60, .z = -200.5, .yaw = 0 };

    var fine = try World.init(allocator, null, 96, null);
    defer fine.deinit();
    var st = try Streamer.init(allocator, &fine, 7, &lod_dists, 448, .{}, 100000, false);
    defer st.deinit();
    try st.runToCompletion(cam_a);

    // Crystal at (40, -190), fine chunk (0, -3), placed above every
    // fine column of its 4x4 footprint so it tops both coarse tiers.
    const ctx = terrain.Ctx.init(7, 96);
    const px: i32 = 40;
    const pz: i32 = -190;
    var top: u16 = 0;
    for (0..4) |dx| {
        for (0..4) |dz| {
            top = @max(top, terrain.heightAt(&ctx, px - 2 + @as(i32, @intCast(dx)), pz - 2 + @as(i32, @intCast(dz))));
        }
    }
    const py: i32 = @as(i32, top) + 1;
    const c1x = @divFloor(px, 2);
    const c1z = @divFloor(pz, 2);
    const c2x = @divFloor(px, 4);
    const c2z = @divFloor(pz, 4);
    const col1 = st.lods[0].columnAt(c1x, c1z).?;
    const col2 = st.lods[1].columnAt(c2x, c2z).?;
    const before1 = try std.testing.allocator.dupe(world_mod.MatRun, col1.runs);
    defer allocator.free(before1);
    const before2 = try std.testing.allocator.dupe(world_mod.MatRun, col2.runs);
    defer allocator.free(before2);

    try fine.set(px, py, pz, 9);
    try st.onEdit(fine.takeDirty().?);
    // The edit propagated to both coarse tiers (the crystal is the
    // highest solid voxel of its coarse columns).
    try std.testing.expectEqual(@as(u8, 9), st.lods[0].get(c1x, @divFloor(py, 2), c1z));
    try std.testing.expectEqual(@as(u8, 9), st.lods[1].get(c2x, @divFloor(py, 4), c2z));

    // Move far away: the fine chunk unloads, the repairs restore
    // generation content on the coarse tiers.
    try st.runToCompletion(cam_b);
    try std.testing.expect(!fine.chunks.contains(world_mod.chunkKey(0, -3)));
    try std.testing.expectEqual(@as(usize, 0), st.repairs.items.len);
    const after1 = st.lods[0].columnAt(c1x, c1z).?;
    const after2 = st.lods[1].columnAt(c2x, c2z).?;
    try std.testing.expectEqual(before1.len, after1.runs.len);
    for (before1, after1.runs) |ra, rb| try std.testing.expectEqual(ra, rb);
    try std.testing.expectEqual(before2.len, after2.runs.len);
    for (before2, after2.runs) |ra, rb| try std.testing.expectEqual(ra, rb);
    // The edit's cyan light is gone from the coarse tier too.
    for (0..st.lods[0].h) |y| {
        try std.testing.expect(lighting.sampleLight(after1, @intCast(y)).color_id != 9);
    }
}
