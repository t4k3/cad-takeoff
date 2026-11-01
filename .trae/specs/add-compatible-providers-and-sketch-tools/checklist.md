# Checklist — add-compatible-providers-and-sketch-tools

## 兼容 provider 层（T150）

* [x] `AssistantProvider.swift` 含 `ModelChoice`，且被 `Tests/Electronics/RemoteProviders/run.sh`、
  `scripts/test-openai-provider.sh`、`scripts/test-apple-intelligence.sh` 三个编译集共享。

* [x] `ClaudeProvider.swift` 保留文件名、类名与无参 `init()`；`ClaudeProvider()` 仍被电子测试编译并跑通。

* [x] `.claude` 请求体与改造前等价：`max_tokens: 64000`、adaptive summarized thinking、ephemeral cache、
  `eager_input_streaming`、opus `fallbacks` + `anthropic-beta`。

* [x] `.compatible`（Anthropic）不发 thinking / cache\_control / eager\_input\_streaming / fallbacks，
  `system` 为普通字符串，`max_tokens: 8192`。

* [x] Anthropic base URL 归一化：`https://api.deepseek.com/anthropic` → `…/anthropic/v1/messages`；
  已带 `/v1/messages` 原样；带 `/v1` → 加 `/messages`。

* [x] `AnthropicStreamAssembler(strictStopReasons:)` 只放宽未知 stop\_reason；缺失 `message_start`/`message_stop`、
  未闭合 block、重复 tool id、`end_turn` 带调用 仍判无效。

* [x] `OpenAIChatConversation.request` 只在 `includeUsage` 时发 `stream_options`，只在 `thinking` 时发
  `thinking`，只在 `reasoningEffort != nil` 时发 `reasoning_effort`；`tools` 为空时省略 `tools`。

* [x] `OpenAIChatStreamAssembler` 处理 `delta.content`、`delta.reasoning_content`、分片 `tool_calls`、`usage`；
  `finish_reason == "length"` → truncated，`"content_filter"` → refused，`"tool_calls"` → toolCalls，
  `"stop"` → done。

* [x] 流不完整（无 finish\_reason / stop 带调用 / tool\_calls 空 / 重复 id / `error` 对象 / HTTP 非 200）
  一律抛 `AssistantError` 且不改历史与文档。

* [x] `OpenAIChatProvider` 三个配置：`.chatGPT`（`https://api.openai.com/v1`、`gpt-6-sol`、includeUsage）、
  `.deepSeek`（`https://api.deepseek.com`、`deepseek-flash`/`deepseek-v4-pro`、thinking+reasoning\_effort medium）、
  `.compatible`（空 base/model、无厂商私有字段）。

* [x] 三个新 OpenAI 文件可用 stub Keychain 独立编译（无 AppKit/SwiftUI/ClaudeProvider 依赖）。

* [x] `FusionTakeoffApp` 注册顺序为 Claude → ChatGPT → DeepSeek → Anthropic 兼容 → OpenAI 兼容 → Apple Intelligence；
  `OpenAIProvider` 仍存在于源码但不注册。

* [x] 设置页五个分区，兼容分区含 Base URL 与模型文本框；每个分区密钥草稿独立，保存/移除生效。

* [x] `Localizable.xcstrings` 新键具备 it/en/zh-Hans 且 `extractionState: manual`，JSON 合法。

* [x] 四个 `setupHint` 与「non configurato」占位在未配置 provider 上可读。

* [x] `scripts/test-assistant-deepseek.sh` 默认离线全绿；`--live` 只在有 `DEEPSEEK_API_KEY` 时联网。

* [x] `Tests/AssistantProviders/Runner.swift` 覆盖 endpoint 归一化与 12 组 assembler 用例。

* [x] `Tests/Electronics/RemoteProviders/run.sh` 23 项 fixture 全绿（未改测试、未改默认行为）。

* [x] `scripts/test-openai-provider.sh`、`scripts/test-apple-intelligence.sh` 全绿。

## 草图工具（T149）

* [x] 工具目录 27 → 31，`list_sketches`/`get_sketch` 只读（无 `expected_revision`），
  `add_sketch`/`extrude_sketch` 写入（自动带 `expected_revision`）。

* [x] `sketchShape` schema 的 enum 只含 9 种 2D 实体（无 `point3D`/`line3D`/`workplane`）。

* [x] 实体解析覆盖 line/polyline/spline/rectangle/circle/polygon/slot/arc/bezier，角度输入输出都用「度」。

* [x] 负的矩形宽高被归一化；坐标与尺寸走 `CADToolValidation`；`sides` 3…64；points ≤ 256。

* [x] 平面解析：`face_point`+`face_normal` 成对、`xy/xz/yz`、`offset`；三者冲突时有明确错误。

* [x] `add_sketch` 先解析全部实体再动文档；`replace` 清空后 `solve()` 清理悬空约束；
  已有草图换平面被拒绝；一次调用一步 undo。

* [x] `add_sketch` 对已有草图调用 `regenerate(from:)`，以该草图 shape 为 seed 的拉伸会更新。

* [x] `extrude_sketch` 无 `shape_id` 且闭合轮廓数 ≠ 1 时报错并列出可选 ID。

* [x] `extrude_sketch` 用 `Sketch.regions` 自动带孔，`hole_count` 与体积正确（40×30×5 = 12000）。

* [x] 非 XY、反向、带 offset 的 `.xy` 草图都使用 `FeaturePlacement(plane:reversed:)`。

* [x] 特征命名默认「Estrusione N」，草图默认「Schizzo N」，均 ≤ 160 字符。

* [x] 拉伸后写入 `SketchLink`（featureID/sketchID/shapeID/holeShapeIDs）。

* [x] `keyProfile(from:)` 被调用，侧面按草图曲线命名。

* [x] 陈旧 revision 与非法 `kind` 都返回错误且文档不变。

* [x] `Tests/MCPIntegration` 工具数 41、文案 `31 CAD + 10 circuit tools`，草图用例全过。

* [x] `Tests/AssistantTools` 断言 31。

* [x] `scripts/test-mcp-integration.sh`、`scripts/test-assistant-tools.sh` 全绿。

## 验收与收尾（T55）

* [x] `DEEPSEEK_API_KEY` 只从环境读取；仓库、脚本、文档里搜不到真实 key。

* [x] DeepSeek OpenAI 格式真实调用成功（1 次），工具调用真实往返（1 次），
  Anthropic 格式真实调用成功（1 次）；总计 3 个请求、提示与回答 di una parola、无重试。

* [x] `docs/connectors/E2E.md` 写明已跑/未跑（Claude、ChatGPT 无账号 key）与 Ross 的人工步骤。

* [x] `swift test --package-path Packages/CADCore` 265 绿（未改 CADCore）。

* [x] `scripts/test-sketch.sh`、`scripts/test-shaders.sh` 回归绿。

* [x] `scripts/build.sh` BUILD SUCCEEDED。

* [x] `python3 scripts/graph.py done T150`、`T149`、`T55` 均写入登记，`docs/COLLAB.md` 有对应条目。

* [x] 没有 commit、没有 `git add -A`、没有修改 `Tests/Electronics/**`。

