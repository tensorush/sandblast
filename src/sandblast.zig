const std = @import("std");

const MAX_FILE_SIZE: usize = 1 << 22;

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

                while (line_iter.next()) |line| {
                    var new_line = line;

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
                            new_line = line_iter.next().?;
                        }
                        continue;
                    }

                    // Skip multi-line imports
                    if (std.mem.startsWith(u8, line_nws, "use") or
                        std.mem.startsWith(u8, line_nws, "pub use"))
                    {
                        while (!std.mem.endsWith(u8, new_line, ";")) {
                            new_line = line_iter.next().?;
                        }
                        continue;
                    }

                    // Skip multi-line attributes
                    if (std.mem.startsWith(u8, line_nws, "#[") or
                        std.mem.startsWith(u8, line_nws, "#!"))
                    {
                        while (!std.mem.endsWith(u8, new_line, "]")) {
                            new_line = line_iter.next().?;
                        }
                        continue;
                    }

                    // Skip trait implementations
                    if (std.mem.startsWith(u8, new_line, "impl Drop") or
                        std.mem.startsWith(u8, new_line, "impl From") or
                        std.mem.startsWith(u8, new_line, "impl AsRef") or
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
                            new_line = line_iter.next().?;
                        }
                        continue;
                    }

                    // Skip "; //..."
                    if (std.mem.indexOf(u8, new_line, "; //")) |idx| {
                        new_line = new_line[0 .. idx + 1];
                    }

                    // Skip "pub(...)"
                    while (std.mem.indexOf(u8, new_line, "pub(")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        new_line = new_line[std.mem.indexOfScalarPos(u8, new_line, idx + 4, ')').? + 2 ..];
                    }

                    // Skip "pub " in "pub ...,"
                    if (std.mem.indexOf(u8, new_line, "pub ")) |idx| {
                        if (new_line[new_line.len - 1] == ',') {
                            try writer.writeAll(new_line[0..idx]);
                            new_line = new_line[idx + 4 ..];
                        }
                    }

                    // Change "loop" to "while (true)"
                    if (std.mem.indexOf(u8, new_line, "loop ")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("while (true)");
                        new_line = new_line[idx + 4 ..];
                    }

                    // Change "while ... {" to "while (...) {"
                    if (std.mem.indexOf(u8, new_line, "while ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 6] != '{') {
                            try writer.writeAll(new_line[0 .. idx + 6]);
                            try writer.writeByte('(');
                            try writer.writeAll(new_line[idx + 6 .. new_line.len - 2]);
                            try writer.writeByte(')');
                            new_line = new_line[new_line.len - 2 ..];
                        }
                    }

                    // Change "if ... {" to "if (...) {"
                    if (std.mem.indexOf(u8, new_line, "if ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 3] != '{') {
                            try writer.writeAll(new_line[0 .. idx + 3]);
                            try writer.writeByte('(');
                            try writer.writeAll(new_line[idx + 3 .. new_line.len - 2]);
                            try writer.writeByte(')');
                            new_line = new_line[new_line.len - 2 ..];
                        }
                    }

                    // Change "match ... {" to "switch (...) {"
                    if (std.mem.indexOf(u8, new_line, "match ")) |idx| {
                        if (new_line[new_line.len - 1] == '{' and new_line[idx + 6] != '{') {
                            try writer.writeAll(new_line[0..idx]);
                            try writer.writeAll("switch ");
                            try writer.writeByte('(');
                            try writer.writeAll(new_line[idx + 6 .. new_line.len - 2]);
                            try writer.writeByte(')');
                            new_line = new_line[new_line.len - 2 ..];
                        }
                    }

                    // Change "let mut" to "var"
                    while (std.mem.indexOf(u8, new_line, "let mut ")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("var");
                        new_line = new_line[idx + 7 ..];
                    }

                    // Change "let" to "const"
                    while (std.mem.indexOf(u8, new_line, "let ")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("const");
                        new_line = new_line[idx + 3 ..];
                    }

                    // Change "&mut " to "*"
                    while (std.mem.indexOf(u8, new_line, "&mut ")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("*");
                        new_line = new_line[idx + 5 ..];
                    }

                    // Change "&str" to "[]const u8"
                    while (std.mem.indexOf(u8, new_line, "&str")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("[]const u8");
                        new_line = new_line[idx + 4 ..];
                    }

                    // Change "::" to "."
                    while (std.mem.indexOf(u8, new_line, "::")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll(".");
                        new_line = new_line[idx + 2 ..];
                    }

                    // Skip "()" in ".len()"
                    while (std.mem.indexOf(u8, new_line, ".len()")) |idx| {
                        try writer.writeAll(new_line[0 .. idx + 4]);
                        new_line = new_line[idx + 6 ..];
                    }

                    // Skip "-> "
                    while (std.mem.indexOf(u8, new_line, "-> ")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        new_line = new_line[idx + 3 ..];
                    }

                    // Change "||" to "or" and "&&" to "and"
                    while (std.mem.indexOf(u8, new_line, "||")) |idx| {
                        var left_new_line = new_line[0..idx];
                        while (std.mem.indexOf(u8, left_new_line, "&&")) |idx2| {
                            try writer.writeAll(left_new_line[0..idx2]);
                            try writer.writeAll("and");
                            left_new_line = left_new_line[idx2 + 2 ..];
                        }
                        try writer.writeAll(left_new_line);
                        try writer.writeAll("or");
                        new_line = new_line[idx + 2 ..];
                    }

                    // Change remaining "&&" to "and"
                    while (std.mem.indexOf(u8, new_line, "&&")) |idx| {
                        try writer.writeAll(new_line[0..idx]);
                        try writer.writeAll("and");
                        new_line = new_line[idx + 2 ..];
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
