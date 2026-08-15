const std = @import("std");

pub const Input = struct {
    forward: f32 = 0,
    strafe: f32 = 0,
    vertical: f32 = 0,
    boost: bool = false,
    mouse_dx: f32 = 0,
};

pub const Camera = struct {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,

    pub const sensitivity: f32 = 0.003;
    /// Fly/noclip speed in voxels/s (walk speed lives in player.zig).
    pub const speed: f32 = 30.0;
    pub const boost_factor: f32 = 4.0;

    pub fn forward(self: Camera) [2]f32 {
        return .{ @cos(self.yaw), @sin(self.yaw) };
    }

    pub fn right(self: Camera) [2]f32 {
        return .{ @sin(self.yaw), -@cos(self.yaw) };
    }

    /// w/d are null for an unbounded world (plans/STREAMING.md): the XZ
    /// clamps drop out. h stays required — falling out of the sky or
    /// under the floor is never useful.
    pub fn update(self: *Camera, input: Input, dt: f32, w: ?usize, h: usize, d: ?usize) void {
        self.yaw = std.math.wrap(self.yaw - input.mouse_dx * sensitivity, std.math.pi);

        const v = speed * (if (input.boost) boost_factor else 1.0) * dt;
        const fwd = self.forward();
        const rgt = self.right();
        const hf: f32 = @floatFromInt(h);
        const nx = self.x + (fwd[0] * input.forward + rgt[0] * input.strafe) * v;
        const nz = self.z + (fwd[1] * input.forward + rgt[1] * input.strafe) * v;
        self.x = if (w) |bw| std.math.clamp(nx, 0, @as(f32, @floatFromInt(bw))) else nx;
        self.y = std.math.clamp(self.y + input.vertical * v, 0, hf);
        self.z = if (d) |bd| std.math.clamp(nz, 0, @as(f32, @floatFromInt(bd))) else nz;
    }
};

test "update moves forward and clamps to bounds" {
    var cam = Camera{ .x = 1, .y = 1, .z = 1, .yaw = 0 };
    cam.update(.{ .forward = 1 }, 0.05, 8, 8, 8);
    try std.testing.expectApproxEqAbs(2.5, cam.x, 1e-5);
    try std.testing.expectApproxEqAbs(1.0, cam.z, 1e-5);

    cam.update(.{ .forward = 1, .boost = true }, 1.0, 8, 8, 8);
    try std.testing.expectEqual(8.0, cam.x);

    cam.update(.{ .vertical = -1 }, 10.0, 8, 8, 8);
    try std.testing.expectEqual(0.0, cam.y);
}

test "update wraps yaw" {
    var cam = Camera{ .x = 0, .y = 0, .z = 0, .yaw = -std.math.pi + 0.01 };
    cam.update(.{ .mouse_dx = 10 }, 0, 8, 8, 8);
    try std.testing.expect(cam.yaw > 0);
    try std.testing.expectApproxEqAbs(std.math.pi - 0.02, cam.yaw, 1e-5);
}
