const clap = @import("clap");
const std = @import("std");

const debug = std.debug;
const io = std.io;

fn help(params: []const clap.Param(clap.Help)) !void {
    const stderr = io.getStdErr().writer();
    try stderr.print("Usage: {s} ", .{std.os.argv[0]});
    try clap.usage(stderr, params);
    try stderr.print("\n", .{});
    try clap.help(stderr, params);
}

pub fn main() !void {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help and exit.              ") catch unreachable,
        clap.parseParam("-s, --scale <NUM>      Scaling integer value.") catch unreachable,
        clap.parseParam("<ROM>") catch unreachable,
    };

    var diag = clap.Diagnostic{};
    var args = clap.parse(clap.Help, &params, .{ .diagnostic = &diag }) catch |err| {
        // Report useful error and exit
        diag.report(io.getStdErr().writer(), err) catch {};
        // return err;
        std.os.exit(1);
    };
    defer args.deinit();

    if (args.flag("--help")) {
        try help(&params);
        return;
    }
    var scale: u32 = blk: {
        if (args.option("--scale")) |n| {
            break :blk try std.fmt.parseUnsigned(u32, n, 10);
        } else {
            break :blk 4;
        }
    };
    var rom_path: []const u8 = blk: {
        const positionals = args.positionals();
        if (positionals.len != 1) {
            try help(&params);
            std.os.exit(1);
        } else {
            break :blk positionals[0];
        }
    };
}
