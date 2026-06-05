const std = @import("std");

const Allocator = std.mem.Allocator;

pub const FormatError = error{InvalidPercent};

pub const FormatOptions = struct {
    bar_width: usize = 18,
};

pub fn clampPercent(raw: f64) f64 {
    if (raw < 0.0) return 0.0;
    if (raw > 100.0) return 100.0;
    return raw;
}

pub fn formatPercent(allocator: Allocator, percent: f64) ![]const u8 {
    const value = clampPercent(percent);
    if (value == @round(value)) {
        return std.fmt.allocPrint(allocator, "{d:.0}", .{value});
    }
    return std.fmt.allocPrint(allocator, "{d:.1}", .{value});
}

pub fn formatTokens(allocator: Allocator, token_count: u64) ![]const u8 {
    if (token_count < 1000) {
        return std.fmt.allocPrint(allocator, "{d}", .{token_count});
    }
    if (token_count >= 1_000_000) {
        return formatWithUnit(allocator, token_count, 1_000_000, "M", token_count == 1_000_000);
    }
    return formatWithUnit(allocator, token_count, 1000, "K", token_count == 1000);
}

fn formatWithUnit(allocator: Allocator, token_count: u64, unit: u64, suffix: []const u8, force_decimal: bool) ![]const u8 {
    const unit_count = @as(f64, @floatFromInt(token_count)) / @as(f64, @floatFromInt(unit));
    const exact_units = @mod(token_count, unit) == 0;
    if (exact_units and !force_decimal) {
        return std.fmt.allocPrint(allocator, "{d}{s}", .{ token_count / unit, suffix });
    }
    if (exact_units and force_decimal) {
        return std.fmt.allocPrint(allocator, "{d:.1}{s}", .{ unit_count, suffix });
    }
    return std.fmt.allocPrint(allocator, "{d:.1}{s}", .{ unit_count, suffix });
}

pub fn formatBar(allocator: Allocator, percent: f64, width: usize) ![]const u8 {
    const safe_percent = clampPercent(percent);
    const filled_float = @round((safe_percent * @as(f64, @floatFromInt(width))) / 100.0);
    const filled = @min(width, @as(usize, @intFromFloat(filled_float)));
    const filled_chars = "█";
    const empty_chars = "░";
    const cell_width = filled_chars.len;
    std.debug.assert(cell_width == empty_chars.len);

    var bar = try allocator.alloc(u8, width * cell_width);
    var bar_length: usize = 0;
    var index: usize = 0;
    while (index < width) : (index += 1) {
        const cell = if (index < filled) filled_chars else empty_chars;
        @memcpy(bar[bar_length .. bar_length + cell.len], cell);
        bar_length += cell.len;
    }
    return bar;
}

pub fn formatStatusLine(allocator: Allocator, model: []const u8, percent: f64, used_tokens: u64, max_tokens: u64, opts: FormatOptions) ![]const u8 {
    const percent_text = try formatPercent(allocator, percent);
    defer allocator.free(percent_text);
    const used_text = try formatTokens(allocator, used_tokens);
    defer allocator.free(used_text);
    const max_text = try formatTokens(allocator, max_tokens);
    defer allocator.free(max_text);
    const bar = try formatBar(allocator, percent, opts.bar_width);
    defer allocator.free(bar);

    return std.fmt.allocPrint(
        allocator,
        "{s} │ ctx {s}% │ {s}/{s} │ {s}",
        .{ model, percent_text, used_text, max_text, bar },
    );
}

test "format token boundaries" {
    const allocator = std.testing.allocator;

    const exact = try formatTokens(allocator, 999);
    defer allocator.free(exact);
    try std.testing.expectEqualStrings("999", exact);

    const kilo = try formatTokens(allocator, 1000);
    defer allocator.free(kilo);
    try std.testing.expectEqualStrings("1.0K", kilo);

    const three_eight_two = try formatTokens(allocator, 382_000);
    defer allocator.free(three_eight_two);
    try std.testing.expectEqualStrings("382K", three_eight_two);

    const million = try formatTokens(allocator, 1_000_000);
    defer allocator.free(million);
    try std.testing.expectEqualStrings("1.0M", million);
}

test "format bar rounds to nearest cell and supports custom widths" {
    const allocator = std.testing.allocator;

    const bar = try formatBar(allocator, 38.2, 18);
    defer allocator.free(bar);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, bar, "█"));
    try std.testing.expectEqual(@as(usize, 11), std.mem.count(u8, bar, "░"));

    const wide = try formatBar(allocator, 50.0, 32);
    defer allocator.free(wide);
    try std.testing.expectEqual(@as(usize, 16), std.mem.count(u8, wide, "█"));
    try std.testing.expectEqual(@as(usize, 16), std.mem.count(u8, wide, "░"));
}
