const std = @import("std");
const clap = @import("clap");
const sandblast = @import("sandblast.zig");

const PARAMS = clap.parseParamsComptime(
    \\-h, --help   Display help.
    \\<str>        Input directory path.
    \\
);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Memory leak has occurred!");
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var res = try clap.parse(clap.Help, &PARAMS, clap.parsers.default, .{ .allocator = allocator });
    defer res.deinit();

    const input_dir_path = res.positionals[0];

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &PARAMS, .{});
    }

    try sandblast.smooth(allocator, input_dir_path);
}
