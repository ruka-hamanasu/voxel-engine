const std = @import("std");
const c = @cImport({
    @cInclude("nk_config.h");
    @cInclude("SDL.h");
    @cInclude("nuklear.h");
    @cInclude("nuklear_sdl_renderer.h");
});

const render_w = 480;
const render_h = 270;
const window_w = 960;
const window_h = 540;

var framebuffer: [render_w * render_h]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    _ = init;

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
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) running = false;
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

        fillGradient(frame);

        if (c.SDL_UpdateTexture(texture, null, &framebuffer, render_w * 4) != 0) {
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

fn fillGradient(frame: u32) void {
    for (0..render_h) |y| {
        for (0..render_w) |x| {
            const r: u32 = @truncate(x * 255 / (render_w - 1));
            const g: u32 = @truncate(y * 255 / (render_h - 1));
            const b: u32 = @truncate((x + y + frame * 2) % 256);
            framebuffer[y * render_w + x] = 0xff000000 | (r << 16) | (g << 8) | b;
        }
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
