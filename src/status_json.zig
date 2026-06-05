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
        if (getChildFloat(context_window, "used_percentage")) |pct| info.used_percentage = pct;
        if (getChildU64(context_window, "total_input_tokens")) |v| info.total_input_tokens = v;
        if (getChildU64(context_window, "total_output_tokens")) |v| info.total_output_tokens = v;
        if (getChildU64(context_window, "context_window_size")) |v| info.context_window_size = v;
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

fn getChildFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const child = obj.get(key) orelse return null;
    return numberToF64(child);
}

fn getChildU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const child = obj.get(key) orelse return null;
    return numberToU64(child);
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
    const as_f64: ?f64 = switch (value) {
        .integer => |v| @as(f64, @floatFromInt(v)),
        .float => |v| v,
        .number_string => |v| std.fmt.parseFloat(f64, v) catch null,
        else => return null,
    };
    if (as_f64) |value_f64| {
        if (value_f64 < 0) return null;
        return @intFromFloat(value_f64);
    }
    return null;
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
