const std = @import("std");

const mem = std.mem;

const SPRITE_CHARS: [0x10][5]u8 = [0x10][5]u8{
    [5]u8{ 0xF0, 0x90, 0x90, 0x90, 0xF0 }, // 0
    [5]u8{ 0x20, 0x60, 0x20, 0x20, 0x70 }, // 1
    [5]u8{ 0xF0, 0x10, 0xF0, 0x80, 0xF0 }, // 2
    [5]u8{ 0xF0, 0x10, 0xF0, 0x10, 0xF0 }, // 3
    [5]u8{ 0x90, 0x90, 0xF0, 0x10, 0x10 }, // 4
    [5]u8{ 0xF0, 0x80, 0xF0, 0x10, 0xF0 }, // 5
    [5]u8{ 0xF0, 0x80, 0xF0, 0x90, 0xF0 }, // 6
    [5]u8{ 0xF0, 0x10, 0x20, 0x40, 0x40 }, // 7
    [5]u8{ 0xF0, 0x90, 0xF0, 0x90, 0xF0 }, // 8
    [5]u8{ 0xF0, 0x90, 0xF0, 0x10, 0xF0 }, // 9
    [5]u8{ 0xF0, 0x90, 0xF0, 0x90, 0x90 }, // A
    [5]u8{ 0xE0, 0x90, 0xE0, 0x90, 0xE0 }, // B
    [5]u8{ 0xF0, 0x80, 0x80, 0x80, 0xF0 }, // C
    [5]u8{ 0xE0, 0x90, 0x90, 0x90, 0xE0 }, // D
    [5]u8{ 0xF0, 0x80, 0xF0, 0x80, 0xF0 }, // E
    [5]u8{ 0xF0, 0x80, 0xF0, 0x80, 0x80 }, // F
};
const SPRITE_CHARS_ADDR: u16 = 0x0000;

pub const Chip8 = struct {
    pub const SCREEN_WIDTH: usize = 64;
    pub const SCREEN_HEIGTH: usize = 32;
    const MEM_SIZE: usize = 0x1000;

    const Self = @This();

    allocator: *mem.Allocator,
    mem: []u8,
    v: [0x10]u8, // Register set
    i: u16, // Index Register
    pc: u16, // Program Counter
    stack: [0x10]u16,
    sp: u8, // Stack Pointer
    dt: u8, // Delay Timer
    st: u8, // Sound Timer
    keypad: u16, // Keypad
    fb: [SCREEN_WIDTH * SCREEN_HEIGTH / 8]u8, // Framebuffer
    tone: bool, // Tone output enable
    time: isize, // Overtime in microseconds

    pub fn init(allocator: *mem.Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .mem = try allocator.alloc(u8, MEM_SIZE),
            .v = [_]u8{0} ** 0x10,
            .i = 0,
            .pc = 0,
            .stack = [_]u16{0} ** 0x10,
            .sp = 0,
            .dt = 0,
            .st = 0,
            .keypad = 0,
            .fb = [_]u8{0} ** (SCREEN_WIDTH * SCREEN_HEIGTH / 8),
            .tone = false,
            .time = 0,
        };
        for (SPRITE_CHARS) |sprite, i| {
            const p = SPRITE_CHARS_ADDR + i * sprite.len;
            mem.copy(u8, self.mem[p .. p + sprite.len], sprite[0..]);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.mem);
    }
};
