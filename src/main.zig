const std = @import("std");

const ctxline = @import("ctxline");

const usage_text =
    "Usage: ctxline [--help|-h] [--version]\n" ++
    "\n" ++
    "Reads Claude status JSON from stdin and prints a compact context meter.\n" ++
    "\n" ++
    "Options:\n" ++
    "  -h, --help      show usage and exit 0\n" ++
    "      --version   print `ctxline <version>` and exit 0\n" ++
    "\n" ++
    "Examples:\n" ++
    "  printf '{\"context_window\":{...}}' | ctxline\n" ++
    "  ctxline --help\n" ++
    "  ctxline --version";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (isHelpArg(arg)) {
                try writeLine(io, usage_text);
                return;
            }
            if (isVersionArg(arg)) {
                var version_buffer: [32]u8 = undefined;
                const version_line = try std.fmt.bufPrint(
                    &version_buffer,
                    "ctxline {s}",
                    .{ctxline.version},
                );
                try writeLine(io, version_line);
                return;
            }
        }
    }

    const options = ctxline.Options{};

    const input = readBoundedFromStdin(io, options.max_stdin_bytes) catch {
        try writeLine(io, ctxline.noStatusLine);
        return;
    };
    defer std.heap.page_allocator.free(input);

    const usage = ctxline.contextUsageFromStatusJson(io, std.heap.page_allocator, input, options) catch {
        try writeLine(io, ctxline.noStatusLine);
        return;
    };

    const line = ctxline.formatContextLine(std.heap.page_allocator, usage, options) catch {
        try writeLine(io, ctxline.noStatusLine);
        return;
    };
    defer std.heap.page_allocator.free(line);

    try writeLine(io, line);
}

fn readBoundedFromStdin(io: std.Io, max_bytes: usize) ![]u8 {
    if (max_bytes == 0) return try std.heap.page_allocator.alloc(u8, 0);

    var output = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, @min(max_bytes, 4096));
    errdefer output.deinit(std.heap.page_allocator);

    const stdin = std.Io.File.stdin();
    var chunk: [4096]u8 = undefined;
    var maxed_out = false;

    while (output.items.len < max_bytes) {
        const read_len = @min(max_bytes - output.items.len, chunk.len);
        const bytes_read = stdin.readStreaming(io, &.{chunk[0..read_len]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (bytes_read == 0) break;
        try output.appendSlice(std.heap.page_allocator, chunk[0..bytes_read]);

        // Stop reading once we have a complete JSON value.  This avoids
        // blocking forever on Windows where Claude Code may not close the
        // write pipe end after writing the status JSON.
        if (isCompleteTopLevelJsonValue(output.items)) break;
    }

    if (output.items.len >= max_bytes) {
        maxed_out = true;
    }

    if (maxed_out) {
        var extra: [1]u8 = undefined;
        const extra_bytes = stdin.readStreaming(io, &.{extra[0..]}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (extra_bytes > 0) return error.InvalidPayload;
    }

    return output.toOwnedSlice(std.heap.page_allocator);
}

/// Returns true when `data` starts with a complete JSON top-level value
/// (balanced {} or [], or a self-terminating primitive).  Uses brace/bracket
/// counting with string-awareness — necessary for statusLine JSON that may
/// contain literal braces inside string values.
fn isCompleteTopLevelJsonValue(data: []const u8) bool {
    if (data.len == 0) return false;

    const first = data[0];
    const opener: u8, const closer: u8 = switch (first) {
        '{' => .{ '{', '}' },
        '[' => .{ '[', ']' },
        else => return true, // primitives: string, number, bool, null are self-terminating
    };

    var depth: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == opener) {
            depth += 1;
        } else if (c == closer) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) return true;
        } else if (c == '"') {
            // Skip string content — including escaped characters
            i += 1;
            while (i < data.len) : (i += 1) {
                if (data[i] == '\\') {
                    i += 1; // skip the escaped character
                    if (i >= data.len) return false;
                } else if (data[i] == '"') {
                    break;
                }
            }
        }
    }
    return false;
}

fn writeLine(io: std.Io, text: []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(std.Io.File.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.writeAll(text);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version");
}
