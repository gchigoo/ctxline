# ctxline

`ctxline` is a tiny Zig CLI for Claude Code status output. It reads a status JSON payload from stdin and prints a compact one-line context meter.

```text
deepseek-v4-pro[1m] │ ctx 38.2% │ 382K/1.0M │ ███████░░░░░░░░░░░
```

## Requirements

- Zig `0.16.0`
- Linux, macOS, or Windows

## Install

```sh
# from source

git clone https://github.com/gchigoo/ctxline.git
cd ctxline
zig build -Doptimize=ReleaseFast
```

Release binaries are also available from GitHub Releases.

| Platform | Artifact | Download path in payload |
| --- | --- | --- |
| Linux | `ctxline-<version>-linux-x86_64.tar.gz` | `/path/to/ctxline` |
| Linux ARM64 | `ctxline-<version>-linux-aarch64.tar.gz` | `/path/to/ctxline` |
| macOS Intel | `ctxline-<version>-macos-x86_64.tar.gz` | `/path/to/ctxline` |
| macOS Apple Silicon | `ctxline-<version>-macos-aarch64.tar.gz` | `/path/to/ctxline` |
| Windows | `ctxline-<version>-windows-x86_64.zip` | `C:\Path\To\ctxline.exe` |

### Checksum verification

Each release publishes:

- Per-asset SHA256 files (`*.sha256`)
- A `SHA256SUMS` manifest

Example:

```sh
# Linux/macOS
sha256sum -c ctxline-<version>-linux-x86_64.tar.gz.sha256
sha256sum -c SHA256SUMS

# macOS also has shasum if sha256sum is unavailable
shasum -a 256 -c ctxline-<version>-macos-aarch64.tar.gz.sha256
```

```powershell
# Windows
Get-FileHash -Algorithm SHA256 ctxline-<version>-windows-x86_64.zip
```

## Claude Code configuration

Add a `statusLine` command in `~/.claude/settings.json`.

### macOS / Linux

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/zig-out/bin/ctxline",
    "padding": 1
  }
}
```

### Windows

```json
{
  "statusLine": {
    "type": "command",
    "command": "C:\\Program Files\\ctxline\\ctxline.exe",
    "padding": 1
  }
}
```

## Usage

```sh
# show usage and exit 0
ctxline --help
ctxline -h

# print version and exit 0
ctxline --version

# normal usage: JSON status payload on stdin
cat status.json | ctxline
```

## Runtime behavior

1. Native token counts are preferred when `context_window.total_input_tokens` or `context_window.total_output_tokens` is available; missing count fields are treated as `0`.
2. If counts are not available, native `used_percentage` is used for display and token estimate.
3. If native fields are invalid or missing, transcript fallback estimation is used via `transcript_path`.
4. If native and transcript paths both fail, `ctxline` falls back to `0/<model-window>` style context output and prints safely.

Malformed input prints:

```text
ctxline │ no status json
```

Model window mapping is inferred from the model id and falls back to `200K`.

## Model context windows

| Model match | Context window |
| --- | ---: |
| `deepseek-v4-pro[1m]` | 1,000,000 |
| `deepseek-v4-pro` | 1,000,000 |
| `deepseek-v4-flash` | 128,000 |
| `claude` + `1m` | 1,000,000 |
| unknown | 200,000 |

## Development

```sh
zig fmt build.zig src/*.zig
zig build test
zig build -Doptimize=ReleaseFast
```

If cache is not writable:

```sh
mkdir -p .zig-global-cache
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build test
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build -Doptimize=ReleaseFast
```

## Limitations

- Transcript fallback is an estimate, not exact tokenization.
- No persistent cache is maintained for transcripts.
- No network calls or provider SDKs are used.

## License

MIT
