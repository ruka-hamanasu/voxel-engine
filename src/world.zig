const std = @import("std");

/// emissive: 0 = normal shaded material; nonzero = emissive intensity
/// (rendered full-bright, seeds the milestone-9 light flood).
pub const PaletteEntry = struct {
    rgb: u32,
    emissive: u8,
};

pub const default_palette = [_]PaletteEntry{
    .{ .rgb = 0x000000, .emissive = 0 }, // 0: air (unused)
    .{ .rgb = 0x8c8c91, .emissive = 0 }, // 1: stone
    .{ .rgb = 0xa5503c, .emissive = 0 }, // 2: brick
    .{ .rgb = 0xc8b482, .emissive = 0 }, // 3: sand
    .{ .rgb = 0x5aa050, .emissive = 0 }, // 4: grass
    .{ .rgb = 0x506ec8, .emissive = 0 }, // 5: blue
    .{ .rgb = 0xdcdcd7, .emissive = 0 }, // 6: marble
    .{ .rgb = 0x7d5a38, .emissive = 0 }, // 7: dirt
    .{ .rgb = 0x4a4a52, .emissive = 0 }, // 8: dark stone
    .{ .rgb = 0x46e6e6, .emissive = 255 }, // 9: crystal cyan
    .{ .rgb = 0xe646c8, .emissive = 255 }, // 10: crystal magenta
    .{ .rgb = 0xf0a53c, .emissive = 255 }, // 11: crystal amber
};

/// Runtime-mutable (milestone 10 animates entries); call
/// render.rebuildShadeLut() after changing it.
pub var palette = default_palette;

pub const MatRun = struct {
    count: u8,
    palette_id: u8,
};

pub const LightRun = struct {
    count: u8,
    color_id: u8,
    intensity: u8,
    /// lighting.Dir of the brightest flood wave's arrival (direction
    /// the light flowed into the cell); u8 to keep the struct
    /// independent of lighting.zig. Runs split when it changes.
    dir: u8,
};

/// Short run streams live directly in the column: runs.len <= cap
/// implies runs.ptr == &inline_runs. 8 runs x 2 B keeps Column at
/// exactly 64 B (one cache line), so the far-field march touches a
/// single line per column instead of chasing a runs pointer into
/// scattered allocations.
pub const inline_runs_cap = 8;

pub const Column = struct {
    runs: []MatRun,
    /// Explicit light deviations; null = default derived from the
    /// material runs (full sky light above the topmost solid run, dark
    /// below). When present, the runs cover y in
    /// (light_base_y - total_count, light_base_y] top-to-bottom; the
    /// default applies outside that span. Freed back to null when it
    /// holds no deviations.
    light: ?[]LightRun = null,
    light_base_y: u16 = 0,
    /// Bottom of the light runs' coverage (light_base_y - total + 1);
    /// cached by lighting.encodeColumns so the renderer's per-cell
    /// zipper setup never re-sums run counts. Meaningless when light
    /// is null.
    light_lo: u16 = 0,
    /// Cached topmost solid y (no_solid when fully air), maintained by
    /// setRange/setColumnRuns so the renderer's analytic sky light
    /// (milestone 11) never rescans runs per cell.
    top_solid_y: u16 = no_solid,
    /// Bit y = voxel y solid; valid only when h <= 64 (World.masks_ok),
    /// else zero. Lets AO neighbor queries test solidity without a run
    /// scan. Maintained alongside the runs by setRange/setColumnRuns.
    solid_mask: u64 = 0,
    inline_runs: [inline_runs_cap]MatRun = undefined,
};

pub const no_solid = std.math.maxInt(u16);

/// Chunked storage (plans/STREAMING.md phase 1): a chunk is 64x64 columns —
/// one 256 KB 64-aligned block — plus its own 8x8-cell macro_max grid
/// (64 columns / 8 = 8 cells per side, so macro cells never straddle
/// chunks). Per-column light runs stay per-column heap allocations.
pub const chunk_w = 64;
const chunk_macro_w = chunk_w / 8;

pub const Chunk = struct {
    columns: [chunk_w * chunk_w]Column align(64),
    macro_max: [chunk_macro_w * chunk_macro_w]u16,
};

/// Hash-map key for the chunk at chunk coords (cx, cz): packed i32
/// pair. Chunk coord of world column x is x >> 6 (arithmetic shift =
/// floorDiv for the power-of-two size), so negative coords work.
pub fn chunkKey(cx: i32, cz: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(cx))) << 32) | @as(u32, @bitCast(cz));
}

/// Chunk map with a multiplicative-mix hash: the render march pays a
/// lookup per cell, and Wyhash (AutoHashMap's default) cost ~20% of
/// the frame. One multiply mixes the small-int coords into the high
/// bits the map's capacity mask uses.
const ChunkMap = std.HashMap(u64, *Chunk, struct {
    pub fn hash(_: @This(), k: u64) u64 {
        return k *% 0x9E3779B97F4A7C15;
    }
    pub fn eql(_: @This(), a: u64, b: u64) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);

/// Rebuild a column's solidity bitmask from its material runs.
/// Caller guarantees h <= 64.
fn computeMask(runs: []const MatRun, h: usize) u64 {
    var mask: u64 = 0;
    var hi: i64 = @intCast(h);
    for (runs) |run| {
        hi -= run.count;
        if (run.palette_id != 0) {
            const lo: u6 = @intCast(hi);
            const ones: u64 = if (run.count >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(run.count)) - 1;
            mask |= ones << lo;
        }
    }
    return mask;
}

/// Topmost solid voxel y in the column, or null when fully air.
pub fn topSolidY(col: *const Column, h: i32) ?i32 {
    var hi: i32 = h - 1;
    for (col.runs) |run| {
        if (run.palette_id != 0) return hi;
        hi -= run.count;
    }
    return null;
}

/// Cursor walking a top-to-bottom run stream; generic over the run
/// type so material and light streams share the walk logic. mat() and
/// peek() are material-specific (0 = air).
pub fn CursorFor(comptime R: type) type {
    return struct {
        const Self = @This();

        runs: []const R,
        idx: usize,
        lo: i32,
        hi: i32,

        pub fn init(runs: []const R, h: i32, y: i32) Self {
            var idx: usize = 0;
            var hi: i32 = h - 1;
            var lo: i32 = hi - @as(i32, runs[0].count) + 1;
            while (y < lo) {
                idx += 1;
                hi = lo - 1;
                lo = hi - @as(i32, runs[idx].count) + 1;
            }
            return .{ .runs = runs, .idx = idx, .lo = lo, .hi = hi };
        }

        pub fn mat(self: *const Self) u8 {
            if (R != MatRun) @compileError("mat() requires a MatRun cursor");
            return self.runs[self.idx].palette_id;
        }

        /// Material at y without moving the cursor; y must be within one
        /// voxel of the current run ([lo-1, hi+1], i.e. y +/- 1 queries land
        /// on adjacent runs, which is all AO neighbor sampling needs).
        /// Out-of-world heights read as air, matching World.get.
        pub fn peek(self: *const Self, y: i32) u8 {
            if (R != MatRun) @compileError("peek() requires a MatRun cursor");
            std.debug.assert(y >= self.lo - 1 and y <= self.hi + 1);
            if (y >= self.lo and y <= self.hi) return self.runs[self.idx].palette_id;
            if (y > self.hi) {
                if (self.idx == 0) return 0;
                return self.runs[self.idx - 1].palette_id;
            }
            if (self.idx + 1 >= self.runs.len) return 0;
            return self.runs[self.idx + 1].palette_id;
        }

        pub fn up(self: *Self) void {
            self.idx -= 1;
            self.lo = self.hi + 1;
            self.hi = self.lo + @as(i32, self.runs[self.idx].count) - 1;
        }

        pub fn down(self: *Self) void {
            self.idx += 1;
            self.hi = self.lo - 1;
            self.lo = self.hi - @as(i32, self.runs[self.idx].count) + 1;
        }
    };
}

pub const RunCursor = CursorFor(MatRun);
pub const LightCursor = CursorFor(LightRun);

/// Half-open edit/extent box. Signed (i32) so unbounded-world chunk
/// boxes and dirty regions at negative coords work (plans/STREAMING.md
/// phase 2); y is always within [0, h] after clamping.
pub const Region = struct {
    x0: i32,
    y0: i32,
    z0: i32,
    x1: i32,
    y1: i32,
    z1: i32,
};

pub const World = struct {
    /// XZ bounds; null = unbounded (both or neither). Bounded worlds
    /// (all test worlds; the default world until the phase-2 streamer)
    /// hold every covering chunk resident from init.
    w: ?usize,
    h: usize,
    d: ?usize,
    chunks: ChunkMap,
    allocator: std.mem.Allocator,
    /// Column.solid_mask is maintained only when h <= 64.
    masks_ok: bool,
    /// The 8x8-group macro_max grids are valid when h fits the u16
    /// top_solid_y cache (h <= 65535), i.e. always.
    macro_ok: bool,
    /// Bounding box (half-open) of everything touched by set/fillBox
    /// since the last takeDirty; consumed by milestone 10's relight.
    dirty: ?Region = null,
/// Last-lookup memo for the hot accessor path: the render march
/// and its AO sampling issue several consecutive lookups per chunk.
/// Mutated through the const accessors (World instances are always
/// owned mutably). Sharded one slot per render-pool participant
/// (plans/DISTANCE.md D1) — threads render concurrently, each using
/// its own slot via memo_slot, so shards never race. Slot padding
/// keeps one thread's shard writes off the others' cache lines.
memo: [memo_slots]Memo = @splat(.{}),

/// Render-pool participant index selecting the memo shard: the main
/// thread keeps 0; pool workers set their own at spawn (pool.zig).
pub threadlocal var memo_slot: usize = 0;

/// Memo shard count, sized to the D1 render pool (main + 3 workers).
pub const memo_slots = 4;

/// Padded to its own cache line: concurrent render threads hold
/// adjacent shards, and a shard write (chunk crossing) must not
/// invalidate the other participants' lines.
const Memo = struct {
    key: u64 = 0,
    chunk: ?*Chunk = null,
    _pad: [48]u8 = @splat(0),
};

    fn markDirty(self: *World, r: Region) void {
        if (self.dirty) |*cur| {
            cur.* = .{
                .x0 = @min(cur.x0, r.x0),
                .y0 = @min(cur.y0, r.y0),
                .z0 = @min(cur.z0, r.z0),
                .x1 = @max(cur.x1, r.x1),
                .y1 = @max(cur.y1, r.y1),
                .z1 = @max(cur.z1, r.z1),
            };
        } else {
            self.dirty = r;
        }
    }

    pub fn takeDirty(self: *World) ?Region {
        const r = self.dirty;
        self.dirty = null;
        return r;
    }

    /// Install a freshly-built run stream on a column: short streams
    /// are copied into the inline buffer (and the caller's allocation
    /// freed), long streams are adopted. Frees the previous stream
    /// when it was out-of-line.
    fn installRuns(self: *World, col: *Column, runs: []MatRun) void {
        const old = col.runs;
        if (runs.len <= inline_runs_cap) {
            @memcpy(col.inline_runs[0..runs.len], runs);
            self.allocator.free(runs);
            col.runs = col.inline_runs[0..runs.len];
        } else {
            col.runs = runs;
        }
        if (old.len > inline_runs_cap) self.allocator.free(old);
    }

    pub fn init(allocator: std.mem.Allocator, w: ?usize, h: usize, d: ?usize) !World {
        std.debug.assert((w == null) == (d == null)); // both or neither
        if (w) |bw| {
            // lighting.zig's sparse scratch keys cells by a u32 voxel index.
            std.debug.assert(@as(u64, bw) * d.? * h < std.math.maxInt(u32));
        }
        std.debug.assert(h <= std.math.maxInt(u16)); // u16 y caches
        var world: World = .{
            .w = w,
            .h = h,
            .d = d,
            .chunks = ChunkMap.init(allocator),
            .allocator = allocator,
            .masks_ok = h <= 64,
            .macro_ok = h <= std.math.maxInt(u16),
        };
        errdefer world.deinit();
        if (w) |bw| {
            const bd = d.?;
            var cx: i32 = 0;
            while (@as(usize, @intCast(cx)) * chunk_w < bw) : (cx += 1) {
                var cz: i32 = 0;
                while (@as(usize, @intCast(cz)) * chunk_w < bd) : (cz += 1) {
                    _ = try world.ensureChunk(cx, cz);
                }
            }
        }
        return world;
    }

    pub fn deinit(self: *World) void {
        var it = self.chunks.valueIterator();
        while (it.next()) |chunk| self.destroyChunk(chunk.*);
        self.chunks.deinit();
    }

    inline fn inBounds(self: *const World, x: i32, z: i32) bool {
        if (self.w) |w| {
            if (x < 0 or @as(u64, @intCast(x)) >= w) return false;
        }
        if (self.d) |d| {
            if (z < 0 or @as(u64, @intCast(z)) >= d) return false;
        }
        return true;
    }

    /// Allocate and register the chunk at (cx, cz) with uniform-air
    /// columns (inline runs, no per-column alloc unless h > 2040).
    /// Idempotent: returns the existing chunk when already resident.
    pub fn ensureChunk(self: *World, cx: i32, cz: i32) !*Chunk {
        if (self.w) |w| std.debug.assert(cx >= 0 and @as(u64, @intCast(cx)) * chunk_w < w);
        if (self.d) |d| std.debug.assert(cz >= 0 and @as(u64, @intCast(cz)) * chunk_w < d);
        const key = chunkKey(cx, cz);
        const gop = try self.chunks.getOrPut(key);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.chunks.remove(key);
        const chunk = try self.allocator.create(Chunk);
        var initialized: usize = 0;
        errdefer {
            for (chunk.columns[0..initialized]) |*col| {
                if (col.runs.len > inline_runs_cap) self.allocator.free(col.runs);
            }
            self.allocator.destroy(chunk);
        }
        for (&chunk.columns, 0..) |*col, i| {
            col.* = .{ .runs = &.{} };
            try self.setAirRuns(col);
            initialized = i + 1;
        }
        @memset(chunk.macro_max[0..], 0);
        gop.value_ptr.* = chunk;
        return chunk;
    }

    /// Remove and free the chunk at (cx, cz); no-op when not resident.
    pub fn freeChunk(self: *World, cx: i32, cz: i32) void {
        const kv = self.chunks.fetchRemove(chunkKey(cx, cz)) orelse return;
        for (&self.memo) |*m| {
            if (m.chunk == kv.value) m.chunk = null;
        }
        self.destroyChunk(kv.value);
    }

    fn destroyChunk(self: *World, chunk: *Chunk) void {
        for (&chunk.columns) |*col| {
            if (col.runs.len > inline_runs_cap) self.allocator.free(col.runs);
            if (col.light) |l| self.allocator.free(l);
        }
        self.allocator.destroy(chunk);
    }

    /// Blank a chunk's materials to uniform air PRESERVING the light
    /// runs (unloadChunk's relight needs the stored flood to find the
    /// orphaned chains). Recomputes the caches and zeroes the macro grid.
    pub fn blankChunk(self: *World, chunk: *Chunk) !void {
        for (&chunk.columns) |*col| {
            try self.setAirRuns(col);
            col.top_solid_y = no_solid;
            col.solid_mask = 0;
        }
        @memset(chunk.macro_max[0..], 0);
    }

    /// Install uniform-air material runs on one column; inline unless
    /// h > 2040. Light runs are the caller's business.
    fn setAirRuns(self: *World, col: *Column) !void {
        const n = (self.h + 254) / 255;
        var heap: []MatRun = &.{};
        if (n > inline_runs_cap) heap = try allocUniformRuns(self.allocator, self.h, 0);
        if (col.runs.len > inline_runs_cap) self.allocator.free(col.runs);
        if (n > inline_runs_cap) {
            col.runs = heap;
        } else {
            var remaining = self.h;
            for (col.inline_runs[0..n]) |*run| {
                const count: u8 = @intCast(@min(remaining, 255));
                run.* = .{ .count = count, .palette_id = 0 };
                remaining -= count;
            }
            col.runs = col.inline_runs[0..n];
        }
    }

    /// Chunk holding world column (x, z), or null when not resident.
    /// Bounds are NOT checked here (the callers do that); the memo is
    /// keyed on the chunk coords, so out-of-bounds negatives stay safe.
    inline fn chunkAt(self: *const World, x: i32, z: i32) ?*Chunk {
        const key = chunkKey(x >> 6, z >> 6);
        const m = &self.memo[memo_slot];
        if (m.chunk) |lc| {
            if (m.key == key) return lc;
        }
        const chunk = self.chunks.get(key) orelse return null;
        const mut: *World = @constCast(self);
        mut.memo[memo_slot].key = key;
        mut.memo[memo_slot].chunk = chunk;
        return chunk;
    }

    /// Recompute one 8x8 group's max top_solid_y after a column change.
    fn updateMacro(self: *World, x: i32, z: i32) void {
        if (!self.macro_ok) return;
        const chunk = self.chunkAt(x, z).?;
        const lx = (@as(usize, @intCast(x & 63)) >> 3) << 3;
        const lz = (@as(usize, @intCast(z & 63)) >> 3) << 3;
        var m: u16 = 0;
        for (lx..lx + 8) |cx| {
            for (lz..lz + 8) |cz| {
                const top = chunk.columns[cx * chunk_w + cz].top_solid_y;
                if (top != no_solid and top > m) m = top;
            }
        }
        chunk.macro_max[(lz >> 3) * chunk_macro_w + (lx >> 3)] = m;
    }

    /// True when (x, z) is in bounds but its chunk isn't resident: a
    /// still-generating hole (vs. out of bounds, genuinely empty).
    pub inline fn cellMissing(self: *const World, x: i32, z: i32) bool {
        return self.inBounds(x, z) and self.chunkAt(x, z) == null;
    }

    /// Max solid y of the 8x8 group holding (x, z); null when out of
    /// bounds or the chunk is not resident (all air: the march may
    /// always skip such cells). Meaningful only when macro_ok.
    pub inline fn macroMax(self: *const World, x: i32, z: i32) ?u16 {
        if (!self.inBounds(x, z)) return null;
        const chunk = self.chunkAt(x, z) orelse return null;
        return chunk.macro_max[@as(usize, @intCast((z & 63) >> 3)) * chunk_macro_w + @as(usize, @intCast((x & 63) >> 3))];
    }

    fn allocUniformRuns(allocator: std.mem.Allocator, h: usize, mat: u8) ![]MatRun {
        const n = (h + 254) / 255;
        const runs = try allocator.alloc(MatRun, n);
        var remaining: usize = h;
        for (runs) |*run| {
            const count: u8 = @intCast(@min(remaining, 255));
            run.* = .{ .count = count, .palette_id = mat };
            remaining -= count;
        }
        return runs;
    }

    pub inline fn columnAt(self: *const World, x: i32, z: i32) ?*const Column {
        if (!self.inBounds(x, z)) return null;
        const chunk = self.chunkAt(x, z) orelse return null;
        return &chunk.columns[@as(usize, @intCast(x & 63)) * chunk_w + @as(usize, @intCast(z & 63))];
    }

    /// Mutable counterpart to columnAt; the one write path into columns,
    /// so chunk residency (plans/STREAMING.md) has a single indirection point.
    pub inline fn columnAtMut(self: *World, x: i32, z: i32) ?*Column {
        if (!self.inBounds(x, z)) return null;
        const chunk = self.chunkAt(x, z) orelse return null;
        return &chunk.columns[@as(usize, @intCast(x & 63)) * chunk_w + @as(usize, @intCast(z & 63))];
    }

    pub fn setColumnRuns(self: *World, x: i32, z: i32, runs: []MatRun) void {
        const col = self.columnAtMut(x, z).?;
        if (col.light) |l| self.allocator.free(l);
        col.light = null;
        col.light_base_y = 0;
        col.light_lo = 0;
        self.installRuns(col, runs);
        col.top_solid_y = if (topSolidY(col, @intCast(self.h))) |y| @intCast(y) else no_solid;
        if (self.masks_ok) col.solid_mask = computeMask(col.runs, self.h);
        self.updateMacro(x, z);
    }

    /// setColumnRuns variant that PRESERVES the light runs: chunk
    /// loads write terrain over an air column whose stored flood (the
    /// pre-gen field) the following relight's stale-clear pass still
    /// needs to find the chains detouring through the chunk
    /// (chunk.loadChunk). Transient state: the relight re-encodes it.
    pub fn setColumnRunsKeepLight(self: *World, x: i32, z: i32, runs: []MatRun) void {
        const col = self.columnAtMut(x, z).?;
        self.installRuns(col, runs);
        col.top_solid_y = if (topSolidY(col, @intCast(self.h))) |y| @intCast(y) else no_solid;
        if (self.masks_ok) col.solid_mask = computeMask(col.runs, self.h);
        self.updateMacro(x, z);
    }

    /// Solidity at (x, y, z) without decoding materials: a single bit
    /// test when masks_ok, run scan otherwise. Matches get(...) != 0.
    pub inline fn solidAt(self: *const World, x: i32, y: i32, z: i32) bool {
        if (y < 0) return false;
        const uy: usize = @intCast(y);
        if (uy >= self.h) return false;
        if (!self.masks_ok) return self.get(x, y, z) != 0;
        const col = self.columnAt(x, z) orelse return false;
        return (col.solid_mask >> @intCast(uy)) & 1 != 0;
    }

    pub inline fn get(self: *const World, x: i32, y: i32, z: i32) u8 {
        if (y < 0) return 0;
        const uy: usize = @intCast(y);
        if (uy >= self.h) return 0;
        const col = self.columnAt(x, z) orelse return 0;
        var depth: usize = self.h - 1 - uy;
        for (col.runs) |run| {
            if (depth < run.count) return run.palette_id;
            depth -= run.count;
        }
        return 0;
    }

    /// Material at (x, y, z), or null when the column's chunk is not
    /// resident. The lighting flood confines propagation to resident
    /// cells (plans/STREAMING.md phase 2): no stored chain can then route
    /// through an unloaded chunk, so a chunk load invalidates no
    /// existing light and floods as a pure add pass.
    pub inline fn getResident(self: *const World, x: i32, y: i32, z: i32) ?u8 {
        const col = self.columnAt(x, z) orelse return null;
        if (y < 0) return 0;
        const uy: usize = @intCast(y);
        if (uy >= self.h) return 0;
        var depth: usize = self.h - 1 - uy;
        for (col.runs) |run| {
            if (depth < run.count) return run.palette_id;
            depth -= run.count;
        }
        return 0;
    }

    /// Topmost solid y within [y_lo, y_hi], or null when the column has
    /// no solid voxel in the interval. Pure interval-overlap scan over
    /// the material runs; exists for the sun shadow march (milestone
    /// 12). The renderer deliberately does NOT call it as a per-cell
    /// fast reject — that cost ~5% in double run scans.
    pub fn firstSolidInColumn(self: *const World, ix: i32, iz: i32, y_lo: i32, y_hi: i32) ?i32 {
        const col = self.columnAt(ix, iz) orelse return null;
        var hi: i32 = @intCast(self.h - 1);
        for (col.runs) |run| {
            const lo = hi - @as(i32, run.count) + 1;
            if (run.palette_id != 0 and lo <= y_hi and hi >= y_lo)
                return @min(hi, y_hi);
            hi = lo - 1;
        }
        return null;
    }

    /// Bottommost solid y within [y_lo, y_hi], or null. Counterpart to
    /// firstSolidInColumn for upward pick rays (milestone 10): an
    /// ascending ray meets the interval's lowest solid first.
    pub fn lastSolidInColumn(self: *const World, ix: i32, iz: i32, y_lo: i32, y_hi: i32) ?i32 {
        const col = self.columnAt(ix, iz) orelse return null;
        var result: ?i32 = null;
        var hi: i32 = @intCast(self.h - 1);
        for (col.runs) |run| {
            const lo = hi - @as(i32, run.count) + 1;
            if (run.palette_id != 0 and lo <= y_hi and hi >= y_lo)
                result = @max(lo, y_lo);
            hi = lo - 1;
        }
        return result;
    }

    /// Returns false (no-op) when the column's chunk is not resident.
    fn setRange(self: *World, x: i32, z: i32, d0: usize, d1: usize, mat: u8) !bool {
        const col = self.columnAtMut(x, z) orelse return false;
        var out: std.ArrayList(MatRun) = .empty;
        errdefer out.deinit(self.allocator);

        var pos: usize = 0;
        for (col.runs) |run| {
            const start = pos;
            const end = pos + run.count;
            pos = end;
            try appendRun(&out, self.allocator, run.palette_id, @min(end, d0) -| start);
            try appendRun(&out, self.allocator, mat, @min(end, d1) -| @max(start, d0));
            try appendRun(&out, self.allocator, run.palette_id, end -| @max(start, d1));
        }

        const new_runs = try out.toOwnedSlice(self.allocator);
        self.installRuns(col, new_runs);
        col.top_solid_y = if (topSolidY(col, @intCast(self.h))) |y| @intCast(y) else no_solid;
        if (self.masks_ok) col.solid_mask = computeMask(col.runs, self.h);
        self.updateMacro(x, z);
        return true;
    }

    fn appendRun(out: *std.ArrayList(MatRun), allocator: std.mem.Allocator, mat: u8, count: usize) !void {
        var remaining = count;
        while (remaining > 0) {
            if (out.items.len > 0) {
                const last = &out.items[out.items.len - 1];
                if (last.palette_id == mat and last.count < 255) {
                    const add: u8 = @intCast(@min(remaining, 255 - @as(usize, last.count)));
                    last.count += add;
                    remaining -= add;
                    continue;
                }
            }
            const chunk: u8 = @intCast(@min(remaining, 255));
            try out.append(allocator, .{ .count = chunk, .palette_id = mat });
            remaining -= chunk;
        }
    }

    pub fn set(self: *World, x: i32, y: i32, z: i32, mat: u8) !void {
        const xc = if (self.w) |w| std.math.clamp(x, 0, @as(i32, @intCast(w)) - 1) else x;
        const yc = std.math.clamp(y, 0, @as(i32, @intCast(self.h)) - 1);
        const zc = if (self.d) |d| std.math.clamp(z, 0, @as(i32, @intCast(d)) - 1) else z;
        const depth = self.h - 1 - @as(usize, @intCast(yc));
        if (!try self.setRange(xc, zc, depth, depth + 1, mat)) return;
        self.markDirty(.{ .x0 = xc, .y0 = yc, .z0 = zc, .x1 = xc + 1, .y1 = yc + 1, .z1 = zc + 1 });
    }

    pub fn fillBox(self: *World, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, mat: u8) !void {
        const hi: i32 = @intCast(self.h);
        const xa = if (self.w) |w| std.math.clamp(x0, 0, @as(i32, @intCast(w))) else x0;
        const ya = std.math.clamp(y0, 0, hi);
        const za = if (self.d) |d| std.math.clamp(z0, 0, @as(i32, @intCast(d))) else z0;
        const xb = if (self.w) |w| std.math.clamp(x1, 0, @as(i32, @intCast(w))) else x1;
        const yb = std.math.clamp(y1, 0, hi);
        const zb = if (self.d) |d| std.math.clamp(z1, 0, @as(i32, @intCast(d))) else z1;
        if (xa >= xb or ya >= yb or za >= zb) return;
        var any = false;
        var x = xa;
        while (x < xb) : (x += 1) {
            var z = za;
            while (z < zb) : (z += 1) {
                any = try self.setRange(x, z, self.h - @as(usize, @intCast(yb)), self.h - @as(usize, @intCast(ya)), mat) or any;
            }
        }
        if (any) self.markDirty(.{ .x0 = xa, .y0 = ya, .z0 = za, .x1 = xb, .y1 = yb, .z1 = zb });
    }

    pub fn buildDemoRoom(allocator: std.mem.Allocator) !World {
        var world = try World.init(allocator, 32, 16, 32);
        errdefer world.deinit();
        try world.fillBox(4, 0, 4, 28, 1, 28, 1); // floor
        try world.fillBox(4, 1, 4, 5, 10, 28, 2); // x=4 wall
        try world.fillBox(27, 1, 4, 28, 10, 28, 2); // x=27 wall
        try world.fillBox(4, 1, 4, 28, 10, 5, 2); // z=4 wall
        try world.fillBox(4, 1, 27, 28, 10, 28, 2); // z=27 wall
        try world.fillBox(19, 1, 27, 23, 5, 28, 0); // arch opening, lower
        try world.fillBox(20, 5, 27, 22, 7, 28, 0); // arch opening, stepped top
        try world.fillBox(11, 1, 15, 14, 9, 17, 6); // marble pillar
        try world.fillBox(8, 1, 20, 10, 3, 22, 5); // blue block
        try world.fillBox(21, 1, 8, 23, 2, 10, 4); // green block
        try world.fillBox(9, 1, 9, 10, 2, 10, 3); // sand block
        return world;
    }
};

fn expectCoverage(world: *const World, x: i32, z: i32) !void {
    const col = world.columnAt(x, z).?;
    var total: usize = 0;
    for (col.runs, 0..) |run, i| {
        try std.testing.expect(run.count > 0);
        if (i > 0) try std.testing.expect(run.palette_id != col.runs[i - 1].palette_id or col.runs[i - 1].count == 255);
        total += run.count;
    }
    try std.testing.expectEqual(world.h, total);
    if (col.light) |runs| {
        var ltotal: usize = 0;
        for (runs, 0..) |run, i| {
            try std.testing.expect(run.count > 0);
            if (i > 0) try std.testing.expect(
                run.color_id != runs[i - 1].color_id or run.intensity != runs[i - 1].intensity or runs[i - 1].count == 255,
            );
            ltotal += run.count;
        }
        try std.testing.expect(ltotal <= world.h);
        try std.testing.expect(col.light_base_y < world.h);
    }
}

test "fillBox and get" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    try world.fillBox(1, 1, 1, 3, 3, 3, 5);
    try std.testing.expectEqual(5, world.get(2, 2, 2));
    try std.testing.expectEqual(5, world.get(1, 1, 1));
    try std.testing.expectEqual(0, world.get(3, 2, 2));
    try std.testing.expectEqual(0, world.get(-1, 2, 2));
    try std.testing.expectEqual(0, world.get(2, 100, 2));
    try world.fillBox(2, 2, 2, 3, 3, 3, 0);
    try std.testing.expectEqual(0, world.get(2, 2, 2));
    for (0..8) |x| {
        for (0..8) |z| {
            try expectCoverage(&world, @intCast(x), @intCast(z));
        }
    }
}

test "set splits and merges runs" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    const col = world.columnAtMut(2, 2).?;
    try std.testing.expectEqual(1, col.runs.len);

    try world.set(2, 2, 2, 5);
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 5, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(MatRun{ .count = 1, .palette_id = 5 }, col.runs[1]);
    try std.testing.expectEqual(MatRun{ .count = 2, .palette_id = 0 }, col.runs[2]);

    try world.set(2, 3, 2, 5);
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 4, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(MatRun{ .count = 2, .palette_id = 5 }, col.runs[1]);

    try world.set(2, 2, 2, 0);
    try world.set(2, 3, 2, 0);
    try std.testing.expectEqual(1, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 8, .palette_id = 0 }, col.runs[0]);
}

test "runs split at 255" {
    var world = try World.init(std.testing.allocator, 1, 600, 1);
    defer world.deinit();
    const col = world.columnAtMut(0, 0).?;
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(255, col.runs[0].count);
    try std.testing.expectEqual(255, col.runs[1].count);
    try std.testing.expectEqual(90, col.runs[2].count);

    try world.fillBox(0, 0, 0, 1, 600, 1, 7);
    try std.testing.expectEqual(3, col.runs.len);
    for (col.runs) |run| try std.testing.expectEqual(7, run.palette_id);
    try expectCoverage(&world, 0, 0);

    try world.set(0, 255, 0, 3);
    try std.testing.expectEqual(3, world.get(0, 255, 0));
    try expectCoverage(&world, 0, 0);
}

test "set clamps out-of-bounds and edits record dirty extents" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    try std.testing.expectEqual(null, world.dirty);

    try world.set(20, 20, 20, 5);
    try std.testing.expectEqual(5, world.get(7, 7, 7));
    try std.testing.expectEqual(Region{ .x0 = 7, .y0 = 7, .z0 = 7, .x1 = 8, .y1 = 8, .z1 = 8 }, world.dirty.?);

    try world.fillBox(1, 2, 3, 4, 5, 6, 7);
    try std.testing.expectEqual(Region{ .x0 = 1, .y0 = 2, .z0 = 3, .x1 = 8, .y1 = 8, .z1 = 8 }, world.dirty.?);

    const r = world.takeDirty().?;
    try std.testing.expectEqual(@as(i32, 1), r.x0);
    try std.testing.expectEqual(null, world.dirty);
    try std.testing.expectEqual(null, world.takeDirty());
}

test "topSolidY finds the topmost solid voxel and the cache tracks edits" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    const col = world.columnAtMut(0, 0).?;
    try std.testing.expectEqual(null, topSolidY(col, 16));
    try std.testing.expectEqual(no_solid, col.top_solid_y);
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    try std.testing.expectEqual(6, topSolidY(col, 16));
    try std.testing.expectEqual(6, col.top_solid_y);
    try world.set(0, 12, 0, 4);
    try std.testing.expectEqual(12, topSolidY(col, 16));
    try std.testing.expectEqual(12, col.top_solid_y);
    try world.set(0, 12, 0, 0);
    try std.testing.expectEqual(6, col.top_solid_y);
    try world.fillBox(0, 0, 0, 1, 16, 1, 0);
    try std.testing.expectEqual(no_solid, col.top_solid_y);
}

test "light stream storage lifecycle" {
    const allocator = std.testing.allocator;
    var world = try World.init(allocator, 2, 16, 2);
    defer world.deinit();
    for (0..2) |x| {
        for (0..2) |z| {
            try std.testing.expect(world.columnAt(@intCast(x), @intCast(z)).?.light == null);
        }
    }

    const col = world.columnAtMut(1, 1).?;
    const runs = try allocator.alloc(LightRun, 2);
    runs[0] = .{ .count = 4, .color_id = 1, .intensity = 200, .dir = 6 };
    runs[1] = .{ .count = 3, .color_id = 1, .intensity = 120, .dir = 6 };
    col.light = runs;
    col.light_base_y = 9;
    col.light_lo = 3;
    try expectCoverage(&world, 1, 1);

    var cur = LightCursor.init(col.light.?, 10, 9);
    try std.testing.expectEqual(9, cur.hi);
    try std.testing.expectEqual(6, cur.lo);
    try std.testing.expectEqual(200, cur.runs[cur.idx].intensity);
    cur.down();
    try std.testing.expectEqual(5, cur.hi);
    try std.testing.expectEqual(120, cur.runs[cur.idx].intensity);

    // Replacing the material runs drops the stale light stream.
    const fresh = try World.allocUniformRuns(allocator, 16, 0);
    world.setColumnRuns(1, 1, fresh);
    try std.testing.expect(col.light == null);
    try std.testing.expectEqual(@as(u16, 0), col.light_base_y);
}

test "firstSolidInColumn finds interval overlap" {
    var world = try World.init(std.testing.allocator, 2, 16, 2);
    defer world.deinit();
    try world.fillBox(1, 3, 1, 2, 7, 2, 5);
    try std.testing.expectEqual(null, world.firstSolidInColumn(0, 0, 0, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 7, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 0, 2));
    try std.testing.expectEqual(6, world.firstSolidInColumn(1, 1, 0, 15));
    try std.testing.expectEqual(5, world.firstSolidInColumn(1, 1, 4, 5));
    try std.testing.expectEqual(4, world.firstSolidInColumn(1, 1, 4, 4));
    try std.testing.expectEqual(null, world.firstSolidInColumn(-3, 1, 0, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 8, 2));
}

test "run cursor peeks adjacent voxels" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    const col = world.columnAtMut(0, 0).?;

    const cur = RunCursor.init(col.runs, 16, 5);
    try std.testing.expectEqual(5, cur.peek(5));
    try std.testing.expectEqual(5, cur.peek(6));
    try std.testing.expectEqual(0, cur.peek(7));
    try std.testing.expectEqual(5, cur.peek(4));
    try std.testing.expectEqual(0, cur.peek(2));

    const top = RunCursor.init(col.runs, 16, 15);
    try std.testing.expectEqual(0, top.peek(16));
    try std.testing.expectEqual(0, top.peek(15));

    const bottom = RunCursor.init(col.runs, 16, 0);
    try std.testing.expectEqual(0, bottom.peek(0));
    try std.testing.expectEqual(0, bottom.peek(-1));
}

test "run cursor walks both directions" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    const col = world.columnAtMut(0, 0).?;

    var y: i32 = 0;
    var cur = RunCursor.init(col.runs, 16, 0);
    while (y < 16) : (y += 1) {
        const expected: u8 = if (y >= 3 and y < 7) 5 else 0;
        try std.testing.expectEqual(expected, cur.mat());
        try std.testing.expect(y >= cur.lo and y <= cur.hi);
        if (y < 15 and y == cur.hi) cur.up();
    }

    y = 15;
    cur = RunCursor.init(col.runs, 16, 15);
    while (y >= 0) : (y -= 1) {
        const expected: u8 = if (y >= 3 and y < 7) 5 else 0;
        try std.testing.expectEqual(expected, cur.mat());
        if (y > 0 and y == cur.lo) cur.down();
    }
}

test "bounded init loads all covering chunks; out of bounds reads as air" {
    var world = try World.init(std.testing.allocator, 80, 16, 80);
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 4), world.chunks.count());
    try std.testing.expect(world.columnAt(0, 0) != null);
    try std.testing.expect(world.columnAt(79, 79) != null);
    try std.testing.expectEqual(@as(?*const Column, null), world.columnAt(80, 0));
    try std.testing.expectEqual(@as(?*const Column, null), world.columnAt(-1, 0));
    try std.testing.expectEqual(@as(?u16, null), world.macroMax(80, 0));
    try std.testing.expectEqual(@as(u8, 0), world.get(79, 3, 79));
}

test "unbounded world: chunks allocate on demand, missing reads as air" {
    const allocator = std.testing.allocator;
    var world = try World.init(allocator, null, 32, null);
    defer world.deinit();
    try std.testing.expectEqual(@as(usize, 0), world.chunks.count());
    try std.testing.expectEqual(@as(?*const Column, null), world.columnAt(0, 0));
    try std.testing.expectEqual(@as(u8, 0), world.get(5, 3, -100));
    try std.testing.expectEqual(@as(?u16, null), world.macroMax(0, 0));
    try std.testing.expect(!world.solidAt(-40, 3, 20));

    const chunk = try world.ensureChunk(-1, 0); // covers x -64..-1, z 0..63
    try std.testing.expectEqual(@as(usize, 1), world.chunks.count());
    const col = world.columnAt(-1, 5).?;
    try std.testing.expectEqual(@as(usize, 1), col.runs.len); // uniform air, inline
    try std.testing.expectEqual(@as(u8, 0), col.runs[0].palette_id);
    try std.testing.expect(col.runs.ptr == &col.inline_runs);
    try std.testing.expectEqual(no_solid, col.top_solid_y);
    try std.testing.expectEqual(@as(u8, 0), world.get(-1, 7, 5));
    try std.testing.expectEqual(@as(u16, 0), world.macroMax(-1, 5).?);
    // ensureChunk is idempotent.
    try std.testing.expectEqual(chunk, try world.ensureChunk(-1, 0));

    // Writes land through the resident chunk and update the macro grid.
    world.setColumnRuns(-1, 5, try World.allocUniformRuns(allocator, 32, 3));
    try std.testing.expectEqual(@as(u8, 3), world.get(-1, 7, 5));
    try std.testing.expectEqual(@as(u16, 31), world.macroMax(-1, 5).?);
    // The neighboring unloaded chunk still reads as air.
    try std.testing.expectEqual(@as(u8, 0), world.get(0, 7, 5));

    world.freeChunk(-1, 0);
    try std.testing.expectEqual(@as(usize, 0), world.chunks.count());
    try std.testing.expectEqual(@as(?*const Column, null), world.columnAt(-1, 5));
}

test "set/fillBox no-op on unloaded columns" {
    var world = try World.init(std.testing.allocator, null, 16, null);
    defer world.deinit();
    try world.set(10, 3, 10, 5);
    try std.testing.expectEqual(@as(u8, 0), world.get(10, 3, 10));
    try std.testing.expectEqual(@as(?Region, null), world.dirty);
    _ = try world.ensureChunk(0, 0);
    try world.set(10, 3, 10, 5);
    try std.testing.expectEqual(@as(u8, 5), world.get(10, 3, 10));
    try std.testing.expect(world.dirty != null);
}

test "blankChunk resets materials and caches but keeps light runs" {
    const allocator = std.testing.allocator;
    var world = try World.init(allocator, 8, 8, 8);
    defer world.deinit();
    try world.fillBox(1, 1, 1, 3, 3, 3, 5);
    const col = world.columnAtMut(2, 2).?;
    const light = try allocator.alloc(LightRun, 1);
    light[0] = .{ .count = 4, .color_id = 1, .intensity = 200, .dir = 6 };
    col.light = light;
    col.light_base_y = 7;
    col.light_lo = 4;

    const chunk = world.chunks.get(chunkKey(0, 0)).?;
    try world.blankChunk(chunk);
    try std.testing.expectEqual(@as(u8, 0), world.get(2, 2, 2));
    try std.testing.expectEqual(no_solid, col.top_solid_y);
    try std.testing.expectEqual(@as(u64, 0), col.solid_mask);
    try std.testing.expectEqual(@as(u16, 0), world.macroMax(2, 2).?);
    try std.testing.expectEqual(light, col.light.?);
    try std.testing.expectEqual(@as(u16, 7), col.light_base_y);
}
