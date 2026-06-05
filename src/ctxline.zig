const std = @import("std");

const models = @import("models.zig");
const status_json = @import("status_json.zig");
const transcript = @import("transcript.zig");
const format = @import("format.zig");

pub const Mode = enum { native, transcript, fallback };

pub const ContextUsage = struct {
    model: []const u8,
    used_tokens: u64,
    max_tokens: u64,
    percent: f64,
    mode: Mode,
};

pub const Options = struct {
    max_stdin_bytes: usize = 256 * 1024,
    max_transcript_bytes: usize = 4 * 1024 * 1024,
    transcript_bytes_per_token: usize = 3,
    bar_width: usize = 18,
};

pub const noStatusLine = "ctxline │ no status json";
const fallback_model = "ctxline";

pub fn contextUsageFromStatusJson(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
) !ContextUsage {
    const status = try status_json.parseStatusInput(allocator, input);
    const model = if (status.model_name) |value| try allocator.dupe(u8, value) else fallback_model;
    defer {
        if (status.model_name) |model_name| allocator.free(model_name);
        if (status.transcript_path) |transcript_path| allocator.free(transcript_path);
    }
    const max_tokens = status.context_window_size orelse models.contextWindowForModel(model);
    const has_native_pct = status.used_percentage != null;
    const has_native_tokens = status.total_input_tokens != null or status.total_output_tokens != null;

    if (has_native_pct or has_native_tokens) {
        const pct = status.used_percentage orelse
            estimatePercentFromCounts(status.total_input_tokens, status.total_output_tokens, max_tokens);
        const used = if (has_native_tokens)
            ((status.total_input_tokens orelse 0) + (status.total_output_tokens orelse 0))
        else if (status.used_percentage) |used_percentage|
            estimateTokensFromPercent(used_percentage, max_tokens)
        else
            estimateTokensFromPercent(pct, max_tokens);

        return ContextUsage{
            .model = model,
            .used_tokens = used,
            .max_tokens = max_tokens,
            .percent = pct,
            .mode = .native,
        };
    }

    if (status.transcript_path) |transcript_path| {
        const estimate_opts = transcript.EstimateOptions{
            .max_transcript_bytes = options.max_transcript_bytes,
            .transcript_bytes_per_token = options.transcript_bytes_per_token,
        };
        const used_tokens = transcript.estimateFromJsonlFile(allocator, transcript_path, estimate_opts);
        const pct = estimatePercentFromCounts(used_tokens, 0, max_tokens);

        return ContextUsage{
            .model = model,
            .used_tokens = used_tokens,
            .max_tokens = max_tokens,
            .percent = pct,
            .mode = .transcript,
        };
    }

    return ContextUsage{
        .model = model,
        .used_tokens = 0,
        .max_tokens = max_tokens,
        .percent = 0.0,
        .mode = .fallback,
    };
}

fn estimateTokensFromPercent(percent: f64, max_tokens: u64) u64 {
    if (max_tokens == 0) return 0;
    return @intFromFloat(std.math.floor((percent * @as(f64, @floatFromInt(max_tokens))) / 100.0));
}

fn estimatePercentFromCounts(used_tokens: ?u64, output_tokens: ?u64, max_tokens: u64) f64 {
    const max = @as(f64, @floatFromInt(max_tokens));
    if (max == 0) return 0.0;
    const used = @as(f64, @floatFromInt((used_tokens orelse 0) + (output_tokens orelse 0)));
    return (used / max) * 100.0;
}

pub fn formatContextLine(
    allocator: std.mem.Allocator,
    usage: ContextUsage,
    options: Options,
) ![]const u8 {
    return format.formatStatusLine(
        allocator,
        usage.model,
        usage.percent,
        usage.used_tokens,
        usage.max_tokens,
        .{ .bar_width = options.bar_width },
    );
}

test "native context usage from status line" {
    const allocator = std.testing.allocator;

    const input = "{\"model\":{\"id\":\"deepseek-v4-pro[1m]\"},\"context_window\":{\"used_percentage\":38.2,\"total_input_tokens\":380000,\"total_output_tokens\":2000,\"context_window_size\":1000000}}";
    const usage = try contextUsageFromStatusJson(
        allocator,
        input,
        .{},
    );
    defer {
        if (!std.mem.eql(u8, usage.model, fallback_model)) allocator.free(usage.model);
    }
    try std.testing.expectEqual(Mode.native, usage.mode);
    try std.testing.expectEqualStrings("deepseek-v4-pro[1m]", usage.model);
    try std.testing.expectEqual(@as(u64, 382000), usage.used_tokens);
    try std.testing.expectEqual(@as(u64, 1_000_000), usage.max_tokens);
    try std.testing.expectApproxEqAbs(38.2, usage.percent, 0.0001);
}

test "derive native used tokens from percentage" {
    const allocator = std.testing.allocator;

    const input = "{\"model\":{\"display_name\":\"deepseek-v4-flash\"},\"context_window\":{\"used_percentage\":25.0,\"context_window_size\":128000}}";
    const usage = try contextUsageFromStatusJson(
        allocator,
        input,
        .{},
    );
    defer {
        if (!std.mem.eql(u8, usage.model, fallback_model)) allocator.free(usage.model);
    }
    try std.testing.expectEqual(Mode.native, usage.mode);
    try std.testing.expectEqualStrings("deepseek-v4-flash", usage.model);
    try std.testing.expectEqual(@as(u64, 32000), usage.used_tokens);
    try std.testing.expectApproxEqAbs(25.0, usage.percent, 0.0001);
}

test "transcript fallback usage" {
    const allocator = std.testing.allocator;

    const bytes =
        \\{"message":{"content":"hello world from transcript"}}
    ;
    const path = "tmp_ctxline_transcript.jsonl";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    const input = "{\"model\":{\"id\":\"deepseek-v4-flash\"},\"transcript_path\":\"tmp_ctxline_transcript.jsonl\"}";
    const usage = try contextUsageFromStatusJson(
        allocator,
        input,
        .{},
    );
    try std.testing.expectEqual(Mode.transcript, usage.mode);
    try std.testing.expectEqualStrings("deepseek-v4-flash", usage.model);
    try std.testing.expectEqual(@as(u64, models.flash_window), usage.max_tokens);
    try std.testing.expect(usage.percent >= 0.0);
    defer {
        if (!std.mem.eql(u8, usage.model, fallback_model)) allocator.free(usage.model);
    }

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
}

test "malformed status json is surfaced by caller" {
    const allocator = std.testing.allocator;

    const input = "not json";
    try std.testing.expectError(error.InvalidPayload, status_json.parseStatusInput(allocator, input));
    try std.testing.expectError(error.InvalidPayload, contextUsageFromStatusJson(
        allocator,
        input,
        .{},
    ));
}

test "output formatting is one line and safe" {
    const allocator = std.testing.allocator;

    const usage = ContextUsage{
        .model = "deepseek-v4-flash",
        .used_tokens = 3800,
        .max_tokens = models.flash_window,
        .percent = 2.5,
        .mode = .transcript,
    };
    const line = try formatContextLine(allocator, usage, .{});
    defer allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\n") == null);
    try std.testing.expect(std.mem.startsWith(u8, line, "deepseek-v4-flash"));
    const bar_count = std.mem.count(u8, line, "█");
    const blank_count = std.mem.count(u8, line, "░");
    try std.testing.expectEqual(@as(usize, 18), bar_count + blank_count);
}
