# ctxline MVP 验收报告

> 阶段：阶段 3（验收闭环）
> 验收日期：2026-06-05
> 关联方案 doc：.codestable/features/2026-06-05-ctxline-mvp/ctxline-mvp-design.md

## 1. 接口契约核对

**接口示例逐项核对**：

- [x] Native status JSON 示例：`model.display_name=deepseek-v4-pro[1m]` + `context_window.used_percentage=38.2` + `total_input_tokens=380000` + `total_output_tokens=2000` + `context_window_size=1000000`
  - 代码实际行为：`src/status_json.zig` 提取字段，`src/ctxline.zig` 汇总 used=382000/max=1000000/pct=38.2，`src/format.zig` 输出 `382K/1.0M`。
  - Smoke 结果：`deepseek-v4-pro[1m] │ ctx 38.2% │ 382K/1.0M │ ███████░░░░░░░░░░░`。
- [x] Fallback status JSON 示例：`model.id=deepseek-v4-flash` + `transcript_path=/tmp/...`
  - 代码实际行为：`src/transcript.zig` 读取 bounded JSONL，递归估算可见文本，`src/models.zig` 映射 max=128000。
  - Smoke 结果：`deepseek-v4-flash │ ctx 0.0% │ 9/128K │ ░░░░░░░░░░░░░░░░░░`。

**名词层“现状 → 变化”逐项核对**：

- [x] `ContextUsage`：已在 `src/ctxline.zig` 落地，包含 model/used/max/percent/mode。
- [x] model window mapping：已在 `src/models.zig` 落地并有单测。
- [x] transcript estimator：已在 `src/transcript.zig` 落地并有 JSONL/oversized transcript 单测。
- [x] formatter：已在 `src/format.zig` 落地并有 token/bar/output safety 单测。

**流程图核对**：

- [x] 读 stdin → parse status JSON → native/fallback 分支 → model window → format → stdout，节点在 `src/main.zig` / `src/ctxline.zig` / `src/status_json.zig` / `src/transcript.zig` / `src/models.zig` / `src/format.zig` 均有实际落点。

## 2. 行为与决策核对

**需求摘要逐项验证**：

- [x] 作为 Claude Code statusLine command 从 stdin 读 JSON：`src/main.zig` 使用 bounded stdin reader。
- [x] 优先 native `context_window`：`src/ctxline.zig` 检测 native pct/tokens 后走 `.native`。
- [x] 无 native context 时读 `transcript_path`：`src/ctxline.zig` 调用 `transcript.estimateFromJsonlFile`。
- [x] 输出单行 compact status：smoke 输出均为单行，测试 `output formatting is one line and safe` 覆盖。
- [x] malformed JSON 安全 fallback：smoke 输出 `ctxline │ no status json`。

**明确不做逐项核对**：

- [x] 无网络调用或 provider SDK：源码只依赖 Zig stdlib。
- [x] 无 exact tokenizer：MVP 使用 deterministic bytes-per-token 估算并在 README 标注限制。
- [x] 无 persistent cache：README 标注 MVP 未做缓存。
- [x] 不输出 secrets/raw transcript：formatter 只输出 model/pct/tokens/bar，测试确认不泄漏 transcript 文本。

**关键决策落地**：

- [x] `main.zig` 保持 thin：只做 stdin/stdout 和 fallback 调度。
- [x] 动态 JSON：`src/status_json.zig` 使用 `std.json.Value`，支持 `.integer`/`.float`/`.number_string`。
- [x] bounded reads：stdin 和 transcript 均有字节 cap；oversized transcript 使用 prefix 并忽略 partial line。
- [x] Zig 0.16 build API：`build.zig` 使用 `root_module`。

**挂载点反向核对（可卸载性）**：

- [x] Binary mount：`build.zig` 创建 `ctxline` executable。
- [x] Source mount：`src/*.zig` 为核心逻辑。
- [x] CI mount：`.github/workflows/ci.yml`。
- [x] Docs mount：`README.md`、`LICENSE`、`.gitignore`。
- [x] grep/文件盘点确认本 feature 引用集中在上述文件和 CodeStable feature docs 中，无额外挂载点。

## 3. 验收场景核对

- [x] **S1 Native context**：`zig build test` 覆盖 native totals；smoke 输出 `38.2% │ 382K/1.0M`。
- [x] **S2 Native percentage without token totals**：`derive native used tokens from percentage` 单测覆盖。
- [x] **S3 Transcript fallback**：`transcript fallback usage`、`estimate visible transcript bytes from JSONL`、`file estimator keeps bounded prefix for oversized transcripts` 单测覆盖；smoke 覆盖真实二进制。
- [x] **S4 Model mapping**：`model mapping` 单测覆盖 DeepSeek/Claude/unknown。
- [x] **S5 Malformed stdin JSON**：`malformed status json is surfaced by caller` 单测 + smoke 覆盖 fallback line。
- [x] **S6 Output safety**：`output formatting is one line and safe` 单测覆盖单行与不泄漏 raw text。

验证命令：

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig fmt build.zig src/*.zig --check
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build test
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache" zig build -Doptimize=ReleaseFast
```

## 4. 术语一致性

- [x] `status JSON` / `native context` / `transcript_path` / `model window` / `status line` 等术语在 design、README、代码命名中一致。
- [x] 新增代码未引入 design 外的新业务概念；模块名与 architect plan 对齐。

## 5. 架构归并

- [x] `.codestable/architecture/ARCHITECTURE.md` 已归并最终 CLI pipeline、stable contracts、model defaults、known constraints、implementation modules。
- [x] 归并后无需阅读 feature design 即可理解 ctxline 的系统形态和输入/输出契约。

## 6. requirement 回写

- [x] 本项目是单一 CLI MVP，无独立 requirements 文档；本次跳过 requirement 回写。能力愿景已记录在 README + architecture + feature design。

## 7. roadmap 回写

- [x] 非 roadmap 起头，feature design frontmatter 无 `roadmap` / `roadmap_item`，跳过。

## 8. attention.md 候选盘点

- [x] 已在 `.codestable/attention.md` 记录本项目关键本地命令和 `ZIG_GLOBAL_CACHE_DIR` 相关开发命令。无额外候选。

## 9. 遗留

- 后续优化点：
  - 增加 transcript incremental cache，降低 statusLine 高频刷新成本。
  - 增加可配置模型窗口映射表。
  - 增加更精细 tokenizer 或可配置 token 倍率。
  - 增加 release artifact workflow（多平台二进制）可作为后续 feature。
- 已知限制：MVP transcript fallback 是估算；大 transcript 只读 bounded prefix。
- 顺手发现：无。
