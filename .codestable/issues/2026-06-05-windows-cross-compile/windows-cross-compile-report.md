---
doc_type: issue-report
issue: 2026-06-05-windows-cross-compile
status: confirmed
severity: P1
tags: [windows, cross-compile, zig, cli]
---

# Windows cross-target 编译失败问题报告

## 1. 问题概述

`ctxline` README/发布目标需要覆盖 Claude Code statusLine CLI 的常见平台，但当前 Zig 0.16.0 下 Windows cross-target 无法编译。问题阻断 Windows artifact / Windows CI，以及 README 中 Windows 配置示例的可信度。

## 2. 复现步骤

在 `/Users/steven/Projects/ctxline` 执行：

```sh
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

当前失败点：

```text
src/main.zig:39:56: error: expected type '*anyopaque', found 'comptime_int'
const bytes_read = try std.posix.read(std.posix.STDIN_FILENO, chunk[0..read_len]);
```

进一步验证 library/test cross compile：

```sh
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

当前失败点：

```text
src/transcript.zig:70:49: error: struct 'c.AT__struct_35900' has no member named 'FDCWD'
const fd = try std.posix.openat(std.posix.AT.FDCWD, path, ...);
```

## 3. 期望行为

- `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast` 成功产出 Windows exe。
- `zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec` 至少能编译 library tests。
- macOS/Linux 当前 native 行为不退化：stdin JSON → one-line status 输出；transcript fallback 仍可读 regular file。
- POSIX transcript hardening 不退化：FIFO/special path 不应阻塞 statusLine。

## 4. 实际行为

- exe 编译在 `src/main.zig` 的 POSIX stdin/stdout API 上失败。
- library/test cross compile 在 `src/transcript.zig` 的 POSIX `openat` / `AT.FDCWD` 上失败。

## 5. 涉及模块

- `src/main.zig`：CLI stdin/stdout I/O。
- `src/transcript.zig`：transcript_path fallback 文件读取和 regular-file guard。
- `src/ctxline.zig`：context usage 主流程调用 transcript fallback。
- `.github/workflows/ci.yml`：CI 尚未覆盖 Windows cross compile。
