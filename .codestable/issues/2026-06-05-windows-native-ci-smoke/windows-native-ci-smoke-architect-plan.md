---
doc_type: issue-plan
issue: 2026-06-05-windows-native-ci-smoke
status: confirmed
source: codex-architect
related: [windows-native-ci-smoke-report.md, windows-native-ci-smoke-analysis.md]
tags: [ci, windows, smoke, zig, release]
---

# Windows native runtime smoke CI Codex architect 计划

## 1. 结论

只新增 `.github/workflows/ci.yml` 里的独立 `windows-smoke` job，并在 issue 目录补 `windows-native-ci-smoke-fix-note.md`。不改源码。

Zig 0.16.0 官方 Windows 包：

```text
https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip
```

`GITHUB_PATH` 写入后只对后续 step 生效，所以安装和 `zig version` 拆开。

## 2. 推荐 job 结构

```yaml
windows-smoke:
  runs-on: windows-latest
  timeout-minutes: 20
  steps:
    - uses: actions/checkout@v5
    - Install Zig 0.16.0 via PowerShell / official zip
    - Show Zig version
    - zig build test
    - zig build -Doptimize=ReleaseFast
    - Runtime smoke via PowerShell
```

## 3. Runtime smoke 场景

### 场景 A：native context_window

- stdin JSON 包含：
  - `model.display_name = deepseek-v4-pro[1m]`
  - `total_input_tokens = 380000`
  - `total_output_tokens = 2000`
  - `context_window_size = 1000000`
- 断言：
  - exactly one output line
  - 包含 `deepseek-v4-pro[1m]`
  - 包含 `382K/1.0M`

### 场景 B：regular transcript fallback

- 在 `$env:RUNNER_TEMP` 创建 JSONL transcript regular file。
- 用 PowerShell `ConvertTo-Json -Compress` 生成 payload，避免 Windows path 反斜杠手写转义。
- 断言：
  - exactly one output line
  - 包含 `deepseek-v4-flash`
  - 包含 `3/128K`
  - 不包含 `0/128K`

### 场景 C：directory transcript fallback

- 在 `$env:RUNNER_TEMP` 创建 directory path。
- payload 的 `transcript_path` 指向该目录。
- 断言：
  - exactly one output line
  - 包含 `deepseek-v4-flash`
  - 包含 `0/128K`

## 4. 断言策略

只断言 ASCII 稳定片段：model、`382K/1.0M`、`3/128K`、`0/128K`。不断言 `│`、`█`、`░` 等 Unicode bar 字符，避免 Windows console encoding 差异导致脆弱失败。

## 5. 风险

- 官方包下载不做 minisig 验签，和现有 Ubuntu CI 直接下载 tarball 的做法一致；验签会扩大范围。
- `windows-latest` 镜像会漂移，但 Zig version URL 固定。
- 如果 Windows smoke 暴露 runtime bug，本 slice 应停止并记录新 issue，不把源码修复混进 CI smoke 变更。

## 6. 验证

本地：

```sh
git diff --check
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

远端：

- push 后 watch GitHub Actions。
- 需要看到 Ubuntu `test` job 和 Windows `windows-smoke` job 都成功。
