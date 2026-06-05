const std = @import("std");

pub fn contextWindowForModel(model_name: ?[]const u8) u64 {
    const name = model_name orelse return unknown_window;

    if (equalIgnoreCase(name, "deepseek-v4-pro[1m]")) return million_window;
    if (equalIgnoreCase(name, "deepseek-v4-pro")) return million_window;
    if (equalIgnoreCase(name, "deepseek-v4-flash")) return flash_window;
    if (containsIgnoreCase(name, "claude") and containsIgnoreCase(name, "1m")) return million_window;

    return unknown_window;
}

fn equalIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    return std.ascii.eqlIgnoreCase(left, right);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        const window = haystack[i .. i + needle.len];
        if (std.ascii.eqlIgnoreCase(window, needle)) return true;
    }
    return false;
}

pub const million_window = 1_000_000;
pub const flash_window = 128_000;
pub const unknown_window = 200_000;

test "model mapping" {
    try std.testing.expectEqual(million_window, contextWindowForModel("deepseek-v4-pro[1m]"));
    try std.testing.expectEqual(million_window, contextWindowForModel("deepseek-v4-pro"));
    try std.testing.expectEqual(flash_window, contextWindowForModel("deepseek-v4-flash"));
    try std.testing.expectEqual(million_window, contextWindowForModel("claude-opus-4.1m"));
    try std.testing.expectEqual(unknown_window, contextWindowForModel("random-unknown-model"));
    try std.testing.expectEqual(unknown_window, contextWindowForModel(null));
}
