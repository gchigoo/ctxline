# ctxline

`ctxline` is a tiny Zig CLI for Claude Code status lines. It reads the JSON payload Claude Code sends on stdin and prints a compact one-line context meter.

```text
deepseek-v4-pro[1m] │ ctx 38.2% │ 382K/1.0M │ ███████░░░░░░░░░░░
```

## Why

Claude Code can expose native `context_window.*` status fields for some models, but those fields may be absent when Claude Code is connected to providers such as DeepSeek. `ctxline` prefers native context usage when available and falls back to local transcript estimation via `transcript_path`.

## Install

```sh
git clone https://github.com/gchigoo/ctxline.git
cd ctxline
zig build -Doptimize=ReleaseFast
```

The binary is written to:

```text
zig-out/bin/ctxline
```

## Claude Code configuration

Add a `statusLine` command to `~/.claude/settings.json`.

macOS / Linux:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Users/steven/tools/ctxline/zig-out/bin/ctxline",
    "padding": 1
  }
}
```

Windows:

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:\\Tools\\ctxline\\ctxline.exe",
    "padding": 1
  }
}
```

Use the absolute path where you built or installed the binary.

## Behavior

Resolution order:

1. Read Claude Code status JSON from stdin.
2. Use native `context_window.used_percentage` if present.
3. Use native input/output token totals when present.
4. If native context is absent, read `transcript_path` and estimate visible text tokens from JSONL transcript lines.
5. Map the model to a max context window and print a single status line.

Model defaults:

| Model match | Context window |
| --- | ---: |
| `deepseek-v4-pro[1m]` | 1,000,000 |
| `deepseek-v4-pro` | 1,000,000 |
| `deepseek-v4-flash` | 128,000 |
| `claude` + `1m` | 1,000,000 |
| unknown | 200,000 |

Malformed input prints a safe fallback and exits successfully:

```text
ctxline │ no status json
```

## Development

```sh
zig fmt build.zig src/*.zig
zig build test
zig build -Doptimize=ReleaseFast
```

If your Zig global cache is not writable:

```sh
mkdir -p .zig-global-cache
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build test
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build -Doptimize=ReleaseFast
```

## Limitations

- Transcript fallback is an estimate, not an exact tokenizer.
- MVP reads a bounded transcript prefix and does not keep a persistent cache.
- No network calls or provider SDKs are used.

## License

MIT
