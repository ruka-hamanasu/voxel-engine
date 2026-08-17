const std = @import("std");

pub const Noise = struct {
    seed: u64,

    pub fn init(seed: u64) Noise {
        return .{ .seed = seed };
    }

    pub fn reseed(self: Noise, salt: u64) Noise {
        return .{ .seed = mix(self.seed ^ salt) };
    }

    fn mix(v_in: u64) u64 {
        var v = v_in;
        v ^= v >> 30;
        v *%= 0xBF58476D1CE4E5B9;
        v ^= v >> 27;
        v *%= 0x94D049BB133111EB;
        v ^= v >> 31;
        return v;
    }

    /// Integer-lattice hash behind noise2.
    pub fn hash2(self: Noise, x: i32, z: i32) u64 {
        const ux: u64 = @bitCast(@as(i64, x));
        const uz: u64 = @bitCast(@as(i64, z));
        return mix(mix(self.seed ^ mix(ux +% 0x9E3779B97F4A7C15)) ^ mix(uz +% 0xC2B2AE3D27D4EB4F));
    }

    /// Integer-lattice hash behind noise3; also the per-position
    /// feature roll source (crystals), so placement is independent of
    /// evaluation order.
    pub fn hash3(self: Noise, x: i32, y: i32, z: i32) u64 {
        const uy: u64 = @bitCast(@as(i64, y));
        return mix(self.hash2(x, z) ^ mix(uy +% 0x165667B19E3779F9));
    }

    fn unit(h: u64) f32 {
        return @as(f32, @floatFromInt(h >> 40)) / @as(f32, 1 << 24);
    }

    fn smooth(t: f32) f32 {
        return t * t * (3.0 - 2.0 * t);
    }

    pub fn noise2(self: Noise, x: f32, z: f32) f32 {
        const x0: i32 = @intFromFloat(@floor(x));
        const z0: i32 = @intFromFloat(@floor(z));
        const tx = smooth(x - @as(f32, @floatFromInt(x0)));
        const tz = smooth(z - @as(f32, @floatFromInt(z0)));
        const v00 = unit(self.hash2(x0, z0));
        const v10 = unit(self.hash2(x0 + 1, z0));
        const v01 = unit(self.hash2(x0, z0 + 1));
        const v11 = unit(self.hash2(x0 + 1, z0 + 1));
        const a = std.math.lerp(v00, v10, tx);
        const b = std.math.lerp(v01, v11, tx);
        return std.math.lerp(a, b, tz) * 2.0 - 1.0;
    }

    pub fn noise3(self: Noise, x: f32, y: f32, z: f32) f32 {
        const x0: i32 = @intFromFloat(@floor(x));
        const y0: i32 = @intFromFloat(@floor(y));
        const z0: i32 = @intFromFloat(@floor(z));
        const tx = smooth(x - @as(f32, @floatFromInt(x0)));
        const ty = smooth(y - @as(f32, @floatFromInt(y0)));
        const tz = smooth(z - @as(f32, @floatFromInt(z0)));
        const c00 = std.math.lerp(unit(self.hash3(x0, y0, z0)), unit(self.hash3(x0 + 1, y0, z0)), tx);
        const c10 = std.math.lerp(unit(self.hash3(x0, y0 + 1, z0)), unit(self.hash3(x0 + 1, y0 + 1, z0)), tx);
        const c01 = std.math.lerp(unit(self.hash3(x0, y0, z0 + 1)), unit(self.hash3(x0 + 1, y0, z0 + 1)), tx);
        const c11 = std.math.lerp(unit(self.hash3(x0, y0 + 1, z0 + 1)), unit(self.hash3(x0 + 1, y0 + 1, z0 + 1)), tx);
        const c0 = std.math.lerp(c00, c10, ty);
        const c1 = std.math.lerp(c01, c11, ty);
        return std.math.lerp(c0, c1, tz) * 2.0 - 1.0;
    }

    pub fn fbm2(self: Noise, x_in: f32, z_in: f32, octaves: u32) f32 {
        var x = x_in;
        var z = z_in;
        var amp: f32 = 1.0;
        var sum: f32 = 0;
        var norm: f32 = 0;
        for (0..octaves) |_| {
            sum += amp * self.noise2(x, z);
            norm += amp;
            amp *= 0.5;
            x *= 2.03;
            z *= 2.03;
        }
        return sum / norm;
    }

    pub fn fbm3(self: Noise, x_in: f32, y_in: f32, z_in: f32, octaves: u32) f32 {
        var x = x_in;
        var y = y_in;
        var z = z_in;
        var amp: f32 = 1.0;
        var sum: f32 = 0;
        var norm: f32 = 0;
        for (0..octaves) |_| {
            sum += amp * self.noise3(x, y, z);
            norm += amp;
            amp *= 0.5;
            x *= 2.03;
            y *= 2.03;
            z *= 2.03;
        }
        return sum / norm;
    }
};

test "noise is deterministic and seeded" {
    const a = Noise.init(42);
    const b = Noise.init(42);
    const c = Noise.init(43);
    try std.testing.expectEqual(a.noise2(1.5, -3.25), b.noise2(1.5, -3.25));
    try std.testing.expectEqual(a.noise3(1.5, 2.5, -3.25), b.noise3(1.5, 2.5, -3.25));
    try std.testing.expect(a.noise2(1.5, -3.25) != c.noise2(1.5, -3.25));
    try std.testing.expect(a.noise3(1.5, 2.5, -3.25) != c.noise3(1.5, 2.5, -3.25));
}

test "fbm stays in range" {
    const n = Noise.init(7);
    var i: i32 = -50;
    while (i < 50) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) * 0.37;
        const v2 = n.fbm2(x, x * 1.3, 4);
        const v3 = n.fbm3(x, x * 0.7, x * 1.3, 2);
        try std.testing.expect(v2 >= -1.0 and v2 <= 1.0);
        try std.testing.expect(v3 >= -1.0 and v3 <= 1.0);
    }
}
