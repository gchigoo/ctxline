---
doc_type: issue-fix
issue: 2026-06-05-windows-native-ci-smoke
status: verified
severity: P2
related: [windows-native-ci-smoke-report.md, windows-native-ci-smoke-analysis.md, windows-native-ci-smoke-architect-plan.md]
tags: [ci, windows, smoke, zig, release]
---

# Windows native runtime smoke CI 修复记录

## 1. 修复摘要

新增真实 Windows runner runtime smoke，补齐上一轮 Windows cross compile 只能证明“能编译”但不能证明“能在 Windows 上运行”的 CI 缺口。

本次无源码改动，只修改 GitHub Actions workflow 和 CodeStable issue 文档。

## 2. 改动文件

| 文件 | 改动 |
|---|---|
| `.github/workflows/ci.yml` | 新增 `windows-smoke` job，运行于 `windows-latest`。 |
| `.codestable/issues/2026-06-05-windows-native-ci-smoke/*` | 新增 report / analysis / architect-plan / fix-note。 |

## 3. CI job 内容

`windows-smoke` job：

1. `actions/checkout@v5`
2. PowerShell 下载官方 Zig 0.16.0 Windows zip：
   - `https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip`
3. 解压并写入 `GITHUB_PATH`
4. `zig version`
5. `zig build test`
6. `zig build -Doptimize=ReleaseFast`
7. PowerShell runtime smoke：
   - 检查 `.\zig-out\bin\ctxline.exe` 存在
   - pipe native context_window JSON 到 exe，断言 exactly one non-empty output line，包含 `deepseek-v4-pro[1m]` 和 `382K/1.0M`
   - 创建 regular transcript JSONL，使用 `ConvertTo-Json` 生成 Windows path payload，断言包含 `deepseek-v4-flash` 和 `3/128K`，且不包含 `0/128K`
   - 创建 directory transcript_path，断言 fallback 输出包含 `deepseek-v4-flash` 和 `0/128K`

## 4. 关键实现决策

- 使用独立 `windows-smoke` job，而不是重构成 matrix，避免扩大 workflow 改动范围。
- PowerShell smoke 只断言 ASCII 稳定片段，不断言 `│`、`█`、`░` 等 Unicode bar，降低 Windows console encoding 脆弱性。
- Windows path payload 用 PowerShell `ConvertTo-Json -Compress` 生成，避免手写反斜杠转义。
- 显式设置 `$ErrorActionPreference = "Stop"`，确保下载/解压/smoke 失败能让 step 失败。
- `Invoke-WebRequest` 前设置 `$ProgressPreference = "SilentlyContinue"`，减少 CI 日志噪音。
- `GITHUB_PATH` 使用 `Out-File -Encoding utf8 -Append`，避免路径文件编码问题。
- regular transcript 使用 `Set-Content -Encoding utf8`。

## 5. 本地验证

以下本地 gates 通过：

```sh
git diff --check
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

其他检查：

- Python YAML parser 成功加载 `.github/workflows/ci.yml`，识别 jobs：`test`, `windows-smoke`。
- Zig 0.16.0 Windows zip URL HEAD 返回 HTTP 200。
- 静态扫描未发现 hardcoded secrets；`no-exec` 字样造成的 `exec` 命中为 false positive。
- 独立 reviewer 复核 workflow diff：`passed: true`，无 blocker。
- `actionlint` 本地未安装，未执行 GitHub Actions schema lint。

## 6. 远端验证要求

push 后必须 watch GitHub Actions，确认：

- Ubuntu `test` job 成功。
- Windows `windows-smoke` job 成功。
- Runtime smoke step 成功覆盖 native context_window、regular transcript fallback、directory fallback。

## 7. 验收结论

本地验证和静态/独立 review 均通过。最终验收以 GitHub Actions run 中 `test` + `windows-smoke` 均 success 为准。
