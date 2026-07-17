use serde_json::Value;
use std::env;
use std::io::Read;
use std::path::Path;
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");
const NO_STATUS_LINE: &str = "ctxline │ no status json";
const FALLBACK_MODEL: &str = "ctxline";
const MILLION_WINDOW: u64 = 1_000_000;
const FLASH_WINDOW: u64 = 128_000;
const UNKNOWN_WINDOW: u64 = 200_000;
const MAX_NATIVE_CONTEXT_WINDOW_SIZE: u64 = 100_000_000;

const USAGE_TEXT: &str = "Usage: ctxline [--help|-h] [--version]\n\n\
Reads Claude status JSON from stdin and prints a compact context meter.\n\n\
Options:\n\
  -h, --help      show usage and exit 0\n\
      --version   print `ctxline <version>` and exit 0\n\n\
Examples:\n\
  printf '{\"context_window\":{...}}' | ctxline\n\
  ctxline --help\n\
  ctxline --version";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Mode {
    Native,
    Transcript,
    Fallback,
}

#[derive(Debug, Clone, PartialEq)]
struct Options {
    max_stdin_bytes: usize,
    max_transcript_bytes: usize,
    transcript_bytes_per_token: usize,
    bar_width: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            max_stdin_bytes: 256 * 1024,
            max_transcript_bytes: 4 * 1024 * 1024,
            transcript_bytes_per_token: 3,
            bar_width: 18,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
struct ContextUsage {
    model: String,
    used_tokens: u64,
    max_tokens: u64,
    percent: f64,
    mode: Mode,
}

#[derive(Debug, Clone, PartialEq, Default)]
struct StatusInfo {
    model_name: Option<String>,
    used_percentage: Option<f64>,
    total_input_tokens: Option<u64>,
    total_output_tokens: Option<u64>,
    context_window_size: Option<u64>,
    transcript_path: Option<String>,
    invalid_context_window: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StatusError {
    InvalidPayload,
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args
        .iter()
        .skip(1)
        .any(|arg| arg == "--help" || arg == "-h")
    {
        println!("{USAGE_TEXT}");
        return ExitCode::SUCCESS;
    }
    if args.iter().skip(1).any(|arg| arg == "--version") {
        println!("ctxline {VERSION}");
        return ExitCode::SUCCESS;
    }

    let options = Options::default();
    let line = read_bounded_from_stdin(options.max_stdin_bytes)
        .and_then(|input| context_usage_from_status_json(&input, &options))
        .map(|usage| format_context_line(&usage, &options))
        .unwrap_or_else(|_| NO_STATUS_LINE.to_string());

    println!("{line}");
    ExitCode::SUCCESS
}

fn context_usage_from_status_json(
    input: &[u8],
    options: &Options,
) -> Result<ContextUsage, StatusError> {
    let status = parse_status_input(input)?;
    let model = status
        .model_name
        .clone()
        .unwrap_or_else(|| FALLBACK_MODEL.to_string());
    let max_tokens = status
        .context_window_size
        .unwrap_or_else(|| context_window_for_model(Some(&model)));

    if !status.invalid_context_window {
        if status.total_input_tokens.is_some() || status.total_output_tokens.is_some() {
            let input_tokens = status.total_input_tokens.unwrap_or(0);
            let output_tokens = status.total_output_tokens.unwrap_or(0);
            if let Some(sum) = input_tokens.checked_add(output_tokens)
                && sum <= max_tokens
            {
                return Ok(ContextUsage {
                    model,
                    used_tokens: sum,
                    max_tokens,
                    percent: status
                        .used_percentage
                        .unwrap_or_else(|| estimate_percent_from_counts(sum, 0, max_tokens)),
                    mode: Mode::Native,
                });
            }
        } else if let Some(percent) = status.used_percentage {
            return Ok(ContextUsage {
                model,
                used_tokens: estimate_tokens_from_percent(percent, max_tokens),
                max_tokens,
                percent,
                mode: Mode::Native,
            });
        }
    }

    if let Some(path) = status.transcript_path {
        let used_tokens = estimate_from_jsonl_file(
            Path::new(&path),
            EstimateOptions {
                max_transcript_bytes: options.max_transcript_bytes,
                transcript_bytes_per_token: options.transcript_bytes_per_token,
            },
        );
        return Ok(ContextUsage {
            model,
            used_tokens,
            max_tokens,
            percent: estimate_percent_from_counts(used_tokens, 0, max_tokens),
            mode: Mode::Transcript,
        });
    }

    Ok(ContextUsage {
        model,
        used_tokens: 0,
        max_tokens,
        percent: 0.0,
        mode: Mode::Fallback,
    })
}

fn parse_status_input(bytes: &[u8]) -> Result<StatusInfo, StatusError> {
    let root: Value = serde_json::from_slice(bytes).map_err(|_| StatusError::InvalidPayload)?;
    let obj = root.as_object().ok_or(StatusError::InvalidPayload)?;
    let mut info = StatusInfo::default();

    if let Some(model_obj) = obj.get("model").and_then(Value::as_object) {
        info.model_name = model_obj
            .get("display_name")
            .and_then(Value::as_str)
            .or_else(|| model_obj.get("id").and_then(Value::as_str))
            .map(ToOwned::to_owned);
    }

    if let Some(context_window) = obj.get("context_window").and_then(Value::as_object) {
        if let Some(value) = context_window.get("used_percentage") {
            match number_to_f64(value).and_then(sanitize_native_percent) {
                Some(percent) => info.used_percentage = Some(percent),
                None => info.invalid_context_window = true,
            }
        }
        parse_native_u64(
            context_window.get("total_input_tokens"),
            &mut info.total_input_tokens,
            &mut info.invalid_context_window,
            false,
        );
        parse_native_u64(
            context_window.get("total_output_tokens"),
            &mut info.total_output_tokens,
            &mut info.invalid_context_window,
            false,
        );
        parse_native_u64(
            context_window.get("context_window_size"),
            &mut info.context_window_size,
            &mut info.invalid_context_window,
            true,
        );
    }

    info.transcript_path = obj
        .get("transcript_path")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    Ok(info)
}

fn parse_native_u64(
    value: Option<&Value>,
    target: &mut Option<u64>,
    invalid_context_window: &mut bool,
    require_non_zero: bool,
) {
    let Some(value) = value else { return };
    let Some(parsed) = number_to_u64(value) else {
        *invalid_context_window = true;
        return;
    };
    if require_non_zero && (parsed == 0 || parsed > MAX_NATIVE_CONTEXT_WINDOW_SIZE) {
        *invalid_context_window = true;
        return;
    }
    *target = Some(parsed);
}

fn number_to_f64(value: &Value) -> Option<f64> {
    value.as_number()?.as_f64()
}

fn number_to_u64(value: &Value) -> Option<u64> {
    let number = value.as_number()?;
    if let Some(unsigned) = number.as_u64() {
        return Some(unsigned);
    }
    exact_u64_from_float(number.as_f64()?)
}

fn exact_u64_from_float(raw: f64) -> Option<u64> {
    const MAX_EXACT_FLOAT_INTEGER: f64 = 9_007_199_254_740_992.0;
    if !raw.is_finite() || !(0.0..=MAX_EXACT_FLOAT_INTEGER).contains(&raw) || raw.trunc() != raw {
        return None;
    }
    Some(raw as u64)
}

fn sanitize_native_percent(percent: f64) -> Option<f64> {
    if percent.is_finite() && (0.0..=100.0).contains(&percent) {
        Some(percent)
    } else {
        None
    }
}

fn estimate_tokens_from_percent(percent: f64, max_tokens: u64) -> u64 {
    if max_tokens == 0 {
        return 0;
    }
    ((percent * max_tokens as f64) / 100.0).floor() as u64
}

fn estimate_percent_from_counts(used_tokens: u64, output_tokens: u64, max_tokens: u64) -> f64 {
    if max_tokens == 0 {
        return 0.0;
    }
    let used = used_tokens.saturating_add(output_tokens);
    (used as f64 / max_tokens as f64) * 100.0
}

fn context_window_for_model(model_name: Option<&str>) -> u64 {
    let Some(name) = model_name else {
        return UNKNOWN_WINDOW;
    };
    if name.eq_ignore_ascii_case("deepseek-v4-pro[1m]")
        || name.eq_ignore_ascii_case("deepseek-v4-pro")
    {
        return MILLION_WINDOW;
    }
    if name.eq_ignore_ascii_case("deepseek-v4-flash") {
        return FLASH_WINDOW;
    }
    let lower = name.to_ascii_lowercase();
    if lower.contains("claude") && lower.contains("1m") {
        return MILLION_WINDOW;
    }
    UNKNOWN_WINDOW
}

#[derive(Debug, Clone, Copy)]
struct EstimateOptions {
    max_transcript_bytes: usize,
    transcript_bytes_per_token: usize,
}

fn estimate_from_jsonl_file(path: &Path, opts: EstimateOptions) -> u64 {
    let Ok(metadata) = std::fs::metadata(path) else {
        return 0;
    };
    if !metadata.is_file() {
        return 0;
    }
    let Ok(mut file) = std::fs::File::open(path) else {
        return 0;
    };
    let mut bytes = Vec::with_capacity(opts.max_transcript_bytes.min(4096));
    if (&mut file)
        .take(opts.max_transcript_bytes as u64)
        .read_to_end(&mut bytes)
        .is_err()
    {
        return 0;
    }
    estimate_from_jsonl_bytes(&bytes, opts)
}

fn estimate_from_jsonl_bytes(bytes: &[u8], opts: EstimateOptions) -> u64 {
    let mut visible_bytes = 0_u64;
    for line in bytes.split(|byte| *byte == b'\n') {
        let line = trim_ascii(line);
        if line.is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(line) {
            visible_bytes = visible_bytes.saturating_add(count_visible_bytes(&value, false));
        }
    }
    if opts.transcript_bytes_per_token == 0 || visible_bytes == 0 {
        return 0;
    }
    visible_bytes.div_ceil(opts.transcript_bytes_per_token as u64)
}

fn trim_ascii(mut bytes: &[u8]) -> &[u8] {
    while matches!(bytes.first(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
        bytes = &bytes[1..];
    }
    while matches!(bytes.last(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
        bytes = &bytes[..bytes.len() - 1];
    }
    bytes
}

fn count_visible_bytes(value: &Value, visible_context: bool) -> u64 {
    match value {
        Value::String(text) => {
            if visible_context {
                text.len() as u64
            } else {
                0
            }
        }
        Value::Array(items) => items
            .iter()
            .map(|item| count_visible_bytes(item, visible_context))
            .fold(0_u64, u64::saturating_add),
        Value::Object(obj) => obj
            .iter()
            .filter(|(key, _)| !is_metadata_key(key))
            .map(|(key, child)| count_visible_bytes(child, visible_context || is_visible_key(key)))
            .fold(0_u64, u64::saturating_add),
        _ => 0,
    }
}

fn is_visible_key(key: &str) -> bool {
    matches!(key, "content" | "text" | "tool_result" | "message")
}

fn is_metadata_key(key: &str) -> bool {
    matches!(
        key,
        "id" | "uuid"
            | "timestamp"
            | "session_id"
            | "parent_uuid"
            | "role"
            | "type"
            | "model"
            | "usage"
            | "metadata"
    )
}

fn format_context_line(usage: &ContextUsage, options: &Options) -> String {
    format_status_line(
        &usage.model,
        usage.percent,
        usage.used_tokens,
        usage.max_tokens,
        options.bar_width,
    )
}

fn clamp_percent(raw: f64) -> f64 {
    raw.clamp(0.0, 100.0)
}

fn format_percent(percent: f64) -> String {
    let value = clamp_percent(percent);
    if value == value.round() {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    }
}

fn format_tokens(token_count: u64) -> String {
    if token_count < 1000 {
        return token_count.to_string();
    }
    if token_count >= 1_000_000 {
        return format_with_unit(token_count, 1_000_000, "M", token_count == 1_000_000);
    }
    format_with_unit(token_count, 1000, "K", token_count == 1000)
}

fn format_with_unit(token_count: u64, unit: u64, suffix: &str, force_decimal: bool) -> String {
    let exact_units = token_count % unit == 0;
    if exact_units && !force_decimal {
        return format!("{}{}", token_count / unit, suffix);
    }
    format!("{:.1}{}", token_count as f64 / unit as f64, suffix)
}

fn format_bar(percent: f64, width: usize) -> String {
    let safe_percent = clamp_percent(percent);
    let filled = ((safe_percent * width as f64) / 100.0)
        .round()
        .min(width as f64) as usize;
    let mut bar = String::with_capacity(width * "█".len());
    for index in 0..width {
        if index < filled {
            bar.push('█');
        } else {
            bar.push('░');
        }
    }
    bar
}

fn format_status_line(
    model: &str,
    percent: f64,
    used_tokens: u64,
    max_tokens: u64,
    bar_width: usize,
) -> String {
    format!(
        "{} │ ctx {}% │ {}/{} │ {}",
        sanitize_model_text(model),
        format_percent(percent),
        format_tokens(used_tokens),
        format_tokens(max_tokens),
        format_bar(percent, bar_width)
    )
}

fn sanitize_model_text(model: &str) -> String {
    const MAX_MODEL_TEXT_BYTES: usize = 64;
    let mut bytes = Vec::with_capacity(model.len().min(MAX_MODEL_TEXT_BYTES));
    for byte in model.as_bytes().iter().take(MAX_MODEL_TEXT_BYTES).copied() {
        if byte < 0x20 || byte == 0x7f || (0x80..=0x9f).contains(&byte) {
            bytes.push(b'?');
        } else {
            bytes.push(byte);
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn read_bounded_from_stdin(max_bytes: usize) -> Result<Vec<u8>, StatusError> {
    if max_bytes == 0 {
        return Ok(Vec::new());
    }
    read_bounded_from_stdin_platform(max_bytes)
}

#[cfg(not(windows))]
fn read_bounded_from_stdin_platform(max_bytes: usize) -> Result<Vec<u8>, StatusError> {
    let stdin = std::io::stdin();
    let mut stdin = stdin.lock();
    let mut output = Vec::with_capacity(max_bytes.min(4096));
    let mut chunk = [0_u8; 4096];

    while output.len() < max_bytes {
        let read_len = (max_bytes - output.len()).min(chunk.len());
        let bytes_read = stdin
            .read(&mut chunk[..read_len])
            .map_err(|_| StatusError::InvalidPayload)?;
        if bytes_read == 0 {
            break;
        }
        output.extend_from_slice(&chunk[..bytes_read]);
        if is_complete_top_level_json_value(&output) {
            break;
        }
    }

    if output.len() >= max_bytes && !is_complete_top_level_json_value(&output) {
        return Err(StatusError::InvalidPayload);
    }
    Ok(output)
}

#[cfg(windows)]
fn read_bounded_from_stdin_platform(max_bytes: usize) -> Result<Vec<u8>, StatusError> {
    windows_stdin::read_bounded(max_bytes)
}

fn is_complete_top_level_json_value(data: &[u8]) -> bool {
    let Some(&first) = data.first() else {
        return false;
    };
    let (opener, closer) = match first {
        b'{' => (b'{', b'}'),
        b'[' => (b'[', b']'),
        _ => return true,
    };

    let mut depth = 0_usize;
    let mut index = 0_usize;
    while index < data.len() {
        match data[index] {
            byte if byte == opener => depth += 1,
            byte if byte == closer => {
                if depth == 0 {
                    return false;
                }
                depth -= 1;
                if depth == 0 {
                    return true;
                }
            }
            b'"' => {
                index += 1;
                while index < data.len() {
                    if data[index] == b'\\' {
                        index += 1;
                        if index >= data.len() {
                            return false;
                        }
                    } else if data[index] == b'"' {
                        break;
                    }
                    index += 1;
                }
            }
            _ => {}
        }
        index += 1;
    }
    false
}

#[cfg(windows)]
mod windows_stdin {
    use super::{StatusError, is_complete_top_level_json_value};
    use std::ffi::c_void;
    use std::ptr;

    type Bool = i32;
    type Dword = u32;
    type Handle = *mut c_void;

    const STD_INPUT_HANDLE: Dword = -10_i32 as Dword;
    const FILE_TYPE_DISK: Dword = 0x0001;
    const FILE_TYPE_CHAR: Dword = 0x0002;
    const FILE_TYPE_PIPE: Dword = 0x0003;
    const FILE_TYPE_MASK: Dword = 0x000f;
    const ERROR_HANDLE_EOF: Dword = 38;
    const ERROR_BROKEN_PIPE: Dword = 109;
    const ERROR_NO_DATA: Dword = 232;
    const STDIN_PIPE_TIMEOUT_MS: u64 = 3000;
    const STDIN_PIPE_POLL_MS: Dword = 10;

    unsafe extern "system" {
        fn GetStdHandle(nStdHandle: Dword) -> Handle;
        fn GetFileType(hFile: Handle) -> Dword;
        fn ReadFile(
            hFile: Handle,
            lpBuffer: *mut u8,
            nNumberOfBytesToRead: Dword,
            lpNumberOfBytesRead: *mut Dword,
            lpOverlapped: *mut c_void,
        ) -> Bool;
        fn PeekNamedPipe(
            hNamedPipe: Handle,
            lpBuffer: *mut u8,
            nBufferSize: Dword,
            lpBytesRead: *mut Dword,
            lpTotalBytesAvail: *mut Dword,
            lpBytesLeftThisMessage: *mut Dword,
        ) -> Bool;
        fn GetLastError() -> Dword;
        fn GetTickCount64() -> u64;
        fn Sleep(dwMilliseconds: Dword);
    }

    pub fn read_bounded(max_bytes: usize) -> Result<Vec<u8>, StatusError> {
        let stdin_handle = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        if stdin_handle.is_null() || stdin_handle as isize == -1 {
            return Err(StatusError::InvalidPayload);
        }
        match unsafe { GetFileType(stdin_handle) } & FILE_TYPE_MASK {
            FILE_TYPE_CHAR => Ok(Vec::new()),
            FILE_TYPE_DISK => read_file(stdin_handle, max_bytes),
            FILE_TYPE_PIPE => read_pipe(stdin_handle, max_bytes),
            _ => Ok(Vec::new()),
        }
    }

    fn read_file(handle: Handle, max_bytes: usize) -> Result<Vec<u8>, StatusError> {
        let mut output = Vec::with_capacity(max_bytes.min(4096));
        let mut chunk = [0_u8; 4096];
        while output.len() < max_bytes {
            let read_len = (max_bytes - output.len()).min(chunk.len()) as Dword;
            let mut bytes_read = 0_u32;
            let ok = unsafe {
                ReadFile(
                    handle,
                    chunk.as_mut_ptr(),
                    read_len,
                    &mut bytes_read,
                    ptr::null_mut(),
                )
            };
            if ok == 0 {
                let err = unsafe { GetLastError() };
                if is_expected_end(err) {
                    break;
                }
                return Err(StatusError::InvalidPayload);
            }
            if bytes_read == 0 {
                break;
            }
            output.extend_from_slice(&chunk[..bytes_read as usize]);
            if is_complete_top_level_json_value(&output) {
                break;
            }
        }
        if output.len() >= max_bytes && !is_complete_top_level_json_value(&output) {
            return Err(StatusError::InvalidPayload);
        }
        Ok(output)
    }

    fn read_pipe(handle: Handle, max_bytes: usize) -> Result<Vec<u8>, StatusError> {
        let mut output = Vec::with_capacity(max_bytes.min(4096));
        let mut chunk = [0_u8; 4096];
        let mut deadline = unsafe { GetTickCount64() } + STDIN_PIPE_TIMEOUT_MS;

        while output.len() < max_bytes {
            let mut available = 0_u32;
            let ok = unsafe {
                PeekNamedPipe(
                    handle,
                    ptr::null_mut(),
                    0,
                    ptr::null_mut(),
                    &mut available,
                    ptr::null_mut(),
                )
            };
            if ok == 0 {
                let err = unsafe { GetLastError() };
                if is_expected_end(err) {
                    break;
                }
                return Err(StatusError::InvalidPayload);
            }
            if available == 0 {
                if unsafe { GetTickCount64() } >= deadline {
                    break;
                }
                unsafe { Sleep(STDIN_PIPE_POLL_MS) };
                continue;
            }

            let read_len = (max_bytes - output.len())
                .min(chunk.len())
                .min(available as usize) as Dword;
            let mut bytes_read = 0_u32;
            let ok = unsafe {
                ReadFile(
                    handle,
                    chunk.as_mut_ptr(),
                    read_len,
                    &mut bytes_read,
                    ptr::null_mut(),
                )
            };
            if ok == 0 {
                let err = unsafe { GetLastError() };
                if is_expected_end(err) {
                    break;
                }
                return Err(StatusError::InvalidPayload);
            }
            if bytes_read == 0 {
                break;
            }
            output.extend_from_slice(&chunk[..bytes_read as usize]);
            if is_complete_top_level_json_value(&output) {
                break;
            }
            deadline = unsafe { GetTickCount64() } + STDIN_PIPE_TIMEOUT_MS;
        }
        if output.len() >= max_bytes && !is_complete_top_level_json_value(&output) {
            return Err(StatusError::InvalidPayload);
        }
        Ok(output)
    }

    fn is_expected_end(err: Dword) -> bool {
        matches!(err, ERROR_BROKEN_PIPE | ERROR_HANDLE_EOF | ERROR_NO_DATA)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn native_context_usage_from_status_line() {
        let input = br#"{"model":{"id":"deepseek-v4-pro[1m]"},"context_window":{"used_percentage":38.2,"total_input_tokens":380000,"total_output_tokens":2000,"context_window_size":1000000}}"#;
        let usage = context_usage_from_status_json(input, &Options::default()).unwrap();
        assert_eq!(Mode::Native, usage.mode);
        assert_eq!("deepseek-v4-pro[1m]", usage.model);
        assert_eq!(382000, usage.used_tokens);
        assert_eq!(1_000_000, usage.max_tokens);
        assert!((usage.percent - 38.2).abs() < 0.0001);
    }

    #[test]
    fn invalid_native_fields_fall_back() {
        let input = br#"{"model":{"display_name":"deepseek-v4-flash"},"context_window":{"used_percentage":125.0,"context_window_size":128000}}"#;
        let usage = context_usage_from_status_json(input, &Options::default()).unwrap();
        assert_eq!(Mode::Fallback, usage.mode);
        assert_eq!(0, usage.used_tokens);
        assert_eq!(128_000, usage.max_tokens);
    }

    #[test]
    fn valid_percentage_does_not_mask_invalid_native_token_sum() {
        let input = br#"{"model":{"id":"deepseek-v4-flash"},"context_window":{"used_percentage":1.0,"total_input_tokens":1000,"total_output_tokens":1,"context_window_size":1000}}"#;
        let usage = context_usage_from_status_json(input, &Options::default()).unwrap();
        assert_eq!(Mode::Fallback, usage.mode);
        assert_eq!(0, usage.used_tokens);
        assert_eq!(1000, usage.max_tokens);
    }

    #[test]
    fn transcript_estimate_counts_visible_jsonl_text() {
        let lines = br#"{"message":{"content":[{"type":"text","text":"hello"},{"text":"world"}]},"uuid":"x"}
{"tool_result":{"output":{"message":{"content":"from"}}}}
not-json
{"metadata":{"text":"secret"},"content":"ok"}
{"id":"m","type":"text"}"#;
        let estimate = estimate_from_jsonl_bytes(
            lines,
            EstimateOptions {
                max_transcript_bytes: 10_000,
                transcript_bytes_per_token: 3,
            },
        );
        assert_eq!(6, estimate);
    }

    #[test]
    fn file_estimator_ignores_non_regular_paths() {
        let path = std::env::temp_dir().join(format!("ctxline-dir-{}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        let estimate = estimate_from_jsonl_file(
            &path,
            EstimateOptions {
                max_transcript_bytes: 1024,
                transcript_bytes_per_token: 1,
            },
        );
        assert_eq!(0, estimate);
        let _ = fs::remove_dir(path);
    }

    #[test]
    fn format_matches_existing_boundaries() {
        assert_eq!("999", format_tokens(999));
        assert_eq!("1.0K", format_tokens(1000));
        assert_eq!("382K", format_tokens(382_000));
        assert_eq!("1.0M", format_tokens(1_000_000));
        let line = format_status_line("deepseek\nv4\t\x1b[31m\rsafe", 12.5, 1000, 2000, 18);
        assert!(!line.contains('\n'));
        assert!(!line.contains('\r'));
        assert!(!line.contains('\t'));
        assert!(!line.contains('\x1b'));
    }

    #[test]
    fn json_value_completion_handles_braces_inside_strings() {
        assert!(is_complete_top_level_json_value(br#"{"x":"}","y":[1]}"#));
        assert!(!is_complete_top_level_json_value(br#"{"x":"}","y":[1]"#));
    }
}
