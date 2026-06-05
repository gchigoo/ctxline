---
doc_type: issue-analysis
issue: 2026-06-05-windows-cross-compile
status: confirmed
root_cause_type: config
related: [windows-cross-compile-report.md]
tags: [windows, cross-compile, zig, cli]
---

# Windows cross-target 编译失败根因分析

## 1. 问题定位

| 关键位置 | 说明 |
|---|---|
| `src/main.zig:39` | `readBoundedFromStdin` 使用 `std.posix.read(std.posix.STDIN_FILENO, ...)`。Windows target 下 `fd_t` 是 HANDLE，不接受 POSIX integer fd；POSIX read 语义也不是跨平台入口。 |
| `src/main.zig:54-55` | `writeLine` 直接调用 `std.posix.system.write(std.posix.STDOUT_FILENO, ...)`，同样是 POSIX stdout 写法，且会继续阻断 Windows 支持/partial write polish。 |
| `src/transcript.zig:70-81` | transcript fallback 用 `std.posix.openat` / `AT.FDCWD` / `std.posix.read`，Windows target 没有 `AT.FDCWD`，该路径不能交叉编译。 |
| `src/transcript.zig:95-124` | regular-file guard 依赖 Linux `statx` 或 POSIX `fstat/fstat64`，缺少 Windows 分支。 |
| `src/ctxline.zig:71` | `contextUsageFromStatusJson` 调用 transcript fallback 时没有传 `std.Io`，因此无法直接使用 Zig 0.16 跨平台 file API。 |
| `.github/workflows/ci.yml` | CI 只跑 Ubuntu native fmt/test/release build，未覆盖 Windows cross compile，导致问题发布前未被自动发现。 |

## 2. 失败路径还原

**正常路径**：用户或 CI 执行 Windows target build → Zig 编译 exe/library → CLI 在 Windows 上通过 stdin 收 statusLine JSON，stdout 输出一行；如果 native context_window 缺失，读取 regular transcript file 做 fallback 估算。

**失败路径**：Windows target build → 编译 `src/main.zig` 时遇到 POSIX stdin read → `std.posix.read` 参数类型/OS 支持不匹配 → exe build 失败。若只编译 library tests，则进入 `src/transcript.zig` → Windows `std.posix.AT` 没有 `FDCWD` → test no-exec 编译失败。

**分叉点**：I/O 边界代码把 POSIX API 当成跨平台 API 使用；核心业务逻辑本身不是 Windows-specific。

## 3. 根因

**根因类型**：配置 / 平台抽象缺失。

**根因描述**：项目业务层是跨平台 Zig 代码，但 CLI stdin/stdout 和 transcript_path 文件读取层直接绑定 POSIX API。Zig 0.16 Windows target 下 `std.posix` 的 fd/openat/stat 语义不能用于 Windows HANDLE/文件路径，因此 Windows cross-target 编译失败。

**是否有多个根因**：是。

1. `src/main.zig` 标准流 I/O 使用 POSIX API。
2. `src/transcript.zig` transcript 文件读取和 regular-file guard 缺少 Windows 路径。
3. CI 未覆盖 Windows target，导致问题未被 gate 捕获。

## 4. 影响面

- **影响范围**：Windows build/artifact 全阻断；README Windows 示例可信度受影响。
- **潜在受害模块**：CLI 启动入口、transcript fallback、CI release readiness。
- **数据完整性风险**：无持久数据损坏风险；主要是可用性/发布质量风险。
- **严重程度复核**：维持 P1。public CLI 宣称/暗示跨平台时，Windows build 失败是发布质量问题，但不影响当前 macOS/Linux 用户的核心功能。

## 5. 修复方案

### 方案 A：显式 `std.Io` 传播 + transcript 平台分支（推荐）

- **做什么**：
  - `src/main.zig` 改用 `std.process.Init.io` + `std.Io.File.stdin/stdout`。
  - `src/ctxline.zig` 将 `std.Io` 传入 transcript fallback。
  - `src/transcript.zig` 保留 POSIX nonblocking regular-file guard；新增 Windows `std.Io.Dir/File/stat/read` 路径。
  - `.github/workflows/ci.yml` 增加 Windows cross compile/no-exec gate。
- **优点**：符合 Zig 0.16 标准 I/O 风格；Windows 功能不降级；POSIX FIFO hardening 不退化。
- **缺点 / 风险**：函数签名会改动；需要更新测试调用点。
- **影响面**：`src/main.zig`、`src/ctxline.zig`、`src/transcript.zig`、`.github/workflows/ci.yml`，以及本 issue 文档。

### 方案 B：只修 exe stdin/stdout，Windows 禁用 transcript fallback

- **做什么**：`main.zig` 改跨平台；`transcript.zig` Windows 分支直接返回 0，不读取 transcript。
- **优点**：改动最小，能尽快让 exe 编译。
- **缺点 / 风险**：Windows 上 DeepSeek/缺 native context_window 场景失去 fallback 能力，与项目目标不一致。
- **影响面**：`src/main.zig`、`src/transcript.zig`、CI。

### 方案 C：全平台改成纯 `std.Io.Dir/File`

- **做什么**：POSIX/Windows 都用高层 `std.Io` 文件 API。
- **优点**：代码统一，平台分支少。
- **缺点 / 风险**：POSIX 上可能失去 `openat + O_NONBLOCK` 对 FIFO/special file 的防阻塞保证；需要额外 stat-before-open，存在 TOCTOU 风险。
- **影响面**：`src/transcript.zig` 核心 hardening 语义变化较大。

### 推荐方案

**推荐方案 A**。它在改动范围可控的前提下解决真正根因：标准流和 transcript 文件读取层需要平台抽象；同时保留 POSIX nonblocking guard，避免回滚上一轮 hardening。
