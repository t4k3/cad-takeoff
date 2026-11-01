# Tasks — add-compatible-providers-and-sketch-tools

顺序：先 `T150`（provider 兼容层，独立、可先验），再 `T149`（草图工具），最后 `T55`（真实凭据记录）。
每个阶段结束都要跑该阶段的验证命令；只有全绿才勾选。

## 阶段 0 — 任务图（写代码前）

- [x] **P1** 更新 T150 路径，加入 `App/Sources/UI/FusionTakeoffApp.swift`：
      `python3 scripts/graph.py paths T150 "App/Sources/Integration/Assistant,App/Sources/Integration/OpenAI,App/Sources/UI/Assistant,App/Sources/UI/FusionTakeoffApp.swift,App/Resources/Localizable.xcstrings,Tests/AssistantProviders,scripts/test-assistant-deepseek.sh" --by claude`
- [x] **P2** 更新 T149 路径，加入 `Tests/AssistantTools`：
      `python3 scripts/graph.py paths T149 "App/Sources/Model/DesignModel.swift,App/Sources/Model/Tools,Tests/MCPIntegration,Tests/AssistantTools,scripts/test-mcp-integration.sh" --by claude`
- [x] **P3** 在 `docs/COLLAB.md` 追加两条 `PATHS` 说明（append-only，不改他人条目）。

## 阶段 1 — T150 共享配置与 Anthropic 兼容

- [x] **T1.1** `AssistantProvider.swift`：新增 `struct ModelChoice: Identifiable, Sendable, Equatable`（`id`、`name`）。
- [x] **T1.2** `ClaudeProvider.swift`：新增 `AnthropicProviderConfig`（`.claude` / `.compatible` 两个静态配置，
      字段见 spec §B），`init(config:)` 默认 `.claude`，把 `modelID` / `baseURL` 持久化到
      `config.defaultsKey`，`endpoint` 归一化到 `/v1/messages`。
- [x] **T1.3** `ClaudeProvider.runTurn`：`max_tokens`、`system` 结构、`thinking`、`cache_control`、
      `eager_input_streaming`、`fallbacks` 全部按 config 开关；错误文案用 `displayName`。
- [x] **T1.4** `AnthropicStream.swift`：`init(strictStopReasons: Bool = true)`，只放宽未知 `stop_reason`，
      其余完整性校验不变；`ClaudeProvider` 按 `config.strictStopReasons` 传入。
- [x] **T1.5** 验证：`Tests/Electronics/RemoteProviders/run.sh` 全绿（默认 init 与 fixture 不改）。

## 阶段 2 — T150 OpenAI Chat Completions

- [x] **T2.1** 新文件 `App/Sources/Integration/OpenAI/OpenAIChatConversation.swift`：
      `OpenAIChatToolCall`、`OpenAIChatRequestOptions`、`OpenAIChatConversation`（`addUser`/`addAssistant`/
      `addToolResults`/`request(model:system:tools:options:)`），请求体按 spec §D1。
- [x] **T2.2** 新文件 `App/Sources/Integration/OpenAI/OpenAIChatStream.swift`：
      `OpenAIChatStreamAssembler`（`delta.content`、`delta.reasoning_content`、按 index 分片的 `tool_calls`、
      `finish_reason`、`usage`、`error`，`incompleteness` 规则见 spec §D2）。
- [x] **T2.3** 新文件 `App/Sources/Integration/OpenAI/OpenAIChatProvider.swift`：
      `OpenAIChatProviderConfig`（`.chatGPT` / `.deepSeek` / `.compatible`）、provider 全实现、
      endpoint 归一化到 `/chat/completions`、`finish_reason` 分派、reset 代际校验、`httpError`。
- [x] **T2.4** 约束检查：三个新文件只能依赖 Foundation / Observation / `AssistantProvider.swift` /
      `ToolBridge.swift` / `OpenAISSEDecoder`；不 import ClaudeProvider、AppKit、SwiftUI。
- [x] **T2.5** 验证：`scripts/test-openai-provider.sh` 全绿（新文件可独立编译，旧 Responses 测试不变）。
- [x] **T2.6** 验证：`Tests/Electronics/RemoteProviders/run.sh` 仍全绿（新文件被同一脚本编译）。

## 阶段 3 — T150 应用接线与设置页

- [x] **T3.1** `FusionTakeoffApp.swift`：注册 `ClaudeProvider(.claude)`、`OpenAIChatProvider(.chatGPT)`、
      `OpenAIChatProvider(.deepSeek)`、`ClaudeProvider(.compatible)`、`OpenAIChatProvider(.compatible)`，
      最后追加 Apple Intelligence（macOS 27）；`OpenAIProvider` 不再注册。
- [x] **T3.2** `AssistantSettings.swift`：五个分区 + `ProviderKeyRow` 子视图（独立草稿、保存/移除、可选链接、caption）；
      兼容分区显示 base URL 与模型文本框。
- [x] **T3.3** `Localizable.xcstrings`：按 spec §K 新增键（it/en/zh-Hans，`extractionState: manual`），JSON 校验。
- [x] **T3.4** `AssistantSession.swift`：系统提示「Scelte da officina」追加一句草图工具用法（不改结构）。
- [x] **T3.5** 验证：`scripts/test-apple-intelligence.sh` 全绿。

## 阶段 4 — T150 测试与脚本

- [x] **T4.1** 新文件 `Tests/AssistantProviders/Runner.swift`：Keychain stub、`FixtureProtocol`、
      endpoint 归一化断言、assembler 12 组用例（见 spec §J）。
- [x] **T4.2** 新文件 `scripts/test-assistant-deepseek.sh`（`chmod +x`），编译列表与电子测试同构，
      默认只跑离线；`--live` 才联网。
- [x] **T4.3** 验证：`scripts/test-assistant-deepseek.sh` 离线全绿。
- [x] **T4.4** `done T150 --note "…"`。

## 阶段 5 — T149 草图工具

- [x] **T5.1** `CADToolCatalog.swift`：新增 `sketchID`/`shapeID`/`sketchPoint`/`sketchShape`/`skPlane`
      局部 schema，新增 4 个 `ToolSpec`（`list_sketches`、`get_sketch`、`add_sketch`、`extrude_sketch`），
      目录 27 → 31。
- [x] **T5.2** `DesignModel+Tools.swift`：`call` 增加两个只读分支；`mutate` 在 `add_chamfer` 之前拦两个写入；
      新增帮助函数（`listSketches`/`getSketch`/`addSketch`/`extrudeSketch`/`sketchShape(_:)`/`sketchPlane(_:)`/
      `shapeJSON`/`planeJSON`/`vec2JSON`/`nextSketchName`/`nextExtrudeName`）。
- [x] **T5.3** `addSketch` 事务：先解析全部 shape，再 `upsert` + `regenerate`，一次 `commitEdit`；
      `replace` 时清空并 `solve()` 清理悬空约束；已有草图改平面则报错。
- [x] **T5.4** `extrudeSketch`：唯一闭合轮廓的判定、`sketch.regions` 取孔、`placement`（非 XY / 反向 / 带 offset）、
      `keyProfile`、`CADToolValidation.feature`、`SketchLink`、一次 `commitEdit`。
- [x] **T5.5** `Tests/MCPIntegration/Runner.swift`：工具数 37 → 41、文案改 `31 CAD + 10 circuit tools`，
      追加草图往返用例（创建/读取/追加/歧义/拉伸/undo/redo/非法 kind/陈旧 revision）。
- [x] **T5.6** `Tests/AssistantTools/Runner.swift`：27 → 31。
- [x] **T5.7** 验证：`scripts/test-mcp-integration.sh`、`scripts/test-assistant-tools.sh` 全绿。
- [x] **T5.8** `done T149 --note "…"`。

## 阶段 6 — T55 真实凭据验收记录

- [x] **T6.1** `scripts/test-assistant-deepseek.sh --live`（`DEEPSEEK_API_KEY` 从环境读；最多 3 个请求，
      `max_tokens` ≤ 64，无重试）。记录输出摘要，不回显 key。
- [x] **T6.2** 新建 `docs/connectors/E2E.md`：环境、实际跑过的命令/结果、Claude 与 ChatGPT 的真实调用
      为何未跑（无账号 key）、Ross 需人工确认的步骤、失败排查顺序。
- [x] **T6.3** `done T55 --note "…"`。

## 阶段 7 — 全量回归

- [x] **T7.1** `swift test --package-path Packages/CADCore`（265 绿，suite attuale dopo T148）。
- [x] **T7.2** `scripts/test-mcp-integration.sh`、`scripts/test-assistant-tools.sh`、`scripts/test-openai-provider.sh`、
      `scripts/test-apple-intelligence.sh`、`Tests/Electronics/RemoteProviders/run.sh`、`scripts/test-sketch.sh`、
      `scripts/test-shaders.sh` 全绿。
- [x] **T7.3** `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → BUILD SUCCEEDED。
- [x] **T7.4** 不 commit（按用户指示）；把「需要 Ross 在应用里点一遍」的清单写进最终回复。

## 依赖关系

- 阶段 1 与阶段 2 可并行（不同文件），但阶段 3 依赖 1+2（要引用两个 provider 类型）。
- 阶段 5 与阶段 1–4 完全独立（不同目录），可与阶段 2/3 并行。
- 阶段 6 依赖阶段 2（DeepSeek Chat 实现）与阶段 4（脚本）。
- 阶段 7 依赖全部。
