const std = @import("std");

const MAX_LINE_LEN: usize = 1 << 11;
const MAX_FILE_SIZE: usize = 1 << 22;
const MAX_NUM_MATCHES: usize = 1 << 2;

pub fn smooth(allocator: std.mem.Allocator, in_dir_path: []const u8) !void {
    const cur_dir = std.fs.cwd();

    var in_dir = try cur_dir.openDir(in_dir_path, .{ .iterate = true });
    defer in_dir.close();

    const out_dir_path = try std.fmt.allocPrint(allocator, "{s}zig-{s}", .{ std.fs.path.dirname(in_dir_path) orelse "", std.fs.path.basename(in_dir_path) });
    defer allocator.free(out_dir_path);

    var out_dir = try cur_dir.makeOpenPath(out_dir_path, .{});
    defer out_dir.close();

    var walker = try in_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => if (std.mem.eql(u8, ".rs", std.fs.path.extension(entry.basename))) {
                const out_file_path = try std.fmt.allocPrint(allocator, "{s}zig", .{entry.path[0 .. entry.path.len - 2]});
                defer allocator.free(out_file_path);

                var out_file = try out_dir.createFile(out_file_path, .{});
                defer out_file.close();

                var buf_writer = std.io.bufferedWriter(out_file.writer());
                const writer = buf_writer.writer();

                var src_buf: [MAX_FILE_SIZE]u8 = undefined;
                const src = try entry.dir.readFile(entry.basename, src_buf[0..]);

                var line_iter = std.mem.tokenizeScalar(u8, src, '\n');
                var new_line_buf: [MAX_LINE_LEN]u8 = undefined;
                var new_line: []u8 = undefined;

                while (line_iter.next()) |line| {
                    new_line = @constCast(line);

                    // Trim left whitespace
                    const line_nws = std.mem.trimLeft(u8, new_line, std.ascii.whitespace[0..]);

                    // Skip line comments, attributes, and exports
                    if (std.mem.startsWith(u8, line_nws, "//") or
                        std.mem.startsWith(u8, line_nws, "///") or
                        std.mem.startsWith(u8, line_nws, "extern crate") or
                        std.mem.startsWith(u8, line_nws, "mod") and new_line[new_line.len - 1] == ';' or
                        std.mem.startsWith(u8, line_nws, "pub mod") and new_line[new_line.len - 1] == ';')
                    {
                        continue;
                    }

                    // Skip block comments
                    if (std.mem.startsWith(u8, line_nws, "/*")) {
                        while (!std.mem.endsWith(u8, new_line, "*/")) {
                            new_line = @constCast(line_iter.next().?);
                        }
                        continue;
                    }

                    // Skip multi-line imports
                    if (std.mem.startsWith(u8, line_nws, "use") or
                        std.mem.startsWith(u8, line_nws, "pub use"))
                    {
                        while (!std.mem.endsWith(u8, new_line, ";")) {
                            new_line = @constCast(line_iter.next().?);
                        }
                        continue;
                    }

                    // Skip multi-line attributes
                    if (std.mem.startsWith(u8, line_nws, "#[") or
                        std.mem.startsWith(u8, line_nws, "#!"))
                    {
                        while (!std.mem.endsWith(u8, new_line, "]")) {
                            new_line = @constCast(line_iter.next().?);
                        }
                        continue;
                    }

                    // Skip trait implementations
                    if (std.mem.startsWith(u8, new_line, "impl Drop") or
                        std.mem.startsWith(u8, new_line, "impl From") or
                        std.mem.startsWith(u8, new_line, "impl Into") or
                        std.mem.startsWith(u8, new_line, "impl AsMut") or
                        std.mem.startsWith(u8, new_line, "impl AsRef") or
                        std.mem.startsWith(u8, new_line, "impl TryFrom") or
                        std.mem.startsWith(u8, new_line, "impl TryInto") or
                        std.mem.startsWith(u8, new_line, "impl Default") or
                        std.mem.startsWith(u8, new_line, "impl Debug") or
                        std.mem.startsWith(u8, new_line, "impl fmt::Debug") or
                        std.mem.startsWith(u8, new_line, "impl core::fmt::Debug") or
                        std.mem.startsWith(u8, new_line, "impl Error") or
                        std.mem.startsWith(u8, new_line, "impl error::Error") or
                        std.mem.startsWith(u8, new_line, "impl std::error::Error") or
                        std.mem.startsWith(u8, new_line, "impl Display") or
                        std.mem.startsWith(u8, new_line, "impl fmt::Display") or
                        std.mem.startsWith(u8, new_line, "impl core::fmt::Display"))
                    {
                        while (new_line[0] != '}') {
                            new_line = @constCast(line_iter.next().?);
                        }
                        continue;
                    }

                    new_line = new_line_buf[0..new_line.len];
                    @memcpy(new_line, line);

                    // Remove " //..."
                    if (std.mem.indexOf(u8, new_line, " //")) |idx| {
                        new_line = new_line[0..idx];
                    }

                    // Remove "pub(...)"
                    while (std.mem.indexOf(u8, new_line, "pub(")) |start_idx| {
                        const end_idx = std.mem.indexOfScalarPos(u8, new_line, start_idx + 4, ')').? + 2;
                        std.mem.copyForwards(u8, new_line[start_idx..], new_line[end_idx..]);
                        new_line = new_line[0 .. new_line.len - end_idx + start_idx];
                    }

                    // Remove "pub " in "pub ...,"
                    if (std.mem.indexOf(u8, new_line, "pub ")) |idx| {
                        if (new_line[new_line.len - 1] == ',') {
                            std.mem.copyForwards(u8, new_line[idx..], new_line[idx + 4 ..]);
                            new_line = new_line[0 .. new_line.len - 4];
                        }
                    }

                    // Change "loop" to "while (true)"
                    if (std.mem.indexOf(u8, new_line, "loop ")) |idx| {
                        new_line = new_line_buf[0 .. new_line.len + 8];
                        std.mem.copyBackwards(u8, new_line[idx + 12 ..], new_line[idx + 4 .. new_line.len - 8]);
                        @memcpy(new_line[idx .. idx + 12], "while (true)");
                    }

                    // Change "while ... {" to "while (...) {"
                    if (std.mem.indexOf(u8, new_line, "while ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 6] != '{') {
                            new_line = new_line_buf[0 .. new_line.len + 2];
                            std.mem.copyBackwards(u8, new_line[idx + 7 ..], new_line[idx + 6 .. new_line.len - 2]);
                            new_line[idx + 6] = '(';
                            @memcpy(new_line[new_line.len - 3 ..], ") {");
                        }
                    }

                    // Change "if ... {" to "if (...) {"
                    if (std.mem.indexOf(u8, new_line, "if ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 3] != '{') {
                            new_line = new_line_buf[0 .. new_line.len + 2];
                            std.mem.copyBackwards(u8, new_line[idx + 4 ..], new_line[idx + 3 .. new_line.len - 2]);
                            new_line[idx + 3] = '(';
                            @memcpy(new_line[new_line.len - 3 ..], ") {");
                        }
                    }

                    // Change "match ... {" to "switch (...) {"
                    if (std.mem.indexOf(u8, new_line, "match ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 6] != '{') {
                            new_line = new_line_buf[0 .. new_line.len + 3];
                            std.mem.copyBackwards(u8, new_line[idx + 3 ..], new_line[idx + 2 .. new_line.len - 3]);
                            @memcpy(new_line[idx .. idx + 3], "swi");
                            std.mem.copyBackwards(u8, new_line[idx + 8 ..], new_line[idx + 7 .. new_line.len - 2]);
                            new_line[idx + 7] = '(';
                            @memcpy(new_line[new_line.len - 3 ..], ") {");
                        }
                    }

                    // Change "fn ...) {" to "fn ...) void {"
                    if (std.mem.indexOf(u8, new_line, "fn ")) |_| {
                        if (std.mem.eql(u8, new_line[new_line.len - 3 ..], ") {")) {
                            new_line = new_line_buf[0 .. new_line.len + 5];
                            @memcpy(new_line[new_line.len - 6 ..], "void {");
                        }
                    }

                    // Change "let mut" to "var"
                    while (std.mem.indexOf(u8, new_line, "let mut ")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 4 ..], new_line[idx + 8 ..]);
                        new_line = new_line[0 .. new_line.len - 4];
                        @memcpy(new_line[idx .. idx + 3], "var");
                    }

                    // Change "let" to "const"
                    while (std.mem.indexOf(u8, new_line, "let ")) |idx| {
                        new_line = new_line_buf[0 .. new_line.len + 2];
                        std.mem.copyBackwards(u8, new_line[idx + 6 ..], new_line[idx + 4 .. new_line.len - 2]);
                        @memcpy(new_line[idx .. idx + 6], "const ");
                    }

                    // Remove "'static " in "&'static "
                    while (std.mem.indexOf(u8, new_line, "&'static ")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 1 ..], new_line[idx + 9 ..]);
                        new_line = new_line[0 .. new_line.len - 8];
                    }

                    // Remove "'a " in "&'a " where "a" is any letter or underscore
                    for (0..MAX_NUM_MATCHES) |_| {
                        if (std.mem.indexOf(u8, new_line, "&'")) |idx| {
                            if (std.ascii.isAlphabetic(new_line[idx + 2]) or new_line[idx + 2] == '_') {
                                std.mem.copyForwards(u8, new_line[idx + 1 ..], new_line[idx + 4 ..]);
                                new_line = new_line[0 .. new_line.len - 3];
                            }
                        }
                    }

                    // Remove "<'a>" or "'a, " in "<'a, " where "a" is any letter or underscore
                    for (0..MAX_NUM_MATCHES) |_| {
                        if (std.mem.indexOf(u8, new_line, "<'")) |idx| {
                            if (std.ascii.isAlphabetic(new_line[idx + 2]) or new_line[idx + 2] == '_') {
                                if (new_line[idx + 3] == ',') {
                                    std.mem.copyForwards(u8, new_line[idx + 1 ..], new_line[idx + 5 ..]);
                                    new_line = new_line[0 .. new_line.len - 4];
                                } else if (new_line[idx + 3] == '>') {
                                    std.mem.copyForwards(u8, new_line[idx..], new_line[idx + 4 ..]);
                                    new_line = new_line[0 .. new_line.len - 4];
                                }
                            }
                        }
                    }

                    // Change "Option<...>" to "?..."
                    while (std.mem.indexOf(u8, new_line, "Option<")) |start_idx| {
                        new_line[start_idx] = '?';
                        std.mem.copyForwards(u8, new_line[start_idx + 1 ..], new_line[start_idx + 7 ..]);

                        if (std.mem.eql(u8, new_line[start_idx + 1 .. start_idx + 4], "()>")) {
                            @memcpy(new_line[start_idx + 1 .. start_idx + 5], "void");
                            std.mem.copyForwards(u8, new_line[start_idx + 5 ..], new_line[start_idx + 10 ..]);
                            new_line = new_line[0 .. new_line.len - 5];
                        } else {
                            var end_idx: usize = undefined;
                            var num_nestings: u8 = 1;
                            for (new_line[start_idx + 1 ..], start_idx + 1..) |char, idx| {
                                if (char == '<') {
                                    num_nestings += 1;
                                } else if (char == '>') {
                                    num_nestings -= 1;
                                    if (num_nestings == 0) {
                                        end_idx = idx;
                                        break;
                                    }
                                }
                            }
                            std.mem.copyForwards(u8, new_line[end_idx..], new_line[end_idx + 1 ..]);
                            new_line = new_line[0 .. new_line.len - 7];
                        }
                    }

                    // Change "&mut " to "*"
                    while (std.mem.indexOf(u8, new_line, "&mut ")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 1 ..], new_line[idx + 5 ..]);
                        new_line = new_line[0 .. new_line.len - 4];
                        new_line[idx] = '*';
                    }

                    // Change "&str" to "[]const u8"
                    while (std.mem.indexOf(u8, new_line, "&str")) |idx| {
                        new_line = new_line_buf[0 .. new_line.len + 6];
                        std.mem.copyBackwards(u8, new_line[idx + 10 ..], new_line[idx + 4 .. new_line.len - 6]);
                        @memcpy(new_line[idx .. idx + 10], "[]const u8");
                    }

                    // Change "::" to "."
                    while (std.mem.indexOf(u8, new_line, "::")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 1 ..], new_line[idx + 2 ..]);
                        new_line = new_line[0 .. new_line.len - 1];
                        new_line[idx] = '.';
                    }

                    // Remove "&" in "&self"
                    while (std.mem.indexOf(u8, new_line, "&self")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx..], new_line[idx + 1 ..]);
                        new_line = new_line[0 .. new_line.len - 1];
                    }

                    // Remove "&" in ": &"
                    while (std.mem.indexOf(u8, new_line, ": &")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 2 ..], new_line[idx + 3 ..]);
                        new_line = new_line[0 .. new_line.len - 1];
                    }

                    // Remove "()" in ".len()"
                    while (std.mem.indexOf(u8, new_line, ".len()")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx + 4 ..], new_line[idx + 6 ..]);
                        new_line = new_line[0 .. new_line.len - 2];
                    }

                    // Remove "-> "
                    while (std.mem.indexOf(u8, new_line, "-> ")) |idx| {
                        std.mem.copyForwards(u8, new_line[idx..], new_line[idx + 3 ..]);
                        new_line = new_line[0 .. new_line.len - 3];
                    }

                    // Change "||" to "or"
                    while (std.mem.indexOf(u8, new_line, "||")) |idx| {
                        @memcpy(new_line[idx .. idx + 2], "or");
                    }

                    // Change "&&" to "and"
                    while (std.mem.indexOf(u8, new_line, "&&")) |idx| {
                        new_line = new_line_buf[0 .. new_line.len + 1];
                        std.mem.copyBackwards(u8, new_line[idx + 3 ..], new_line[idx + 2 .. new_line.len - 1]);
                        @memcpy(new_line[idx .. idx + 3], "and");
                    }

                    try writer.writeAll(new_line);
                    try writer.writeByte('\n');
                }

                try buf_writer.flush();
            },
            .directory => {
                try out_dir.makePath(entry.path);
                continue;
            },
            else => continue,
        }
    }
}
