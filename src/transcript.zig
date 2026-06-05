const std = @import("std");

const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

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
                    visible_bytes = addVisibleBytes(visible_bytes, parseLineBytes(allocator, line, opts) orelse 0);
                }
            }
            start = index + 1;
        }
    }

    if (opts.transcript_bytes_per_token == 0) return 0;
    if (visible_bytes == 0) return 0;
    return std.math.divCeil(u64, visible_bytes, @as(u64, opts.transcript_bytes_per_token)) catch 0;
}

fn parseLineBytes(allocator: Allocator, line: []const u8, opts: EstimateOptions) ?u64 {
    _ = opts;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();

    return countVisibleBytes(parsed.value, false);
}

pub fn estimateFromJsonlFile(io: std.Io, allocator: Allocator, path: []const u8, opts: EstimateOptions) u64 {
    const max = opts.max_transcript_bytes;
    const bytes = readFileLimited(io, allocator, path, max) catch return 0;
    defer allocator.free(bytes);
    return estimateFromJsonlBytes(allocator, bytes, opts);
}

fn readFileLimited(io: std.Io, allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    if (max == 0) return try allocator.alloc(u8, 0);
    if (builtin.os.tag == .windows) return readFileLimitedWindows(io, allocator, path, max);

    return readFileLimitedPosix(allocator, path, max);
}

fn readFileLimitedPosix(allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    defer _ = std.posix.system.close(fd);
    try ensureRegularFile(fd);

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

fn readFileLimitedWindows(io: std.Io, allocator: Allocator, path: []const u8, max: usize) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    if (stat.kind != .file) return error.NotRegularFile;

    const file = try cwd.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var output = try std.ArrayList(u8).initCapacity(allocator, @min(max, 4096));
    errdefer output.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    var remaining: usize = max;
    var offset: u64 = 0;

    while (remaining > 0) {
        const read_len = @min(remaining, chunk.len);
        const bytes_read = try file.readPositional(io, &.{chunk[0..read_len]}, offset);
        if (bytes_read == 0) break;
        try output.appendSlice(allocator, chunk[0..bytes_read]);
        remaining -= bytes_read;
        offset += bytes_read;
    }

    // Keep the bounded prefix instead of failing on oversized transcripts.
    return output.toOwnedSlice(allocator);
}

fn ensureRegularFile(fd: std.posix.fd_t) !void {
    if (builtin.os.tag == .linux) return ensureRegularFileLinux(fd);
    return ensureRegularFilePosix(fd);
}

fn ensureRegularFileLinux(fd: std.posix.fd_t) !void {
    const linux = std.os.linux;
    var file_stat = std.mem.zeroes(linux.Statx);
    while (true) {
        switch (std.posix.errno(linux.statx(@intCast(fd), "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &file_stat))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.NotRegularFile,
        }
    }
    if ((file_stat.mode & linux.S.IFMT) != linux.S.IFREG) return error.NotRegularFile;
}

fn ensureRegularFilePosix(fd: std.posix.fd_t) !void {
    const fstat_sym = if (std.posix.lfs64_abi) std.posix.system.fstat64 else std.posix.system.fstat;
    var file_stat = std.mem.zeroes(std.posix.Stat);
    while (true) {
        switch (std.posix.errno(fstat_sym(fd, &file_stat))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.NotRegularFile,
        }
    }
    if ((file_stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG) return error.NotRegularFile;
}

fn countVisibleBytes(value: std.json.Value, visible_context: bool) u64 {
    return switch (value) {
        .string => |text| if (visible_context) text.len else 0,
        .array => |items| blk: {
            var total: u64 = 0;
            for (items.items) |entry| total = addVisibleBytes(total, countVisibleBytes(entry, visible_context));
            break :blk total;
        },
        .object => |obj| blk: {
            var total: u64 = 0;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (isMetadataKey(key)) continue;
                const child_visible = visible_context or isVisibleKey(key);
                total = addVisibleBytes(total, countVisibleBytes(entry.value_ptr.*, child_visible));
            }
            break :blk total;
        },
        else => 0,
    };
}

fn addVisibleBytes(current: u64, added: u64) u64 {
    const sum = @addWithOverflow(current, added);
    if (sum[1] != 0) return std.math.maxInt(u64);
    return sum[0];
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

    const estimate = estimateFromJsonlFile(std.testing.io, allocator, path, .{
        .max_transcript_bytes = first_line.len,
        .transcript_bytes_per_token = 1,
    });
    try std.testing.expectEqual(@as(u64, 5), estimate);
}

test "estimateFromJsonlBytes handles huge bytes-per-token values" {
    const allocator = std.testing.allocator;

    const estimate = estimateFromJsonlBytes(allocator, "{\"content\":\"hi\"}", .{
        .max_transcript_bytes = 1024,
        .transcript_bytes_per_token = std.math.maxInt(usize),
    });

    try std.testing.expectEqual(@as(u64, 1), estimate);
}

test "visible byte accumulator saturates on u64 overflow" {
    const near_max = std.math.maxInt(u64) - 10;

    try std.testing.expectEqual(std.math.maxInt(u64), addVisibleBytes(near_max, 11));
    try std.testing.expectEqual(std.math.maxInt(u64), addVisibleBytes(std.math.maxInt(u64), 1));
}

test "file estimator ignores non-regular paths" {
    const allocator = std.testing.allocator;
    const path = "tmp_ctxline_transcript_dir";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, path) catch {};

    const estimate = estimateFromJsonlFile(std.testing.io, allocator, path, .{
        .max_transcript_bytes = 1024,
        .transcript_bytes_per_token = 1,
    });

    try std.testing.expectEqual(@as(u64, 0), estimate);
}
