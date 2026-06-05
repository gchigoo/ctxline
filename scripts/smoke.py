#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


def run_ctxline(binary: Path, payload: str, *args: str, timeout: float = 3.0) -> list[str]:
    cmd = [str(binary), *args]
    result = subprocess.run(
        cmd,
        input=payload,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ctxline failed with code {result.returncode}: {result.stdout!r} / {result.stderr!r}")

    lines = result.stdout.splitlines()
    return lines


def assert_one_line(lines: list[str]) -> str:
    if len(lines) != 1:
        raise RuntimeError(f"Expected exactly one output line, got {len(lines)}: {lines!r}")
    return lines[0]


def assert_contains(line: str, needle: str) -> None:
    if needle not in line:
        raise RuntimeError(f"Expected output to contain {needle!r}, got {line!r}")


def smoke_native(binary: Path) -> None:
    payload = '{"model":{"id":"deepseek-v4-pro[1m]"},"context_window":{"used_percentage":38.2,"total_input_tokens":380000,"total_output_tokens":2000,"context_window_size":1000000}}'
    line = assert_one_line(run_ctxline(binary, payload))
    assert_contains(line, "deepseek-v4-pro[1m]")
    assert_contains(line, "38.2%")
    assert_contains(line, "382K/1.0M")


def smoke_malformed_fallback(binary: Path) -> None:
    line = assert_one_line(run_ctxline(binary, "not json"))
    if line != "ctxline │ no status json":
        raise RuntimeError(f"Expected no-status fallback, got {line!r}")


def smoke_transcript_regular(binary: Path, scratch: Path) -> None:
    transcript = scratch / "ctxline-transcript-regular.jsonl"
    transcript.write_text('{"message":{"content":"hello"}}\n', encoding="utf-8")
    payload = json.dumps({"model": {"id": "deepseek-v4-flash"}, "transcript_path": transcript.as_posix()})
    line = assert_one_line(run_ctxline(binary, payload))
    assert_contains(line, "deepseek-v4-flash")
    assert_contains(line, "2/128K")


def smoke_transcript_directory(binary: Path, scratch: Path) -> None:
    directory = scratch / "ctxline-transcript-dir"
    directory.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"model": {"id": "deepseek-v4-flash"}, "transcript_path": directory.as_posix()})
    line = assert_one_line(run_ctxline(binary, payload))
    assert_contains(line, "deepseek-v4-flash")
    assert_contains(line, "0/128K")


def smoke_transcript_fifo_quick(binary: Path, scratch: Path) -> None:
    if not hasattr(os, "mkfifo"):
        return

    fifo = scratch / "ctxline-transcript-fifo.jsonl"
    os.mkfifo(fifo)
    try:
        payload = json.dumps({"model": {"id": "deepseek-v4-flash"}, "transcript_path": fifo.as_posix()})
        start = time.perf_counter()
        line = assert_one_line(run_ctxline(binary, payload, timeout=2.0))
        duration = time.perf_counter() - start
        assert_contains(line, "deepseek-v4-flash")
        assert_contains(line, "0/128K")
        if duration > 2.0:
            raise RuntimeError(f"FIFO fallback took too long: {duration:.2f}s")
    finally:
        try:
            fifo.unlink()
        except FileNotFoundError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(description="Run ctxline smoke checks.")
    parser.add_argument("binary", type=Path, help="Path to ctxline binary")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as workspace:
        scratch = Path(workspace)
        binary = args.binary
        if not binary.exists():
            raise RuntimeError(f"Binary not found: {binary}")

        smoke_native(binary)
        smoke_malformed_fallback(binary)
        smoke_transcript_regular(binary, scratch)
        smoke_transcript_directory(binary, scratch)
        smoke_transcript_fifo_quick(binary, scratch)


if __name__ == "__main__":
    main()
