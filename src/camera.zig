pub const Camera = struct {
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,

    pub fn forward(self: Camera) [2]f32 {
        return .{ @cos(self.yaw), @sin(self.yaw) };
    }

    pub fn right(self: Camera) [2]f32 {
        return .{ @sin(self.yaw), -@cos(self.yaw) };
    }
};
