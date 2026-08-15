//! Persistent worker pool (plans/DISTANCE.md D1): a fixed set of
//! std.Thread workers created at startup that sleep between jobs, plus
//! the calling (main) thread, which always participates. One job at a
//! time: run() publishes a job, every participant grabs work items via
//! an atomic counter until drained, and run() returns once all workers
//! have finished the grab loop (so every claimed item is complete).
//!
//! Item assignment is timing-dependent, but correct jobs write
//! disjoint output per item and carry no cross-item state, so results
//! stay byte-identical to the inline (zero-worker) path.

const std = @import("std");
const world_mod = @import("world.zig");

/// Main thread + 3 workers; bounds world.zig's memo shards.
pub const max_participants = world_mod.World.memo_slots;

const Job = struct {
    ctx: *anyopaque,
    run_item: *const fn (ctx: *anyopaque, item: usize) void,
    n_items: usize,
    next: std.atomic.Value(usize) = .init(0),
};

pub const Pool = struct {
    workers: [max_participants - 1]?std.Thread = @splat(null),
    n_workers: usize = 0,
    // Only the uncancelable futex paths are used (userdata ignored),
    // so the static single-threaded Io suffices as the backing impl.
    threaded: std.Io.Threaded = .init_single_threaded,
    mutex: std.Io.Mutex = .init,
    job_cv: std.Io.Condition = .init,
    done_cv: std.Io.Condition = .init,
    job: ?*Job = null,
    generation: u64 = 0,
    done: usize = 0,
    quit: bool = false,

    /// Spawn worker_count workers. Two-phase: the Pool must be at its
    /// final address before start (workers hold a back-pointer), and
    /// must not be moved or run concurrently afterwards.
    pub fn start(self: *Pool, worker_count: usize) !void {
        std.debug.assert(worker_count < max_participants);
        std.debug.assert(self.n_workers == 0);
        errdefer self.deinit();
        for (0..worker_count) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerMain, .{ self, i });
            self.n_workers += 1;
        }
    }

    pub fn deinit(self: *Pool) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        self.quit = true;
        self.job_cv.broadcast(io);
        self.mutex.unlock(io);
        for (self.workers) |w| {
            if (w) |t| t.join();
        }
        self.* = .{};
    }

    /// Invoke func(ctx, i) for i in 0..n_items across all participants,
    /// returning when every item has completed. ctx must be a pointer
    /// that outlives the call. With no workers (or no items) runs
    /// inline on the calling thread.
    pub fn run(self: *Pool, ctx: anytype, comptime func: anytype, n_items: usize) void {
        if (n_items == 0) return;
        if (self.n_workers == 0) {
            for (0..n_items) |i| func(ctx, i);
            return;
        }
        const Ctx = @TypeOf(ctx);
        const trampoline = struct {
            fn call(raw: *anyopaque, item: usize) void {
                func(@as(Ctx, @ptrCast(@alignCast(raw))), item);
            }
        }.call;
        var job: Job = .{ .ctx = @constCast(@as(*const anyopaque, @ptrCast(ctx))), .run_item = trampoline, .n_items = n_items };
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        self.job = &job;
        self.generation += 1;
        self.done = 0;
        self.job_cv.broadcast(io);
        self.mutex.unlock(io);

        grab(&job);

        self.mutex.lockUncancelable(io);
        while (self.done < self.n_workers) self.done_cv.waitUncancelable(io, &self.mutex);
        self.job = null;
        self.mutex.unlock(io);
    }

    fn grab(job: *Job) void {
        while (true) {
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.n_items) break;
            job.run_item(job.ctx, i);
        }
    }

    fn workerMain(self: *Pool, index: usize) void {
        world_mod.World.memo_slot = index + 1;
        const io = self.threaded.io();
        var seen: u64 = 0;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.quit and self.generation == seen) {
                self.job_cv.waitUncancelable(io, &self.mutex);
            }
            if (self.quit) {
                self.mutex.unlock(io);
                return;
            }
            seen = self.generation;
            const job = self.job.?;
            self.mutex.unlock(io);

            grab(job);

            self.mutex.lockUncancelable(io);
            self.done += 1;
            if (self.done == self.n_workers) self.done_cv.signal(io);
            self.mutex.unlock(io);
        }
    }
};

test "run covers every item exactly once, inline and pooled" {
    const Counter = struct {
        hits: [64]std.atomic.Value(u32) = @splat(.init(0)),
        fn bump(self: *@This(), i: usize) void {
            _ = self.hits[i].fetchAdd(1, .monotonic);
        }
    };
    for ([_]usize{ 0, 3 }) |workers| {
        var pool: Pool = .{};
        try pool.start(workers);
        defer pool.deinit();
        var counter: Counter = .{};
        pool.run(&counter, Counter.bump, 64);
        for (&counter.hits) |*h| try std.testing.expectEqual(1, h.load(.monotonic));
    }
}
