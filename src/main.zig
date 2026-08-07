const std = @import("std");
const c = @cImport({
    @cInclude("nk_config.h");
    @cInclude("SDL.h");
    @cInclude("nuklear.h");
    @cInclude("nuklear_sdl_renderer.h");
});
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const Input = @import("camera.zig").Input;
const render = @import("render.zig");

const render_w = 480;
const render_h = 270;
const window_w = 960;
const window_h = 540;

var framebuffer: [render_w * render_h]u32 = undefined;
var staging: [render_w * render_h]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    var headless_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--headless")) {
            i += 1;
            if (i >= args.len) return error.MissingHeadlessPath;
            headless_path = std.mem.span(args[i]);
        }
    }

    const allocator = init.gpa;
    var world = try World.buildDemoRoom(allocator);
    defer world.deinit();
    var cam = Camera{ .x = 16, .y = 5.5, .z = 8, .yaw = std.math.pi / 2.0 };

    if (headless_path) |path| {
        render.render(&framebuffer, render_w, render_h, &world, cam);
        render.transpose(&staging, &framebuffer, render_w, render_h);
        try render.writePpm(init.io, allocator, path, &staging, render_w, render_h);
        return;
    }

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "voxel-engine",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        window_w,
        window_h,
        c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(
        window,
        -1,
        c.SDL_RENDERER_SOFTWARE | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse {
        std.log.err("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        render_w,
        render_h,
    ) orelse {
        std.log.err("SDL_CreateTexture: {s}", .{c.SDL_GetError()});
        return error.SdlTextureFailed;
    };
    defer c.SDL_DestroyTexture(texture);

    const ctx = c.nk_sdl_init(window, renderer);
    var atlas: ?*c.nk_font_atlas = null;
    c.nk_sdl_font_stash_begin(&atlas);
    c.nk_sdl_font_stash_end();
    defer c.nk_sdl_shutdown();

    _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE);
    var mouse_captured = true;
    var mouse_dx: f32 = 0;

    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    var last_counter = c.SDL_GetPerformanceCounter();
    var fps: f64 = 0;
    var frame: u32 = 0;
    var running = true;

    while (running) {
        c.nk_input_begin(ctx);
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            _ = c.nk_sdl_handle_event(&event);
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        if (mouse_captured) {
                            _ = c.SDL_SetRelativeMouseMode(c.SDL_FALSE);
                            mouse_captured = false;
                        } else {
                            running = false;
                        }
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (mouse_captured) mouse_dx += @floatFromInt(event.motion.xrel);
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (!mouse_captured) {
                        _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE);
                        mouse_captured = true;
                    }
                },
                else => {},
            }
        }
        c.nk_input_end(ctx);

        const now_counter = c.SDL_GetPerformanceCounter();
        const dt = @as(f64, @floatFromInt(now_counter - last_counter)) / freq;
        last_counter = now_counter;
        if (dt > 0) {
            const instant = 1.0 / dt;
            fps = if (frame == 0) instant else fps * 0.95 + instant * 0.05;
        }

        const keys = c.SDL_GetKeyboardState(null);
        var input: Input = .{ .mouse_dx = mouse_dx };
        mouse_dx = 0;
        if (keys[c.SDL_SCANCODE_W] != 0) input.forward += 1;
        if (keys[c.SDL_SCANCODE_S] != 0) input.forward -= 1;
        if (keys[c.SDL_SCANCODE_D] != 0) input.strafe += 1;
        if (keys[c.SDL_SCANCODE_A] != 0) input.strafe -= 1;
        if (keys[c.SDL_SCANCODE_SPACE] != 0) input.vertical += 1;
        if (keys[c.SDL_SCANCODE_LCTRL] != 0) input.vertical -= 1;
        input.boost = keys[c.SDL_SCANCODE_LSHIFT] != 0;
        cam.update(input, @floatCast(dt), world.w, world.h, world.d);

        render.render(&framebuffer, render_w, render_h, &world, cam);
        render.transpose(&staging, &framebuffer, render_w, render_h);

        if (c.SDL_UpdateTexture(texture, null, &staging, render_w * 4) != 0) {
            std.log.err("SDL_UpdateTexture: {s}", .{c.SDL_GetError()});
            return error.SdlTextureUpdateFailed;
        }
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);

        drawFpsOverlay(ctx, fps);
        c.nk_sdl_render(c.NK_ANTI_ALIASING_ON);

        c.SDL_RenderPresent(renderer);
        frame +%= 1;
    }
}

fn drawFpsOverlay(ctx: ?*c.nk_context, fps: f64) void {
    const w: f32 = 110;
    const h: f32 = 36;
    const bounds: c.struct_nk_rect = .{ .x = window_w - w - 8, .y = 8, .w = w, .h = h };
    const flags = c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_NO_INPUT;

    if (c.nk_begin(ctx, "fps", bounds, flags) != 0) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1} fps", .{fps}) catch "? fps";
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, text.ptr, c.NK_TEXT_CENTERED);
    }
    c.nk_end(ctx);
}
