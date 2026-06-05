---
doc_type: issue-analysis
status: confirmed
project: ctxline
slug: statusline-hardening
severity: P1
tags: [status-line, robustness, security, transcript]
recommended方案: bounded-hardening-slice
---

# statusLine hardening analysis

## 1. Root cause locations

### A. Raw model text reaches formatter

- `src/status_json.zig:37-42` duplicates `model.display_name` / `model.id` from JSON.
- `src/ctxline.zig:34` duplicates and returns it as `ContextUsage.model`.
- `src/format.zig:77-80` interpolates `{model}` directly into the final line.

There is no control-character removal, whitespace normalization, or length cap between untrusted JSON input and statusLine output.

### B. Numeric fields are not strict enough

- `src/status_json.zig:89-107` converts JSON numbers to `f64` / `u64` without finite, fractional, zero-window, or upper-bound checks.
- `src/ctxline.zig:47` adds input/output token totals directly.
- `src/ctxline.zig:90` derives token count from a percentage without validating the percentage/max combination.
- `src/ctxline.zig:96` computes percent from unchecked sums.

Malformed native context should not be allowed to dominate transcript/fallback behavior.

### C. Transcript paths are opened without file-type guard

- `src/status_json.zig:52-53` accepts any `transcript_path` string.
- `src/ctxline.zig:67` passes it directly to `transcript.estimateFromJsonlFile`.
- `src/transcript.zig:70-80` opens and reads with blocking POSIX calls without `fstat` regular-file validation.

A statusLine command should never block indefinitely on a FIFO/device/socket path.

## 2. Selected fix方案

Use one bounded hardening slice:

1. Add tests first for the three failing behaviors.
2. Sanitize model text at the formatting boundary so every status line is one-line safe.
3. Tighten JSON numeric parsing and native usage construction:
   - finite percentage only, `0 <= pct <= 100`
   - token/window fields must be exact unsigned integer values
   - `context_window_size > 0`
   - checked addition for token totals
   - invalid native token totals should not produce native usage
4. Guard transcript file reads with a regular-file check before reading content.

## 3. Impacted files

- `src/format.zig`
- `src/status_json.zig`
- `src/ctxline.zig`
- `src/transcript.zig`
- `.codestable/issues/2026-06-05-statusline-hardening/statusline-hardening-fix-note.md` after verification

## 4. Verification plan

Run after implementation:

```sh
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
```

Manual smoke checks:

- injected model newline/control chars produce exactly one output line
- invalid native numeric payload falls back safely
- FIFO transcript path returns quickly instead of blocking
- valid native DeepSeek payload still prints expected context meter

## 5. Codex architect plan

Stored separately in `statusline-hardening-architect-plan.md` for implementation details and RED/GREEN sequencing.
