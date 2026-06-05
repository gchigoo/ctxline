---
doc_type: issue-architect-plan
status: confirmed
project: ctxline
slug: statusline-hardening
---

# statusLine hardening Codex architect plan

Read-only pass only. No files were edited by this architect pass.

## Implementation Plan

1. Add RED tests first.

In `src/format.zig`:

- Test: `format status line sanitizes model control bytes`
- Input model: `"deepseek\nv4\t\x1b[31m\r"`
- Expect:
  - output contains no `\n`, `\r`, `\t`, or `\x1b`
  - output remains one physical line
  - printable suffix like `[31m` may remain, but ESC must not
- Current RED: raw model is interpolated into `allocPrint`, so newline/control bytes appear.

In `src/status_json.zig`:

- Test: `parse context window ignores invalid numeric fields`
- Payload with:
  - `used_percentage: 150.1`
  - `total_input_tokens: 1.5`
  - `total_output_tokens: -1`
  - `context_window_size: 0`
- Expect all four parsed fields are `null`.
- Current RED: percentage is accepted, fractional token count truncates to `1`, zero window is accepted.

In `src/ctxline.zig`:

- Test: `invalid native percentage falls back when no valid native counts`
- Payload: known model, `used_percentage: 125.0`, `context_window_size: 128000`.
- Expect `.mode == .fallback`, `used_tokens == 0`, `percent == 0.0`, `max_tokens == models.flash_window`.
- Current RED: returns `.native` with `125%`.

In `src/ctxline.zig`:

- Test: `overflowing native token sum is ignored`
- Payload: `total_input_tokens: 18446744073709551615`, `total_output_tokens: 1`.
- Expect no trap; invalid native counts are ignored, so no transcript means `.fallback`.
- Current RED: likely traps or produces unsafe native usage due unchecked sum.

In `src/transcript.zig`:

- Test: `file estimator ignores fifos`
- POSIX-only test: create FIFO, hold a nonblocking `RDWR` fd open, write one JSONL content line, call `estimateFromJsonlFile`.
- Expect `0`.
- Current RED: estimator opens and reads the FIFO as if it were a transcript.

2. Minimal production changes.

In `src/format.zig`:

- Add a small `sanitizeModelName` helper.
- Replace ASCII C0 controls and DEL with `?`.
- Use sanitized model only inside `formatStatusLine`.

In `src/status_json.zig`:

- Make numeric helpers strict:
  - percentages must be finite and `0 <= pct <= 100`
  - token/window fields must be exact unsigned integers
  - `context_window_size` must be `> 0`
  - reject fractional, negative, infinite, NaN, and out-of-`u64` values.

In `src/ctxline.zig`:

- Add checked native usage construction:
  - use checked addition for input/output totals
  - reject native token sums greater than `max_tokens`
  - use valid percentage if present; otherwise valid checked counts; otherwise transcript/fallback.

In `src/transcript.zig`:

- Open transcript paths and immediately `fstat` the opened fd.
- Require a regular file mode before reading.
- Return `0` through existing catch path for non-regular files.
- Keep bounded-prefix reading unchanged.

## Verification

Run RED after adding tests, then GREEN after production changes:

```sh
zig build test
zig fmt build.zig src/*.zig
zig build test
zig build -Doptimize=ReleaseFast
```

## Risks

- Policy choices around ignoring native token sums greater than context window should not break valid statusLine payloads; when percentage is valid, prefer the percentage for display.
- FIFO test should be POSIX-gated; no Windows expansion in this slice.
- Use `fstat` after open to avoid path check/open races.
