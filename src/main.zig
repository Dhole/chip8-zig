const clap = @import("clap");
const std = @import("std");
const chip8 = @import("chip8.zig");

const Chip8 = chip8.Chip8;
const testBit = chip8.testBit;

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

fn key_map(sym: c.SDL_Keycode) u16 {
    return switch (sym) {
        c.SDLK_1 => 1 << 0x1,
        c.SDLK_2 => 1 << 0x2,
        c.SDLK_3 => 1 << 0x3,
        c.SDLK_4 => 1 << 0xC,
        c.SDLK_q => 1 << 0x4,
        c.SDLK_w => 1 << 0x5,
        c.SDLK_e => 1 << 0x6,
        c.SDLK_r => 1 << 0xD,
        c.SDLK_a => 1 << 0x7,
        c.SDLK_s => 1 << 0x8,
        c.SDLK_d => 1 << 0x9,
        c.SDLK_f => 1 << 0xE,
        c.SDLK_z => 1 << 0xA,
        c.SDLK_x => 1 << 0x0,
        c.SDLK_c => 1 << 0xB,
        c.SDLK_v => 1 << 0xF,
        else => @as(u16, 0),
    };
}

const AUDIO_FREQ: c_int = 44100;
const PHASE_INC: c_int = std.math.maxInt(c_int) / AUDIO_FREQ * 440;
const VOL: i16 = 0x20_00; // 25% of std.math.maxInt(i16)

fn square_wave_audio_cb(user_data: ?*c_void, raw_buffer: [*c]u8, bytes: c_int) callconv(.C) void {
    var buffer = @ptrCast([*c]i16, @alignCast(@alignOf(*i16), raw_buffer));
    const length = @intCast(usize, bytes) / 2; // 2 bytes per sample for AUDIO_S16SYS
    var phase = @ptrCast(*c_int, @alignCast(@alignOf(c_int), user_data));

    var i: usize = 0;
    while (i < length) : (i += 1) {
        buffer[i] = if (phase.* < 0) -VOL else VOL;
        phase.* +%= PHASE_INC;
    }
}

pub fn main() !u8 {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.              ") catch unreachable,
        clap.parseParam("-s, --scale <NUM>      Scaling integer value.") catch unreachable,
        clap.parseParam("<ROM>") catch unreachable,
    };

    //
    // Parse arguments
    //

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

    // Read ROM file

    var rom_file = try std.fs.cwd().openFile(rom_path, .{ .read = true });
    const rom = try rom_file.readToEndAlloc(&gpa.allocator, Chip8.MEM_SIZE);
    defer gpa.allocator.free(rom);

    //
    // SDL Setup
    //

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO) != 0) {
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

    var phase: c_int = 0;
    var want = c.SDL_AudioSpec{
        .freq = AUDIO_FREQ,
        .format = c.AUDIO_S16SYS,
        .channels = 1,
        .samples = 2048,
        .callback = square_wave_audio_cb,
        .userdata = &phase,
        .silence = undefined,
        .padding = undefined,
        .size = undefined,
    };
    var have: c.SDL_AudioSpec = undefined;
    if (c.SDL_OpenAudio(&want, &have) != 0) {
        log.err("Unable to open audio: {s}", .{c.SDL_GetError()});
        return 4;
    }
    defer c.SDL_CloseAudio();
    if (want.format != have.format) {
        log.err("Unable to get desired AudioSpec", .{});
        return 4;
    }

    //
    // Chip8 initialization
    //

    var seed: u64 = undefined;
    try std.os.getrandom(std.mem.asBytes(&seed));
    var c8 = try Chip8.init(&gpa.allocator, seed);
    defer c8.deinit();
    try c8.load_rom(rom);

    //
    // Main loop
    //

    var keypad: u16 = 0;
    var timestamp = time.nanoTimestamp();
    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => {
                    quit = true;
                },
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        quit = true;
                    }
                    keypad |= key_map(event.key.keysym.sym);
                },
                c.SDL_KEYUP => {
                    keypad &= ~key_map(event.key.keysym.sym);
                },
                else => {},
            }
        }

        try c8.frame(keypad);
        if (c8.tone_on()) {
            c.SDL_PauseAudio(0);
        } else {
            c.SDL_PauseAudio(1);
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
            while (y < Chip8.SCREEN_HEIGTH) : (y += 1) {
                var row = pixels[y * row_len .. (y + 1) * row_len];
                var x: usize = 0;
                while (x < Chip8.SCREEN_WIDTH / 8) : (x += 1) {
                    const byte = c8.framebuffer()[y * Chip8.SCREEN_WIDTH / 8 + x];
                    var i: usize = 0;
                    while (i < 8) : (i += 1) {
                        const offset = x * 8 + i;
                        const on = if (testBit(byte, 7 - i)) true else false;
                        if (on) {
                            row[offset] = 0xff_ff_ff_ff;
                        } else {
                            row[offset] = 0x00_00_00_00;
                        }
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

        const now = time.nanoTimestamp();
        const sleep_dur = chip8.FRAME_TIME * time.ns_per_us - (now - timestamp);
        time.sleep(if (sleep_dur > 0) @intCast(u64, sleep_dur) else 0);
        timestamp = now;
    }
    return 0;
}
