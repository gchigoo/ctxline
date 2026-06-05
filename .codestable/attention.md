---
doc_type: attention
project: ctxline
---

# ctxline CodeStable attention

## Project constraints

- Project is a standalone Zig CLI named `ctxline`.
- Target use case: Claude Code statusLine command; read status JSON from stdin, print a compact one-line context meter.
- Must support DeepSeek/Claude Code cases where native `context_window` fields are absent by estimating tokens from `transcript_path`.
- Keep output safe for status lines: one line, no raw JSON, no secrets.
- Use TDD where practical: library behavior tests first, then CLI wiring.

## Local commands

- Build: `zig build -Doptimize=ReleaseFast`
- Test: `zig build test`
- Smoke: `printf '{...}' | zig-out/bin/ctxline`

## Git/GitHub

- Commit identity: Gchigoo <stan.guo@mail.ru>.
- Public GitHub project target: `gchigoo/ctxline`.
