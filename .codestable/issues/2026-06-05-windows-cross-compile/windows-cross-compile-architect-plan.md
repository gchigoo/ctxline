---
doc_type: issue-plan
issue: 2026-06-05-windows-cross-compile
status: confirmed
source: codex-architect
related: [windows-cross-compile-report.md, windows-cross-compile-analysis.md]
tags: [windows, cross-compile, zig, cli]
---

# Windows cross-target 编译修复 Codex architect 计划

已只读检查源码和本机 Zig 0.16.0 stdlib，没有改文件。

## 根因

- `src/main.zig:39`：`readBoundedFromStdin` 直接调用 `std.posix.read(std.posix.STDIN_FILENO, ...)`；`src/main.zig:54` 也直接用 POSIX stdout fd。Windows 下 Zig 0.16 的 `fd_t` 是 HANDLE，不能按 POSIX `read/write` 语义编译/调用。
- `src/transcript.zig:70`：`std.posix.AT.FDCWD`、`openat`、`read` 是 POSIX 路径，Windows 不存在 `AT.FDCWD`；`src/transcript.zig:95` 之后的 `statx/fstat` guard 也是 POSIX-only。
- `src/ctxline.zig:71`：transcript fallback 当前没有接收 `std.Io`，所以无法直接使用 Zig 0.16 跨平台 `File/Dir` API。

## 建议改动

### `src/main.zig`

- 把入口改为 `pub fn main(init: std.process.Init) !void`，用 `const io = init.io`。
- `readBoundedFromStdin(io, allocator, max_bytes)` 使用 `std.Io.File.stdin()` 的流式读 API；EOF 当作输入结束，仍保留 max_bytes 后再读 1 byte 判超限。
- `writeLine(io, text)` 用 stdout `writeAll`/flush 语义，不再直接调用 POSIX `write`。

### `src/ctxline.zig`

- 将 `contextUsageFromStatusJson` 签名改成接收 `io: std.Io`。
- 只在 transcript fallback 分支传给 `transcript.estimateFromJsonlFile(io, allocator, transcript_path, opts)`。
- 不改 native context_window 优先级：valid native 仍先用；invalid/absent 才 fallback。

### `src/transcript.zig`

- `estimateFromJsonlFile(io: std.Io, allocator, path, opts)`。
- `readFileLimited` 按 comptime OS 分发：
  - POSIX：保留 `openat + O_NONBLOCK + statx/fstat regular-file guard`，避免 FIFO/special path 阻塞。
  - Windows：使用 `std.Io.Dir/File` 读取 regular file，`stat.kind == .file` 才 bounded read；非 file 返回错误并由上层 fallback 为 0。
- bounded read 保留“只读 prefix，不因超限失败整次估算”的语义。

## 测试和 Gate

- 更新所有 `contextUsageFromStatusJson` / `estimateFromJsonlFile` 调用，传 `std.testing.io`。
- 保留 regular transcript、oversized bounded prefix、directory non-regular tests。
- 如可行，补 POSIX-only FIFO quick-return 测试；Windows no-exec 只验证编译。
- 必跑：

```sh
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
zig test src/transcript.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

## CI

在 `.github/workflows/ci.yml` 现有 Ubuntu native gates 后加 Windows cross gates：

```sh
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

## 风险

- `std.Io` 传播会改 public 函数签名，需要更新测试。
- Windows named pipe/device/reparse point 行为需要后续在 Windows native 环境进一步验证；本 slice 先保证 cross compile + regular file fallback。
