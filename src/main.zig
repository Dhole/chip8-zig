const clap = @import("clap");
const std = @import("std");
const Chip8 = @import("chip8.zig").Chip8;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const debug = std.debug;
const io = std.io;
const log = std.log;
const time = std.time;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

fn help(params: []const clap.Param(clap.Help)) !void {
    const stderr = io.getStdErr().writer();
    try stderr.print("Usage: {s} ", .{std.os.argv[0]});
    try clap.usage(stderr, params);
    try stderr.print("\n", .{});
    try clap.help(stderr, params);
}

pub fn main() !u8 {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.              ") catch unreachable,
        clap.parseParam("-s, --scale <NUM>      Scaling integer value.") catch unreachable,
        clap.parseParam("<ROM>") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag }) catch |err| {
        // Report useful error and exit
        var buf = std.ArrayList(u8).init(&gpa.allocator);
        defer buf.deinit();
        try diag.report(buf.writer(), err);
        const msg = std.mem.trimRight(u8, buf.items, "\n");
        log.err("Clap parse: {s} ({any})", .{ msg, err });
        return 1;
    };
    defer args.deinit();

    if (args.flag("--help")) {
        try help(&params);
        return 0;
    }
    const scale: u32 = blk: {
        if (args.option("--scale")) |n| {
            break :blk std.fmt.parseUnsigned(u32, n, 10) catch |err| {
                log.err("Unable to parse flag --scale \"{s}\" ({any})", .{ n, err });
                return 1;
            };
        } else {
            break :blk 8;
        }
    };
    const rom_path: []const u8 = blk: {
        const positionals = args.positionals();
        if (positionals.len != 1) {
            log.err("Missing positional argument", .{});
            try help(&params);
            return 1;
        } else {
            break :blk positionals[0];
        }
    };

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        log.err("Unable to initialize SDL: {s}", .{c.SDL_GetError()});
        return 2;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "chip8-zig by Dhole",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        @intCast(c_int, scale * Chip8.SCREEN_WIDTH),
        @intCast(c_int, scale * Chip8.SCREEN_HEIGTH),
        c.SDL_WINDOW_OPENGL,
    ) orelse
        {
        log.err("Unable to create window: {s}", .{c.SDL_GetError()});
        return 2;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, -1, 0) orelse {
        log.err("Unable to create renderer: {s}", .{c.SDL_GetError()});
        return 2;
    };
    defer c.SDL_DestroyRenderer(renderer);

    if (c.SDL_RenderClear(renderer) != 0) {
        log.err("Unable to clear renderer: {s}", .{c.SDL_GetError()});
        return 3;
    }

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_RGBA8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        Chip8.SCREEN_WIDTH,
        Chip8.SCREEN_HEIGTH,
    ) orelse {
        log.err("Unable to create texture from surface: {s}", .{c.SDL_GetError()});
        return 2;
    };
    defer c.SDL_DestroyTexture(texture);

    var chip8 = try Chip8.init(&gpa.allocator);
    defer chip8.deinit();

    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.@"type") {
                c.SDL_QUIT => {
                    quit = true;
                },
                else => {},
            }
        }

        {
            var pixels: [*]u32 = undefined;
            var pitch: c_int = undefined;
            if (c.SDL_LockTexture(texture, null, @ptrCast([*c]?*c_void, &pixels), &pitch) != 0) {
                log.err("Unable to lock texture: {s}", .{c.SDL_GetError()});
                return 3;
            }
            var row_len = @divExact(@intCast(usize, pitch), 4); // RGBA8888 is 4 bytes
            var y: usize = 0;
            while (y < 10) : (y += 1) {
                var row = pixels[y * row_len .. (y + 1) * row_len];
                var x: usize = 0;
                while (x < 10) : (x += 1) {
                    if ((x + y) % 2 == 0) {
                        row[x] = 0x00_00_00_00;
                    } else {
                        row[x] = 0xff_ff_ff_ff;
                    }
                }
            }
            c.SDL_UnlockTexture(texture);
        }

        if (c.SDL_RenderCopy(renderer, texture, null, null) != 0) {
            log.err("Unable to copy tecture to renderer: {s}", .{c.SDL_GetError()});
            return 3;
        }

        c.SDL_RenderPresent(renderer);

        time.sleep(1_666 * time.ns_per_us);
    }
    return 0;
}
