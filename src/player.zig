const std = @import("std");
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const Input = @import("camera.zig").Input;

/// Walking/flying movement with AABB collision against the voxel world
/// (milestone 23; noclip delegates to Camera.update unchanged). The
/// body is a box 2*half_width x height x 2*half_width voxels anchored
/// at the feet (pos = feet center); the camera rides at eye_height. At
/// the nominal 10 cm voxel scale the body is 0.6 x 1.6 x 0.6 m.
///
/// Collision is axis-separated: each axis moves, then clamps to the
/// nearest blocking voxel face among the handful of voxels the box
/// overlaps (World.solidAt — a bit test for h <= 64, a short run scan
/// above). Walk mode adds gravity, jumping, auto-step onto ledges up
/// to step_height tall (terrain slopes read as 1-voxel stairs), and a
/// ground snap of the same range so descents don't micro-bounce.
pub const Mode = enum { walk, fly };

pub const Player = struct {
    x: f32, // feet center
    y: f32,
    z: f32,
    yaw: f32,
    vy: f32 = 0,
    mode: Mode = .walk,
    noclip: bool = false,
    on_ground: bool = false,

    pub const half_width: f32 = 3.0;
    pub const height: f32 = 16.0;
    pub const eye_height: f32 = 14.0;
    pub const step_height: f32 = 4.0;
    pub const walk_speed: f32 = 14.0;
    /// 9.8 m/s^2 at 10 cm voxels.
    pub const gravity: f32 = 98.0;
    /// Apex ~12 voxels: clears auto-step range with margin, not 2x.
    pub const jump_vel: f32 = 48.0;
    pub const terminal_vel: f32 = 150.0;
    const ground_probe: f32 = 0.05;
    const max_dt: f32 = 0.1;

    pub fn fromCamera(cam: Camera) Player {
        return .{ .x = cam.x, .y = cam.y - eye_height, .z = cam.z, .yaw = cam.yaw };
    }

    pub fn camera(self: *const Player) Camera {
        return .{ .x = self.x, .y = self.y + eye_height, .z = self.z, .yaw = self.yaw };
    }

    /// Push straight up until the body is out of solid voxels (spawn
    /// and collision re-enable can start embedded).
    pub fn unstick(self: *Player, world: *const World) void {
        var i: usize = 0;
        while (i < world.h * 2 and aabbCollides(world, self.x, self.y, self.z)) : (i += 1)
            self.y += 0.5;
    }

    /// True when the voxel overlaps the body box (edit place-guard).
    pub fn overlapsVoxel(self: *const Player, vx: usize, vy: usize, vz: usize) bool {
        const fx: f32 = @floatFromInt(vx);
        const fy: f32 = @floatFromInt(vy);
        const fz: f32 = @floatFromInt(vz);
        return fx + 1 > self.x - half_width and fx < self.x + half_width and
            fy + 1 > self.y and fy < self.y + height and
            fz + 1 > self.z - half_width and fz < self.z + half_width;
    }

    pub fn update(self: *Player, world: *const World, input: Input, dt: f32) void {
        if (self.noclip) {
            var cam = self.camera();
            cam.update(input, dt, world.w, world.h, world.d);
            self.x = cam.x;
            self.y = cam.y - eye_height;
            self.z = cam.z;
            self.yaw = cam.yaw;
            self.vy = 0;
            self.on_ground = false;
            return;
        }
        self.yaw = std.math.wrap(self.yaw - input.mouse_dx * Camera.sensitivity, std.math.pi);
        const dtc = @min(dt, max_dt);
        const fwd: [2]f32 = .{ @cos(self.yaw), @sin(self.yaw) };
        const rgt: [2]f32 = .{ fwd[1], -fwd[0] };

        self.on_ground = aabbCollides(world, self.x, self.y - ground_probe, self.z);
        const hv = (if (self.mode == .walk) walk_speed else Camera.speed) *
            (if (input.boost) Camera.boost_factor else 1.0) * dtc;
        self.moveHorizontal(world, .x, (fwd[0] * input.forward + rgt[0] * input.strafe) * hv);
        self.moveHorizontal(world, .z, (fwd[1] * input.forward + rgt[1] * input.strafe) * hv);

        switch (self.mode) {
            .walk => {
                if (input.vertical > 0 and self.on_ground) self.vy = jump_vel;
                self.vy = @max(self.vy - gravity * dtc, -terminal_vel);
                if (self.on_ground and self.vy <= 0) {
                    // Ground snap: glued down 1-voxel stairs and small
                    // drops instead of ballistic micro-hops.
                    if (self.axisMove(world, .y, -(step_height + ground_probe))) {
                        // No ground within snap range: walked off an
                        // edge — undo the blind probe and fall.
                        self.y += step_height + ground_probe;
                        self.on_ground = false;
                    } else {
                        self.vy = 0;
                    }
                }
                if (!self.axisMove(world, .y, self.vy * dtc)) {
                    if (self.vy < 0) self.on_ground = true;
                    self.vy = 0;
                }
            },
            .fly => {
                self.vy = 0;
                const vv = Camera.speed * (if (input.boost) Camera.boost_factor else 1.0) * dtc;
                _ = self.axisMove(world, .y, input.vertical * vv);
            },
        }

        // World bounds act as walls/floor/ceiling (solidAt reads OOB
        // as air). XZ bounds lift for an unbounded world (STREAMING.md;
        // still always bounded pre-chunking); the Y clamp stays.
        const hf: f32 = @floatFromInt(world.h);
        const xb: ?usize = world.w;
        const zb: ?usize = world.d;
        if (xb) |bw| self.x = std.math.clamp(self.x, half_width, @as(f32, @floatFromInt(bw)) - half_width);
        self.y = std.math.clamp(self.y, 0, hf - height);
        if (zb) |bd| self.z = std.math.clamp(self.z, half_width, @as(f32, @floatFromInt(bd)) - half_width);
    }

    const Axis = enum { x, y, z };

    fn moveHorizontal(self: *Player, world: *const World, comptime axis: Axis, amount: f32) void {
        if (amount == 0) return;
        const coord: *f32 = switch (axis) {
            .x => &self.x,
            .z => &self.z,
            .y => unreachable,
        };
        const goal = coord.* + amount;
        if (self.axisMove(world, axis, amount)) return;
        if (self.mode != .walk or !self.on_ground) return;
        // Auto-step: retry the remaining motion lifted by step_height,
        // then settle back down onto the ledge (or back onto the
        // original ground when the wall is taller than the step).
        const clamped = coord.*;
        const y0 = self.y;
        self.y = y0 + step_height;
        if (aabbCollides(world, self.x, self.y, self.z)) {
            self.y = y0;
            return;
        }
        _ = self.axisMove(world, axis, goal - clamped);
        _ = self.axisMove(world, .y, -(step_height + ground_probe));
    }

    /// Move along one axis by amount, clamping to the nearest blocking
    /// voxel face. Returns false when blocked (position still clamped).
    fn axisMove(self: *Player, world: *const World, comptime axis: Axis, amount: f32) bool {
        if (amount == 0) return true;
        const coord: *f32 = switch (axis) {
            .x => &self.x,
            .y => &self.y,
            .z => &self.z,
        };
        const start = coord.*;
        const lo_off: f32 = if (axis == .y) 0 else -half_width;
        const hi_off: f32 = if (axis == .y) height else half_width;
        var p: [3]f32 = .{ self.x, self.y, self.z };
        p[@intFromEnum(axis)] = start + amount;
        const rx = vrange(p[0], -half_width, half_width);
        const ry = vrange(p[1], 0, height);
        const rz = vrange(p[2], -half_width, half_width);
        var limit = start + amount;
        var blocked = false;
        var vx = rx[0];
        while (vx <= rx[1]) : (vx += 1) {
            var vy = ry[0];
            while (vy <= ry[1]) : (vy += 1) {
                var vz = rz[0];
                while (vz <= rz[1]) : (vz += 1) {
                    if (!world.solidAt(vx, vy, vz)) continue;
                    const v: f32 = @floatFromInt(switch (axis) {
                        .x => vx,
                        .y => vy,
                        .z => vz,
                    });
                    blocked = true;
                    if (amount > 0) {
                        limit = @min(limit, v - hi_off);
                    } else {
                        limit = @max(limit, v + 1 - lo_off);
                    }
                }
            }
        }
        if (!blocked) {
            coord.* = start + amount;
            return true;
        }
        // A constraint behind the start means the body was already
        // embedded: escape (full move) rather than pulling back.
        if (amount > 0) {
            if (limit < start) {
                coord.* = start + amount;
                return true;
            }
            coord.* = limit;
        } else {
            if (limit > start) {
                coord.* = start + amount;
                return true;
            }
            coord.* = limit;
        }
        return false;
    }
};

/// Voxel-index range overlapped by [p+lo, p+hi]; the hi - eps keeps a
/// box face exactly on a voxel boundary from counting the voxel beyond.
fn vrange(p: f32, lo: f32, hi: f32) [2]i32 {
    return .{
        @intFromFloat(@floor(p + lo)),
        @intFromFloat(@floor(p + hi - 1e-4)),
    };
}

fn aabbCollides(world: *const World, x: f32, y: f32, z: f32) bool {
    const rx = vrange(x, -Player.half_width, Player.half_width);
    const ry = vrange(y, 0, Player.height);
    const rz = vrange(z, -Player.half_width, Player.half_width);
    var vx = rx[0];
    while (vx <= rx[1]) : (vx += 1) {
        var vy = ry[0];
        while (vy <= ry[1]) : (vy += 1) {
            var vz = rz[0];
            while (vz <= rz[1]) : (vz += 1) {
                if (world.solidAt(vx, vy, vz)) return true;
            }
        }
    }
    return false;
}

fn testWorld() !World {
    var world = try World.init(std.testing.allocator, 32, 40, 32);
    try world.fillBox(0, 0, 0, 32, 1, 32, 1); // floor at y=0
    return world;
}

fn step(p: *Player, world: *const World, input: Input, frames: usize) void {
    for (0..frames) |_| p.update(world, input, 1.0 / 60.0);
}

test "gravity lands on the floor" {
    var world = try testWorld();
    defer world.deinit();
    var p = Player.fromCamera(.{ .x = 16, .y = 25 + Player.eye_height, .z = 16, .yaw = 0 });
    step(&p, &world, .{}, 120);
    try std.testing.expectApproxEqAbs(1.0, p.y, 1e-3);
    try std.testing.expect(p.on_ground);
    try std.testing.expectEqual(@as(f32, 0), p.vy);
}

test "walk stops at a wall" {
    var world = try testWorld();
    defer world.deinit();
    try world.fillBox(20, 1, 0, 21, 25, 32, 1);
    var p: Player = .{ .x = 14, .y = 1, .z = 16, .yaw = 0 };
    step(&p, &world, .{ .forward = 1 }, 240); // 56 voxels without the wall
    try std.testing.expectApproxEqAbs(17.0, p.x, 1e-3); // face 20 - half_width
    try std.testing.expect(p.on_ground);
}

test "auto-step climbs 4 voxels but not 5" {
    var world = try testWorld();
    defer world.deinit();
    try world.fillBox(20, 1, 0, 32, 5, 32, 1); // 4-tall plateau
    var p: Player = .{ .x = 14, .y = 1, .z = 16, .yaw = 0 };
    step(&p, &world, .{ .forward = 1 }, 30); // ~7 voxels: onto the plateau
    try std.testing.expect(p.x > 20);
    try std.testing.expect(p.x < 23);
    try std.testing.expectApproxEqAbs(5.0, p.y, 1e-3);

    try world.fillBox(26, 5, 0, 27, 10, 32, 1); // 5-tall wall on the plateau
    step(&p, &world, .{ .forward = 1 }, 120);
    try std.testing.expectApproxEqAbs(23.0, p.x, 1e-3);
    try std.testing.expectApproxEqAbs(5.0, p.y, 1e-3);
}

test "jump apex and landing" {
    var world = try testWorld();
    defer world.deinit();
    var p: Player = .{ .x = 16, .y = 1, .z = 16, .yaw = 0 };
    step(&p, &world, .{}, 30);
    var max_y: f32 = 0;
    step(&p, &world, .{ .vertical = 1 }, 1);
    for (0..180) |_| {
        step(&p, &world, .{}, 1);
        max_y = @max(max_y, p.y);
    }
    try std.testing.expect(max_y > 11 and max_y < 13.5);
    try std.testing.expectApproxEqAbs(1.0, p.y, 1e-3);
}

test "ceiling blocks jumps" {
    var world = try testWorld();
    defer world.deinit();
    try world.fillBox(0, 25, 0, 32, 26, 32, 1);
    var p: Player = .{ .x = 16, .y = 1, .z = 16, .yaw = 0 };
    step(&p, &world, .{}, 30);
    var max_y: f32 = 0;
    for (0..180) |_| {
        step(&p, &world, .{ .vertical = 1 }, 1);
        max_y = @max(max_y, p.y);
    }
    try std.testing.expectApproxEqAbs(9.0, max_y, 1e-3); // 25 - height
}

test "fly collides with walls and ceilings" {
    var world = try testWorld();
    defer world.deinit();
    try world.fillBox(20, 1, 0, 21, 25, 32, 1);
    try world.fillBox(0, 25, 0, 32, 26, 32, 1);
    var p: Player = .{ .x = 14, .y = 1, .z = 16, .yaw = 0, .mode = .fly };
    step(&p, &world, .{ .forward = 1, .vertical = 1 }, 240);
    try std.testing.expectApproxEqAbs(17.0, p.x, 1e-3);
    try std.testing.expectApproxEqAbs(9.0, p.y, 1e-3);
}

test "noclip passes through walls" {
    var world = try testWorld();
    defer world.deinit();
    try world.fillBox(20, 1, 0, 21, 25, 32, 1);
    var p: Player = .{ .x = 14, .y = 1, .z = 16, .yaw = 0, .noclip = true };
    step(&p, &world, .{ .forward = 1 }, 240);
    try std.testing.expect(p.x > 21);
}

test "unstick lifts an embedded body out of the floor" {
    var world = try testWorld();
    defer world.deinit();
    var p: Player = .{ .x = 16, .y = 0.5, .z = 16, .yaw = 0 };
    p.unstick(&world);
    try std.testing.expectApproxEqAbs(1.0, p.y, 1e-3);
}

test "overlapsVoxel matches the body box" {
    const p: Player = .{ .x = 16, .y = 1, .z = 16, .yaw = 0 };
    try std.testing.expect(p.overlapsVoxel(16, 5, 16));
    try std.testing.expect(p.overlapsVoxel(13, 16, 13));
    try std.testing.expect(!p.overlapsVoxel(20, 5, 16));
    try std.testing.expect(!p.overlapsVoxel(16, 0, 16)); // floor below
    try std.testing.expect(!p.overlapsVoxel(16, 17, 16)); // above head
}
