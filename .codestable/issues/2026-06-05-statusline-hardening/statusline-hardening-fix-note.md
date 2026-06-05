---
doc_type: issue-fix
status: verified
project: ctxline
slug: statusline-hardening
severity: P1
tags: [status-line, robustness, security, transcript]
fixed_at: 2026-06-05
---

# statusLine hardening fix note

## 1. Fix summary

Implemented the P1 hardening slice for `ctxline` statusLine safety:

1. Model display text is sanitized before status-line formatting.
2. Native `context_window` numeric parsing is strict and avoids f64 rounding for integer/token fields.
3. Native token totals use checked arithmetic and invalid/overflow/over-window totals cannot be masked by a valid percentage.
4. `transcript_path` reads are guarded to regular files only; FIFO/special paths return a zero estimate quickly.

## 2. Files changed

- `src/format.zig`
  - Added model text sanitization at the formatting boundary.
  - Replaces control bytes and caps printed model byte length.
  - Added tests for control-byte sanitization and cap behavior.

- `src/status_json.zig`
  - Added `invalid_context_window` tracking.
  - Parses integer/number-string token fields directly as `u64` instead of via `f64`.
  - Rejects negative, fractional, non-finite, out-of-range, zero/oversized context-window values.

- `src/ctxline.zig`
  - Validates native token counts before percentage-only fallback.
  - Preserves exact native token totals when both percentage and counts are present.
  - Falls back safely for invalid, overflowing, over-window, or partially invalid native counts.
  - Added regression tests for partial invalid fields, >2^53 rounding boundary, count preference, and percent+bad-sum bypass.

- `src/transcript.zig`
  - Opens transcript paths non-blocking and requires `fstat` regular-file mode before reading.
  - Added non-regular path regression test.

## 3. Verification

Automated gates passed:

```sh
zig fmt build.zig src/*.zig --check
zig build test
zig build -Doptimize=ReleaseFast
```

Manual smoke checks passed:

- injected model newline/tab/ESC/control chars produce exactly one output line
- invalid `used_percentage: 1e309` falls back to `0%`
- huge token sum `u64.max + 1` falls back to `0%`
- `used_percentage` cannot mask over-window token totals
- exact native counts are preferred for used-token display when both counts and percentage are present
- large integer boundary above 2^53 does not get rounded into valid native usage
- FIFO `transcript_path` returns within milliseconds and does not block
- valid DeepSeek native payload remains correct: `382K/1.0M` at `38.2%`

## 4. Review loop

Independent review was run after implementation.

- First review found direct `f64` rounding of large integer fields; fixed with direct integer/number-string `u64` parsing and regression coverage.
- Second review found percentage-first native handling could bypass invalid token totals and misreport exact counts; fixed by validating/prefering counts before percentage-only fallback.
- Third review passed with no security concerns or logic errors.

Final independent reviewer verdict:

```json
{"passed":true,"security_concerns":[],"logic_errors":[],"suggestions":[],"summary":"The unstaged diff resolves the f64 rounding and percent-first bypass concerns without introducing a new blocking issue."}
```

## 5. Follow-up items not in this slice

- Add CLI-level integration tests for `main.zig` stdin/stdout behavior.
- Decide whether README should remove Windows support text or implementation should become cross-platform.
- Add release workflow/artifacts/checksums for public CLI distribution.
- Revisit long-transcript fallback accuracy with streaming or sidecar cache.
