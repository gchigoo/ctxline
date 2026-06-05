---
doc_type: issue-analysis
issue: 2026-06-05-windows-native-ci-smoke
status: confirmed
root_cause_type: missing-guard
related: [windows-native-ci-smoke-report.md]
tags: [ci, windows, smoke, zig, release]
---

# Windows native runtime smoke CI 缺口分析

## 1. 问题定位

| 关键位置 | 说明 |
|---|---|
| `.github/workflows/ci.yml:9` | 当前只有一个 `ubuntu-latest` job。 |
| `.github/workflows/ci.yml:26-29` | Windows 覆盖是 Ubuntu-hosted cross compile/no-exec test compile，不运行 `.exe`。 |
| `src/main.zig` | Windows runtime 风险主要在 stdin/stdout `std.Io` 行为，cross compile 不能证明真实管道执行。 |
| `src/transcript.zig` | Windows runtime 风险主要在 `std.Io.Dir/File` regular file / directory fallback 行为，cross compile 不能证明真实文件系统行为。 |

## 2. 失败路径还原

**正常路径**：CI 在 Windows runner 上安装 Zig 0.16.0 → native `zig build test` / release build → 用 PowerShell 将 JSON pipe 给 `ctxline.exe` → 检查输出单行和关键内容 → 创建 transcript 文件/目录并验证 fallback 行为。

**当前路径**：CI 只在 Ubuntu runner 上做 Windows target cross compile → 即使 `.exe` 能编译，仍无法发现 Windows stdin pipe、stdout encoding、文件路径/目录 fallback 的 runtime 问题。

**分叉点**：CI 缺少真实 Windows runner runtime smoke。

## 3. 根因

**根因类型**：missing-guard。

**根因描述**：上一轮为节省范围只加入了 Windows cross compile gates；这适合证明编译问题修复，但 public CLI 的 Windows 支持还需要最小 runtime smoke 作为 release readiness guard。

**是否有多个根因**：否，主要是 CI 覆盖缺口。

## 4. 影响面

- **影响范围**：Windows 用户和 release artifact 可信度。
- **潜在受害模块**：CLI stdin/stdout、Windows transcript fallback、README/发布说明可信度。
- **数据完整性风险**：无持久数据风险。
- **严重程度复核**：P2。不是当前功能 blocker，但属于 public release polish 的高价值 gate。

## 5. 修复方案

### 方案 A：新增独立 `windows-smoke` job（推荐）

- **做什么**：在 `.github/workflows/ci.yml` 新增 `windows-smoke` job，`runs-on: windows-latest`，安装 Zig 0.16.0 Windows archive，跑 `zig build test`、`zig build -Doptimize=ReleaseFast`，再用 PowerShell smoke `ctxline.exe`。
- **优点**：真实验证 Windows runtime；和 Ubuntu job 分离，失败定位清晰。
- **缺点 / 风险**：增加 CI runner 成本和时长；PowerShell 引号/UTF-8 输出断言要谨慎。
- **影响面**：只改 `.github/workflows/ci.yml` 和本 issue 文档。

### 方案 B：在现有 Ubuntu job 中只保留 cross compile

- **做什么**：不新增 native Windows job，仅依靠上一轮 cross gates。
- **优点**：CI 成本最低。
- **缺点 / 风险**：无法覆盖真实 runtime，用户要求“加”的项没有完成。
- **影响面**：无代码改动。

### 方案 C：用 matrix 合并 Ubuntu/Windows job

- **做什么**：把 workflow 改成 matrix，Ubuntu 和 Windows 共用步骤。
- **优点**：结构统一。
- **缺点 / 风险**：当前 Zig 官方 archive URL/解压/PATH 在 Linux/Windows 不同，matrix 条件会复杂化；本 slice 容易扩大。
- **影响面**：workflow 重构较大。

### 推荐方案

**推荐方案 A**。它最小化改动，同时直接覆盖真实 Windows runtime 行为。
