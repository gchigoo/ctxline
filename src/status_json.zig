const std = @import("std");

const Allocator = std.mem.Allocator;

pub const StatusError = error{
    InvalidPayload,
    MissingPayload,
};

pub const StatusInfo = struct {
    model_name: ?[]const u8 = null,
    used_percentage: ?f64 = null,
    total_input_tokens: ?u64 = null,
    total_output_tokens: ?u64 = null,
    context_window_size: ?u64 = null,
    transcript_path: ?[]const u8 = null,
    invalid_context_window: bool = false,
};

pub fn parseStatusInput(allocator: Allocator, bytes: []const u8) !StatusInfo {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch {
        return StatusError.InvalidPayload;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |value| value,
        else => return StatusError.InvalidPayload,
    };

    var info = StatusInfo{};

    if (getChildObjectValue(obj, "model")) |model_obj| {
        if (try getChildString(allocator, model_obj, "display_name")) |name| {
            info.model_name = name;
        }
        if (info.model_name == null) {
            info.model_name = try getChildString(allocator, model_obj, "id");
        }
    }

    if (getChildObjectValue(obj, "context_window")) |context_window| {
        parseNativePercent(context_window, "used_percentage", &info);
        parseNativeU64(context_window, "total_input_tokens", &info.total_input_tokens, &info.invalid_context_window, false);
        parseNativeU64(context_window, "total_output_tokens", &info.total_output_tokens, &info.invalid_context_window, false);
        parseNativeU64(context_window, "context_window_size", &info.context_window_size, &info.invalid_context_window, true);
    }

    if (try getChildString(allocator, obj, "transcript_path")) |path| {
        info.transcript_path = path;
    }

    return info;
}

fn getChildObjectValue(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const child = obj.get(key) orelse return null;
    return switch (child) {
        .object => |value| value,
        else => null,
    };
}

fn getChildString(allocator: Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const child = obj.get(key) orelse return null;
    const text: ?[]const u8 = switch (child) {
        .string => |value| value,
        else => null,
    };
    if (text) |value| {
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn parseNativePercent(obj: std.json.ObjectMap, key: []const u8, info: *StatusInfo) void {
    const child = obj.get(key) orelse return;
    const value = numberToF64(child) orelse {
        info.invalid_context_window = true;
        return;
    };
    info.used_percentage = sanitizeNativePercent(value) orelse {
        info.invalid_context_window = true;
        return;
    };
}

const max_native_context_window_size = 100_000_000;

fn parseNativeU64(
    obj: std.json.ObjectMap,
    key: []const u8,
    target: *?u64,
    invalid_context_window: *bool,
    require_non_zero: bool,
) void {
    const child = obj.get(key) orelse return;
    const value = numberToU64(child) orelse {
        invalid_context_window.* = true;
        return;
    };
    if (require_non_zero and (value == 0 or value > max_native_context_window_size)) {
        invalid_context_window.* = true;
        return;
    }
    target.* = value;
}

fn numberToF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |v| @as(f64, @floatFromInt(v)),
        .float => |v| v,
        .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => null,
    };
}

fn numberToU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |v| if (v >= 0) @as(u64, @intCast(v)) else null,
        .float => |v| exactU64FromFloat(v),
        .number_string => |v| std.fmt.parseInt(u64, v, 10) catch null,
        else => null,
    };
}

const max_exact_float_integer = 9_007_199_254_740_992.0;

fn exactU64FromFloat(raw: f64) ?u64 {
    if (!std.math.isFinite(raw)) return null;
    if (raw < 0.0) return null;
    if (raw > max_exact_float_integer) return null;
    if (@trunc(raw) != raw) return null;
    return @intFromFloat(raw);
}

fn sanitizeNativePercent(percent: f64) ?f64 {
    if (!std.math.isFinite(percent)) return null;
    if (percent < 0.0 or percent > 100.0) return null;
    return percent;
}

test "parse native status payload" {
    const allocator = std.testing.allocator;

    const raw = "{\"model\":{\"display_name\":\"deepseek-v4-pro[1m]\"},\"context_window\":{\"used_percentage\":38.2,\"total_input_tokens\":380000,\"total_output_tokens\":2000,\"context_window_size\":1000000}}";
    const status = try parseStatusInput(allocator, raw);

    try std.testing.expectEqualStrings("deepseek-v4-pro[1m]", status.model_name.?);
    try std.testing.expectApproxEqAbs(38.2, status.used_percentage.?, 0.0001);
    try std.testing.expectEqual(@as(u64, 380000), status.total_input_tokens.?);
    try std.testing.expectEqual(@as(u64, 2000), status.total_output_tokens.?);
    try std.testing.expectEqual(@as(u64, 1_000_000), status.context_window_size.?);
    try std.testing.expect(status.transcript_path == null);

    if (status.model_name) |model_name| allocator.free(model_name);
}

test "parse context window ignores invalid numeric fields" {
    const allocator = std.testing.allocator;

    const raw = "{\"model\":{\"id\":\"x\"},\"context_window\":{\"used_percentage\":150.1,\"total_input_tokens\":1.5,\"total_output_tokens\":-1,\"context_window_size\":0}}";
    const status = try parseStatusInput(allocator, raw);
    defer {
        if (status.model_name) |model_name| allocator.free(model_name);
    }

    try std.testing.expect(status.used_percentage == null);
    try std.testing.expect(status.total_input_tokens == null);
    try std.testing.expect(status.total_output_tokens == null);
    try std.testing.expect(status.context_window_size == null);
}
