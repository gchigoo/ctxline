---
doc_type: feature-plan
feature: 2026-06-05-ctxline-mvp
source: codex-architect
---

# Codex architect implementation plan

Read the requested docs. No files were edited. Note: the checklist file is actually `.codestable/features/2026-06-05-ctxline-mvp/ctxline-mvp-checklist.yaml`.

**Implementation Plan**
Use Zig `0.16.0+` and keep `main.zig` thin.

Target tree:

```text
build.zig
src/
  main.zig          # stdin/stdout only, fallback on errors
  ctxline.zig       # public facade and shared types
  status_json.zig   # Claude status JSON extraction
  models.zig        # model -> context window mapping
  transcript.zig    # JSONL transcript fallback estimator
  format.zig        # percent/token/bar/status-line formatting
```

In `build.zig`, use the Zig 0.16 `root_module` style: create/add a public `ctxline` module rooted at `src/ctxline.zig`, build the `ctxline` executable from `src/main.zig`, import the library module into the executable module, install the artifact, and wire `zig build test` through `addTest` + `addRunArtifact`.

**Core Boundaries**
`main.zig`:
Read stdin up to a cap, call library, print exactly one line. On malformed stdin or unexpected library error, print:

```text
ctxline │ no status json
```

and exit `0`.

`ctxline.zig`:
Expose small testable APIs:

```zig
pub const Mode = enum { native, transcript, fallback };

pub const ContextUsage = struct {
    model: []const u8,
    used_tokens: u64,
    max_tokens: u64,
    percent: f64,
    mode: Mode,
};

pub const Options = struct {
    max_stdin_bytes: usize = 256 * 1024,
    max_transcript_bytes: usize = 4 * 1024 * 1024,
    transcript_bytes_per_token: usize = 3,
    bar_width: usize = 10,
};
```

Keep pure helpers separate from file I/O where possible. `transcript.zig` should have both `estimateJsonlBytes(bytes, opts)` for tests and `estimateJsonlFile(path, opts)` for CLI fallback.

`status_json.zig`:
Parse `std.json.Value`, not strict structs, because Claude status JSON will contain extra provider/session fields. Extract:

- model: `model.display_name`, fallback `model.id`, fallback `ctxline`
- native context: `context_window.used_percentage`
- token totals: `total_input_tokens + total_output_tokens`
- max window: `context_window.context_window_size`, fallback model mapping
- transcript path: `transcript_path`

`models.zig`:
Implement exact acceptance mappings:

```text
deepseek-v4-pro[1m] -> 1_000_000
deepseek-v4-pro     -> 1_000_000
deepseek-v4-flash   -> 128_000
claude + 1m         -> 1_000_000
unknown             -> 200_000
```

`transcript.zig`:
Read JSONL line by line or split bounded bytes by `\n`. Ignore malformed lines. Recursively count strings under visible keys like `content`, `text`, `tool_result`, `message`, while skipping metadata-ish keys such as `id`, `uuid`, `timestamp`, `session_id`, `parent_uuid`, `role`, `type`, `model`, `usage`, `metadata`. Estimate tokens with one constant, e.g. `ceil(visible_utf8_bytes / 3)`, so tests are deterministic and the tokenizer can be replaced later.

`format.zig`:
Clamp percent to `[0, 100]`. Format tokens deterministically: `382K/1.0M`, `0/200K`, etc. Use the required separator format:

```text
{model} │ ctx {pct}% │ {used}/{max} │ {bar}
```

Keep the bar ASCII for portability, e.g. `[####------]`.

**Test Strategy**
Follow the checklist order.

Step 1 unit tests:
`models.zig`, `format.zig`, `status_json.zig`.

Cover:

- DeepSeek/Claude/unknown model windows
- token formatting boundaries: `999`, `1.0K`, `382K`, `1.0M`
- native context with full totals
- native percent with missing totals derives `used = pct * max`

Step 2 transcript tests:
Use in-memory JSONL first.

Cover:

- visible content recursion
- metadata skipping
- invalid JSONL line ignored
- empty/missing transcript gives `0`
- DeepSeek flash fallback uses `128_000`

Add one temp-file test only if Zig test filesystem ergonomics stay simple.

Step 3 CLI smoke:
After build, test real stdin/stdout for:

- valid native JSON
- fallback transcript JSON
- malformed stdin
- exactly one output line
- transcript text not present in output

**Likely `std.json` Pitfalls**
In Zig 0.16, `std.json.parseFromSlice` returns `std.json.Parsed(T)` backed by an arena. Always `defer parsed.deinit()` and do not return slices from `parsed.value` after deinit unless copied.

Avoid typed status structs unless using `.ignore_unknown_fields = true`; otherwise unknown Claude fields can fail parsing. Dynamic `std.json.Value` is safer for MVP.

Handle all numeric variants: `.integer`, `.float`, and `.number_string`. `used_percentage` may be `38` or `38.2`; token fields should tolerate integer-looking strings too.

Default duplicate field behavior is error. For status input, consider `.duplicate_field_behavior = .use_last` to avoid a hard failure on duplicate JSON keys.

Do not parse the whole transcript as one JSON document. It is JSONL; parse each non-empty line independently and ignore bad/truncated lines.

**Verification Commands**
Executor should run:

```sh
zig version
zig fmt build.zig src/*.zig
zig build test
zig build -Doptimize=ReleaseFast
```

If Zig cache permissions get in the way:

```sh
mkdir -p .zig-cache .zig-global-cache
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build test
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build -Doptimize=ReleaseFast
```

Smoke checks:

```sh
printf '%s\n' '{"model":{"display_name":"deepseek-v4-pro[1m]"},"context_window":{"used_percentage":38.2,"total_input_tokens":380000,"total_output_tokens":2000,"context_window_size":1000000}}' | zig-out/bin/ctxline

printf 'not json\n' | zig-out/bin/ctxline

tmp="$(mktemp)"
printf '%s\n' '{"message":{"content":[{"type":"text","text":"hello world from transcript"}]},"timestamp":"x"}' > "$tmp"
printf '%s\n' "{\"model\":{\"id\":\"deepseek-v4-flash\"},\"transcript_path\":\"$tmp\"}" | zig-out/bin/ctxline
rm "$tmp"

git status --short
```
