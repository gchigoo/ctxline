---
doc_type: issue-report
issue: 2026-06-05-windows-native-ci-smoke
status: confirmed
severity: P2
tags: [ci, windows, smoke, zig, release]
---

# Windows native runtime smoke CI 缺口报告

## 1. 问题概述

上一轮已修复 Windows cross-target 编译，并在 Ubuntu CI 上加入 Windows target cross compile/no-exec test compile gate。但这只能证明 `.exe` 可编译，不能证明 Windows runner 上真实执行 statusLine CLI 的 stdin/stdout、regular transcript fallback、directory/non-file fallback 行为正常。

## 2. 复现 / 当前状态

当前 CI：`.github/workflows/ci.yml`

已有 gates：

```sh
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast
zig test src/ctxline.zig -target x86_64-windows -O ReleaseFast --test-no-exec
```

最近成功 CI：`https://github.com/gchigoo/ctxline/actions/runs/27002636177`

缺口：没有 `windows-latest` job 实际运行 `zig-out/bin/ctxline.exe`。

## 3. 期望行为

新增真实 Windows native CI smoke job，至少验证：

1. Windows 上可安装 Zig 0.16.0 并 native build/test。
2. `.\zig-out\bin\ctxline.exe` 可从 stdin 读取 statusLine JSON，并输出 exactly one line。
3. valid native `context_window` payload 输出预期 token/window 摘要。
4. regular transcript file fallback 在 Windows 上能读文件并输出非零估算。
5. `transcript_path` 指向 directory 时安全 fallback 为 0，不 crash/hang。

## 4. 实际行为

目前 CI 未覆盖上述 Windows native runtime 行为；只能从 cross compile 推断。

## 5. 涉及模块

- `.github/workflows/ci.yml`：需要新增 `windows-latest` job 和 PowerShell smoke。
- `.codestable/issues/2026-06-05-windows-native-ci-smoke/*`：记录本次 CI smoke 增强闭环。
