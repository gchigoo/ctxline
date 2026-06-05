const std = @import("std");

const ctxline = @import("ctxline");

pub fn main() !void {
    const options = ctxline.Options{};

    const input = readBoundedFromStdin(options.max_stdin_bytes) catch {
        try writeLine(ctxline.noStatusLine);
        return;
    };
    defer std.heap.page_allocator.free(input);

    const usage = ctxline.contextUsageFromStatusJson(std.heap.page_allocator, input, options) catch {
        try writeLine(ctxline.noStatusLine);
        return;
    };

    const line = ctxline.formatContextLine(std.heap.page_allocator, usage, options) catch {
        try writeLine(ctxline.noStatusLine);
        return;
    };
    defer std.heap.page_allocator.free(line);

    try writeLine(line);
}

fn readBoundedFromStdin(max_bytes: usize) ![]u8 {
    if (max_bytes == 0) return try std.heap.page_allocator.alloc(u8, 0);

    var output = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, @min(max_bytes, 4096));
    errdefer output.deinit(std.heap.page_allocator);

    var chunk: [4096]u8 = undefined;
    var remaining = max_bytes;

    while (remaining > 0) {
        const read_len = @min(remaining, chunk.len);
        const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, chunk[0..read_len]);
        if (bytes_read == 0) break;
        try output.appendSlice(std.heap.page_allocator, chunk[0..bytes_read]);
        remaining -= bytes_read;
    }

    if (remaining == 0) {
        var extra: [1]u8 = undefined;
        if (try std.posix.read(std.posix.STDIN_FILENO, extra[0..]) > 0) return error.InvalidPayload;
    }

    return output.toOwnedSlice(std.heap.page_allocator);
}

fn writeLine(text: []const u8) !void {
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, text.ptr, text.len);
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, "\n".ptr, 1);
}
