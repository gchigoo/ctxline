const std = @import("std");

const Allocator = std.mem.Allocator;

pub const EstimateOptions = struct {
    max_transcript_bytes: usize = 4 * 1024 * 1024,
    transcript_bytes_per_token: usize = 3,
};

const visible_keys = [_][]const u8{
    "content",
    "text",
    "tool_result",
    "message",
};

const skip_keys = [_][]const u8{
    "id",
    "uuid",
    "timestamp",
    "session_id",
    "parent_uuid",
    "role",
    "type",
    "model",
    "usage",
    "metadata",
};

pub fn estimateFromJsonlBytes(allocator: Allocator, bytes: []const u8, opts: EstimateOptions) u64 {
    var visible_bytes: u64 = 0;
    var start: usize = 0;
    var index: usize = 0;

    while (index <= bytes.len) : (index += 1) {
        if (index == bytes.len or bytes[index] == '\n') {
            if (index > start) {
                const line = std.mem.trim(u8, bytes[start..index], " \t\r\n");
                if (line.len > 0) {
                    visible_bytes +%= parseLineBytes(allocator, line, opts) orelse 0;
                }
            }
            start = index + 1;
        }
    }

    if (opts.transcript_bytes_per_token == 0) return 0;
    if (visible_bytes == 0) return 0;
    return (visible_bytes + opts.transcript_bytes_per_token - 1) / opts.transcript_bytes_per_token;
}

fn parseLineBytes(allocator: Allocator, line: []const u8, opts: EstimateOptions) ?u64 {
    _ = opts;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    return countVisibleBytes(parsed.value, false);
}

pub fn estimateFromJsonlFile(allocator: Allocator, path: []const u8, opts: EstimateOptions) u64 {
    const max = opts.max_transcript_bytes;
    const bytes = readFileLimited(allocator, path, max) catch return 0;
    defer allocator.free(bytes);
    return estimateFromJsonlBytes(allocator, bytes, opts);
}

fn readFileLimited(allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    if (max == 0) return try allocator.alloc(u8, 0);

    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.posix.system.close(fd);

    var output = try std.ArrayList(u8).initCapacity(allocator, @min(max, 4096));
    errdefer output.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    var remaining: usize = max;

    while (remaining > 0) {
        const read_len = @min(remaining, chunk.len);
        const bytes_read = try std.posix.read(fd, chunk[0..read_len]);
        if (bytes_read == 0) {
            break;
        }
        try output.appendSlice(allocator, chunk[0..bytes_read]);
        remaining -= bytes_read;
    }

    // A transcript can be much larger than the status-line budget. Keep the
    // bounded prefix instead of failing the whole estimate; any partial trailing
    // JSONL line will be ignored by the line parser.
    return output.toOwnedSlice(allocator);
}

fn countVisibleBytes(value: std.json.Value, visible_context: bool) u64 {
    return switch (value) {
        .string => |text| if (visible_context) text.len else 0,
        .array => |items| blk: {
            var total: u64 = 0;
            for (items.items) |entry| total +%= countVisibleBytes(entry, visible_context);
            break :blk total;
        },
        .object => |obj| blk: {
            var total: u64 = 0;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (isMetadataKey(key)) continue;
                const child_visible = visible_context or isVisibleKey(key);
                total +%= countVisibleBytes(entry.value_ptr.*, child_visible);
            }
            break :blk total;
        },
        else => 0,
    };
}

fn isVisibleKey(key: []const u8) bool {
    for (visible_keys) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn isMetadataKey(key: []const u8) bool {
    for (skip_keys) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

test "estimate visible transcript bytes from JSONL" {
    const allocator = std.testing.allocator;

    const lines =
        \\{"message":{"content":[{"type":"text","text":"hello"},{"text":"world"}]},"uuid":"x"}
        \\{"tool_result":{"output":{"message":{"content":"from"}}}}
        \\not-json
        \\{"metadata":{"text":"secret"},"content":"ok"}
        \\{"id":"m","type":"text"}
    ;
    const estimate = estimateFromJsonlBytes(allocator, lines, .{ .max_transcript_bytes = 10_000, .transcript_bytes_per_token = 3 });
    // visible bytes: "hello"(5) + "world"(5) + "from"(4) + "ok"(2) = 16 => ceil(16/3)=6
    try std.testing.expectEqual(@as(u64, 6), estimate);
    try std.testing.expect(estimate > 0);
}

test "file estimator keeps bounded prefix for oversized transcripts" {
    const allocator = std.testing.allocator;
    const path = "tmp_ctxline_large_transcript.jsonl";
    const first_line = "{\"content\":\"alpha\"}\n";
    const content = first_line ++ "{\"content\":\"this part is beyond the read cap\"}\n";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = content });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const estimate = estimateFromJsonlFile(allocator, path, .{
        .max_transcript_bytes = first_line.len,
        .transcript_bytes_per_token = 1,
    });
    try std.testing.expectEqual(@as(u64, 5), estimate);
}
