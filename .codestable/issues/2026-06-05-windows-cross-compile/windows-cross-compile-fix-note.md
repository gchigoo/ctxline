---
doc_type: issue-fix
issue: 2026-06-05-windows-cross-compile
status: verified
severity: P1
related: [windows-cross-compile-report.md, windows-cross-compile-analysis.md, windows-cross-compile-architect-plan.md]
tags: [windows, cross-compile, zig, cli]
---

# Windows cross-target 编译失败修复记录

## 1. 修复摘要

本次按推荐方案 A 修复 Windows cross-target 编译失败：将标准流 I/O 和 transcript 文件读取的 POSIX-only 边界改成平台适配，同时保留 macOS/Linux 上的 nonblocking regular-file guard。

修复后：

- `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast` 通过。
- `zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec` 通过。
- `zig test src/transcript.zig -target x86_64-windows -O ReleaseFast --test-no-exec` 通过。
- macOS/Linux native tests/build/smoke 通过。
- POSIX FIFO transcript path 仍快速 fallback，不阻塞。

## 2. 改动文件

| 文件 | 改动 |
|---|---|
| `src/main.zig` | 入口改为 `pub fn main(init: std.process.Init) !void`；stdin 读取改用 `std.Io.File.stdin().readStreaming`；stdout 输出改用 writer `writeAll`/newline/`flush`；保留 stdin size cap 和 fallback line 行为。 |
| `src/ctxline.zig` | `contextUsageFromStatusJson` 增加 `std.Io` 参数，只传给 transcript fallback；native context_window 优先级和 invalid-native fallback 逻辑不变；更新测试调用为 `std.testing.io`。 |
| `src/transcript.zig` | `estimateFromJsonlFile` 增加 `std.Io` 参数；POSIX 路径保留 `openat + .NONBLOCK + statx/fstat regular-file guard`；新增 Windows `std.Io.Dir/File` regular-file 读取分支；Windows 读取使用 `readPositional`，避免 `readStreaming` EOF 导致短 regular file 被误判为 0。 |
| `.github/workflows/ci.yml` | 在 Ubuntu CI native gates 后增加 Windows cross compile 和 no-exec test compile gate。 |
| `.codestable/issues/2026-06-05-windows-cross-compile/*` | 新增 report / analysis / architect-plan / fix-note。 |

## 3. 关键实现决策

1. **不全平台改成高层 `std.Io.Dir/File`**：POSIX 继续使用 `openat(... .NONBLOCK = true)`，避免 FIFO/special transcript path 在 open 阶段阻塞。
2. **Windows 使用 `std.Io.Dir/File`**：先 `statFile` 判断 regular file，再 open/read；directory/non-file fallback 为 0 token。
3. **Windows bounded read 使用 `readPositional`**：`readStreaming` 以 `error.EndOfStream` 表示 EOF，若不捕获会让普通短 transcript 返回 0；`readPositional` EOF 返回 0，更适合 bounded file prefix loop。
4. **CI 加 cross gates 而非 native Windows job**：本 slice 先保证 Windows target 编译和 tests no-exec 编译；真实 Windows runtime smoke 作为后续 release polish。

## 4. 验证记录

### RED 复现

```sh
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
```

修复前失败于 `src/main.zig:39` 的 `std.posix.read(std.posix.STDIN_FILENO, ...)`。

```sh
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

修复前失败于 `src/transcript.zig:70` 的 `std.posix.AT.FDCWD`。

### 本地 gates

以下命令最终全部通过：

```sh
git diff --check
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
zig test src/transcript.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

### 本地 CLI smoke

使用 `zig-out/bin/ctxline` 验证：

- valid native context_window：输出 `382K/1.0M` / `38.2%`，单行。
- model control-character injection：输出仍为单行，控制字符被替换。
- regular transcript fallback：可估算 transcript，输出单行。
- POSIX FIFO transcript path：约 0.006 秒返回 fallback `0/128K`，不阻塞。

### 静态扫描 / review

- 新增 diff 静态扫描：未发现 hardcoded secret、eval/exec、shell spawn 等问题。
- 独立 reviewer 复核当前 uncommitted diff：`passed: true`，无 blocker。
- Reviewer 备注：真实 Windows runtime smoke 仍建议后续在 Windows host 上覆盖 regular transcript、directory/named pipe/device-like path、oversized transcript。

## 5. 未纳入本 slice 的后续项

- Windows native GitHub Actions job / 真 Windows runtime smoke。
- README Windows 支持说明 polish。
- `--help` / `--version`。
- release artifact matrix / checksums。

## 6. 验收结论

本 issue 的 P1 blocker 已修复：Windows target 能 cross compile，library tests 能 no-exec cross compile；macOS/Linux native gates 和 POSIX transcript hardening smoke 均通过。
