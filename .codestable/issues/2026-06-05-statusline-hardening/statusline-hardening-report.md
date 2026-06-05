---
doc_type: issue-report
status: confirmed
project: ctxline
slug: statusline-hardening
severity: P1
tags: [status-line, robustness, security, transcript]
discovered_at: 2026-06-05
---

# statusLine hardening report

## 1. Problem summary

Codex review and controller verification found three P1 robustness issues in the current public `ctxline` MVP:

1. `model.display_name` / `model.id` from Claude Code status JSON is copied into the status line without sanitization, so control bytes can break the one-line output contract.
2. Native `context_window` numeric fields are accepted without strict finite/range/overflow validation, so malformed-but-parseable JSON can produce absurd token counts or wraparound output.
3. `transcript_path` is opened as an arbitrary blocking local path, so a FIFO/special file can hang the statusLine command.

## 2. Reproduction evidence

### Raw model text breaks one-line output

Payload shape:

```json
{"model":{"display_name":"safe\nLEAK=1"},"context_window":{"used_percentage":1,"context_window_size":100000}}
```

Observed output from existing binary:

```text
safe
LEAK=1 │ ctx 1% │ 1.0K/100K │ ...
```

### Invalid native numbers produce unsafe output

Payload shape:

```json
{"model":{"display_name":"x"},"context_window":{"used_percentage":1e309,"context_window_size":1000}}
```

Observed output from existing binary:

```text
x │ ctx 100% │ 18446744073709.6M/1.0K │ ██████████████████
```

Huge token sums also wrap to an incorrect low value.

### FIFO transcript path blocks

A local smoke reproduction created a POSIX FIFO, passed it as `transcript_path`, and the existing binary did not return within 2 seconds.

## 3. Expected behavior

- Output remains exactly one physical status line plus terminating newline.
- Model text printed in the line contains no raw control characters, escape bytes, or unbounded user-controlled length.
- Invalid native numeric context values are ignored/rejected safely and never cause panics, wraparound, or absurd values.
- Transcript fallback reads only regular transcript files; non-regular paths return a zero estimate/fallback quickly.

## 4. Scope

This issue is limited to the three P1 hardening items above. It intentionally excludes:

- Windows support
- release workflow / artifacts
- README polish
- long-transcript streaming/cache accuracy work
