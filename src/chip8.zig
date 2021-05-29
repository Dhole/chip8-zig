const std = @import("std");

const log = std.log;
const mem = std.mem;

pub const FRAME_TIME: isize = 16666; // In microseconds

const SPRITE_CHAR_LEN: usize = 5;
const SPRITE_CHARS: [0x10][SPRITE_CHAR_LEN]u8 = [0x10][SPRITE_CHAR_LEN]u8{
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x90, 0x90, 0x90, 0xF0 }, // 0
    [SPRITE_CHAR_LEN]u8{ 0x20, 0x60, 0x20, 0x20, 0x70 }, // 1
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x10, 0xF0, 0x80, 0xF0 }, // 2
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x10, 0xF0, 0x10, 0xF0 }, // 3
    [SPRITE_CHAR_LEN]u8{ 0x90, 0x90, 0xF0, 0x10, 0x10 }, // 4
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x80, 0xF0, 0x10, 0xF0 }, // 5
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x80, 0xF0, 0x90, 0xF0 }, // 6
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x10, 0x20, 0x40, 0x40 }, // 7
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x90, 0xF0, 0x90, 0xF0 }, // 8
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x90, 0xF0, 0x10, 0xF0 }, // 9
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x90, 0xF0, 0x90, 0x90 }, // A
    [SPRITE_CHAR_LEN]u8{ 0xE0, 0x90, 0xE0, 0x90, 0xE0 }, // B
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x80, 0x80, 0x80, 0xF0 }, // C
    [SPRITE_CHAR_LEN]u8{ 0xE0, 0x90, 0x90, 0x90, 0xE0 }, // D
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x80, 0xF0, 0x80, 0xF0 }, // E
    [SPRITE_CHAR_LEN]u8{ 0xF0, 0x80, 0xF0, 0x80, 0x80 }, // F
};
const SPRITE_CHARS_ADDR: u16 = 0x0000;

fn nnn(w0: u8, w1: u8) u16 {
    return @intCast(u16, w0 & 0x0f) << 8 | @intCast(u16, w1);
}

/// Returns low nibble from byte
fn lo_nib(b: u8) u8 {
    return b & 0x0f;
}
/// Returns high nibble from byte
fn hi_nib(b: u8) u8 {
    return (b & 0xf0) >> 4;
}

fn shr1WithOverflow(comptime T: type, a: T, result: *T) bool {
    const overflow = a & 1 != 0;
    result.* = a >> 1;
    return overflow;
}

pub fn testBit(v: u16, b: usize) bool {
    return (@as(u16, 1) << @intCast(u4, b)) & v != 0;
}

pub const Chip8 = struct {
    pub const SCREEN_WIDTH: usize = 64;
    pub const SCREEN_HEIGTH: usize = 32;
    pub const MEM_SIZE: usize = 0x1000;
    const ROM_ADDR: usize = 0x200;

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
    rng: std.rand.DefaultPrng,

    pub fn init(allocator: *mem.Allocator, seed: u64) !Self {
        var self = Self{
            .allocator = allocator,
            .mem = try allocator.alloc(u8, MEM_SIZE),
            .v = [_]u8{0} ** 0x10,
            .i = 0,
            .pc = ROM_ADDR,
            .stack = [_]u16{0} ** 0x10,
            .sp = 0,
            .dt = 0,
            .st = 0,
            .keypad = 0,
            .fb = [_]u8{0} ** (SCREEN_WIDTH * SCREEN_HEIGTH / 8),
            .tone = false,
            .time = 0,
            .rng = std.rand.DefaultPrng.init(seed),
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

    /// Load a rom into Chip8 memory
    pub fn load_rom(self: *Self, rom: []const u8) !void {
        if (rom.len > MEM_SIZE - ROM_ADDR) {
            return error.RomTooBig;
        }
        mem.copy(u8, self.mem[ROM_ADDR .. ROM_ADDR + rom.len], rom);
    }
    /// Whether a tone must be played
    pub fn tone_on(self: *Self) bool {
        return self.tone;
    }
    /// Framebuffer view
    pub fn framebuffer(self: *Self) *[SCREEN_WIDTH * SCREEN_HEIGTH / 8]u8 {
        return &self.fb;
    }
    /// Emulates the execution of instructions continuously until the emulated instructions total
    /// elapsed time reaches the equivalent of a frame.
    pub fn frame(self: *Self, keypad: u16) !void {
        self.keypad = keypad;
        if (self.dt != 0) {
            self.dt -= 1;
        }
        self.tone = self.st != 0;
        if (self.st != 0) {
            self.st -= 1;
        }
        self.time += FRAME_TIME;

        while (self.time > 0) {
            if (self.pc > MEM_SIZE - 1) {
                return error.PcOutOfBounds;
            }
            const w0 = self.mem[self.pc];
            const w1 = self.mem[self.pc + 1];
            const adv = try self.exec(w0, w1);
            self.time -= @intCast(isize, adv);
        }
    }

    /// Op: Clear the display.
    fn op_cls(self: *Self) usize {
        for (self.fb) |*b| {
            b.* = 0;
        }
        self.pc += 2;
        return 109;
    }
    fn op_call_rca_1802(self: *Self, _addr: u16) usize {
        return 100;
    }
    /// Op: Return from a subroutine.
    fn op_ret(self: *Self) usize {
        self.sp -= 1;
        self.pc = self.stack[self.sp];
        return 105;
    }
    /// Op: Jump to addr.
    fn op_jp(self: *Self, addr: u16) usize {
        self.pc = addr;
        return 105;
    }
    /// Op: Call subroutine at addr.
    fn op_call(self: *Self, addr: u16) usize {
        self.stack[self.sp] = self.pc + 2;
        self.sp += 1;
        self.pc = addr;
        return 105;
    }
    /// Op: Skip next instruction if a == b.
    fn op_se(self: *Self, a: u8, b: u8) usize {
        if (a == b) {
            self.pc += 4;
        } else {
            self.pc += 2;
        }
        return 61;
    }
    /// Op: Skip next instruction if a != b.
    fn op_sne(self: *Self, a: u8, b: u8) usize {
        if (a != b) {
            self.pc += 4;
        } else {
            self.pc += 2;
        }
        return 61;
    }
    /// Op: Set Vx = v.
    fn op_ld(self: *Self, x: u8, v: u8) usize {
        self.v[x] = v;
        self.pc += 2;
        return 27;
    }
    /// Op: Wait for a key press, store the value of the key in Vx.
    fn op_ld_vx_k(self: *Self, x: u8) usize {
        var i: u8 = 0;
        while (i < 0x10) : (i += 1) {
            if (testBit(self.keypad, i)) {
                self.v[x] = i;
                self.pc += 2;
                break;
            }
        }
        return 200;
    }
    /// Op: Set delay timer = Vx.
    fn op_ld_dt(self: *Self, v: u8) usize {
        self.dt = v;
        self.pc += 2;
        return 45;
    }
    /// Op: Set sound timer = Vx.
    fn op_ld_st(self: *Self, v: u8) usize {
        self.st = v;
        self.pc += 2;
        return 45;
    }
    /// Op: Set I = location of sprite for digit v.
    fn op_ld_f(self: *Self, v: u8) usize {
        self.i = SPRITE_CHARS_ADDR + v * @as(u16, SPRITE_CHAR_LEN);
        self.pc += 2;
        return 91;
    }
    /// Op: Store BCD representation of v in memory locations I, I+1, and I+2.
    fn op_ld_b(self: *Self, _v: u8) usize {
        var v = _v;
        const d2 = v / 100;
        v = v - d2 * 100;
        const d1 = v / 10;
        v = v - d1 * 10;
        const d0 = v / 1;
        self.mem[self.i + 0] = d2;
        self.mem[self.i + 1] = d1;
        self.mem[self.i + 2] = d0;
        self.pc += 2;
        return 927;
    }

    /// Op: Store registers V0 through Vx in memory starting at location I.
    fn op_ld_i_vx(self: *Self, x: u8) usize {
        var i: usize = 0;
        while (i < x + 1) : (i += 1) {
            self.mem[self.i + i] = self.v[i];
        }
        self.pc += 2;
        return 605;
    }
    /// Op: Read registers V0 through Vx from memory starting at location I.
    fn op_ld_vx_i(self: *Self, x: u8) usize {
        var i: usize = 0;
        while (i < x + 1) : (i += 1) {
            self.v[i] = self.mem[self.i + i];
        }
        self.pc += 2;
        return 605;
    }
    /// Op: Set Vx = Vx + b.
    fn op_add(self: *Self, x: u8, b: u8) usize {
        const overflow = @addWithOverflow(u8, self.v[x], b, &self.v[x]);
        self.v[0xf] = if (overflow) 1 else 0;
        self.pc += 2;
        return 45;
    }
    /// Op: Set I = I + b.
    fn op_add16(self: *Self, b: u8) usize {
        self.i += b;
        self.pc += 2;
        return 86;
    }
    /// Op: Set Vx = Vx OR b.
    fn op_or(self: *Self, x: u8, b: u8) usize {
        self.v[x] |= b;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = Vx AND b.
    fn op_and(self: *Self, x: u8, b: u8) usize {
        self.v[x] &= b;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = Vx XOR b.
    fn op_xor(self: *Self, x: u8, b: u8) usize {
        self.v[x] ^= b;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = Vx - b.
    fn op_sub(self: *Self, x: u8, b: u8) usize {
        const overflow = @subWithOverflow(u8, self.v[x], b, &self.v[x]);
        self.v[0xf] = if (overflow) 1 else 0;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = b - Vx, set Vf = NOT borrow.
    fn op_subn(self: *Self, x: u8, b: u8) usize {
        const overflow = @subWithOverflow(u8, self.v[x], b, &self.v[x]);
        self.v[0xf] = if (overflow) 0 else 1;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = Vx >> 1.
    fn op_shr(self: *Self, x: u8) usize {
        const overflow = shr1WithOverflow(u8, self.v[x], &self.v[x]);
        self.v[0xf] = if (overflow) 1 else 0;
        self.pc += 2;
        return 200;
    }
    /// Op: Set Vx = Vx << 1.
    fn op_shl(self: *Self, x: u8) usize {
        const overflow = @shlWithOverflow(u8, self.v[x], 1, &self.v[x]);
        self.v[0xf] = if (overflow) 1 else 0;
        self.pc += 2;
        return 200;
    }
    /// Op: Set I = addr
    fn op_ld_i(self: *Self, addr: u16) usize {
        self.i = addr;
        self.pc += 2;
        return 55;
    }
    /// Op: Set Vx = random byte AND v
    fn op_rnd(self: *Self, x: u8, v: u8) usize {
        self.v[x] = (self.rng.random.int(u8)) & v;
        self.pc += 2;
        return 164;
    }
    /// Op: Display n-byte sprite starting at memory location I at (Vx, Vy), set VF = collision.
    fn op_drw(self: *Self, _pos_x: u8, _pos_y: u8, n: u8) usize {
        const pos_x = _pos_x % 64;
        const pos_y = _pos_y % 32;
        const shift = pos_x % 8;
        const col_a = pos_x / 8;
        const col_b = (col_a + 1) % (SCREEN_WIDTH / 8);
        var collision: u8 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const byte = self.mem[self.i + i];
            const y = (pos_y + i) % SCREEN_HEIGTH;
            const a = byte >> @intCast(u3, shift);
            var fb_a = &self.fb[y * SCREEN_WIDTH / 8 + col_a];
            collision |= fb_a.* & a;
            fb_a.* ^= a;
            if (shift != 0) {
                const b = byte << @intCast(u3, 8 - shift);
                var fb_b = &self.fb[y * SCREEN_WIDTH / 8 + col_b];
                collision |= fb_b.* & b;
                fb_b.* ^= b;
            }
        }
        self.v[0xf] = if (collision != 0) 1 else 0;
        self.pc += 2;
        return 22734;
    }
    /// Op: Skip next instruction if key with the value of v is pressed.
    fn op_skp(self: *Self, v: u8) usize {
        if (testBit(self.keypad, v)) {
            self.pc += 4;
        } else {
            self.pc += 2;
        }
        return 73;
    }
    /// Op: Skip next instruction if key with the value of v is not pressed.
    fn op_sknp(self: *Self, v: u8) usize {
        if (!testBit(self.keypad, v)) {
            self.pc += 4;
        } else {
            self.pc += 2;
        }
        return 73;
    }

    /// Execute the instruction defined by (w0, w1).  Returns the number of microseconds elapsed.
    fn exec(self: *Self, w0: u8, w1: u8) !usize {
        return switch (w0 & 0xf0) {
            0x00 => switch (w1) {
                0xe0 => self.op_cls(),
                0xee => self.op_ret(),
                else => self.op_call_rca_1802(nnn(w0, w1)),
            },
            0x10 => self.op_jp(nnn(w0, w1)),
            0x20 => self.op_call(nnn(w0, w1)),
            0x30 => self.op_se(self.v[lo_nib(w0)], w1),
            0x40 => self.op_sne(self.v[lo_nib(w0)], w1),
            0x50 => self.op_se(self.v[lo_nib(w0)], self.v[hi_nib(w1)]),
            0x60 => self.op_ld(lo_nib(w0), w1),
            0x70 => self.op_add(lo_nib(w0), w1),
            0x80 => blk: {
                const a = lo_nib(w0);
                const b = self.v[hi_nib(w1)];
                break :blk switch (w1 & 0x0f) {
                    0x00 => self.op_ld(a, b),
                    0x01 => self.op_or(a, b),
                    0x02 => self.op_and(a, b),
                    0x03 => self.op_xor(a, b),
                    0x04 => self.op_add(a, b),
                    0x05 => self.op_sub(a, b),
                    0x06 => self.op_shr(a),
                    0x07 => self.op_subn(a, b),
                    0x0E => self.op_shl(a),
                    else => return error.InvalidOp,
                };
            },
            0x90 => switch (w1 & 0x0f) {
                0x00 => self.op_sne(self.v[lo_nib(w0)], self.v[hi_nib(w1)]),
                else => return error.InvalidOp,
            },
            0xA0 => self.op_ld_i(nnn(w0, w1)),
            0xB0 => self.op_jp(self.v[0] + nnn(w0, w1)),
            0xC0 => self.op_rnd(lo_nib(w0), w1),
            0xD0 => self.op_drw(self.v[lo_nib(w0)], self.v[hi_nib(w1)], lo_nib(w1)),
            0xE0 => switch (w1) {
                0x9E => self.op_skp(self.v[lo_nib(w0)]),
                0xA1 => self.op_sknp(self.v[lo_nib(w0)]),
                else => return error.InvalidOp,
            },
            0xF0 => switch (w1) {
                0x07 => self.op_ld(lo_nib(w0), self.dt),
                0x0A => self.op_ld_vx_k(lo_nib(w0)),
                0x15 => self.op_ld_dt(self.v[lo_nib(w0)]),
                0x18 => self.op_ld_st(self.v[lo_nib(w0)]),
                0x1E => self.op_add16(self.v[lo_nib(w0)]),
                0x29 => self.op_ld_f(self.v[lo_nib(w0)]),
                0x33 => self.op_ld_b(self.v[lo_nib(w0)]),
                0x55 => self.op_ld_i_vx(lo_nib(w0)),
                0x65 => self.op_ld_vx_i(lo_nib(w0)),
                else => return error.InvalidOp,
            },
            else => return error.InvalidOp,
        };
    }
};
