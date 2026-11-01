# Assistants: Claude / ChatGPT / DeepSeek first-class + sketch MCP tools — Spec

Stato: **in attesa di approvazione** (nessun commit, come da istruzione di Ross).

对应任务：`T150`（兼容 provider）与 `T149`（草图 MCP 工具），最后 `T55` 做真实凭据验收记录。

## Why

两件事都卡在实际使用上：

1. **助手只能接 Claude 和 OpenAI Responses**。用户明确要求把 Claude 与 ChatGPT 改成两种「兼容接口」接入——
   Anthropic Messages 兼容 与 OpenAI Chat Completions 兼容——这样 DeepSeek 以及其他遵循这两种协议的模型
   都能直接选；Claude / ChatGPT / DeepSeek 作为一等公民并行出现，其余模型走「兼容」入口自填 base URL 和模型名。
2. **助手/ MCP 看不到草图**。模型目前只能画 box/cylinder/extrude 多边形，不能列出、读取、创建草图实体，
   也不能把草图区域（含内孔）直接拉伸。草图是 CAD 的主入口，缺了它助手只能造「盲盒几何」。

`T55` 是收尾：把真实凭据能跑到的部分跑一遍并写进 `docs/connectors/E2E.md`，把必须在 Ross 机器上人工确认的部分列清楚。

## What Changes

- **新增 `OpenAIChatProvider`**（Chat Completions 协议）+ 独立的组装器与历史容器；支持
  `.chatGPT`、`.deepSeek`、`.openAICompatible` 三种配置。
- **改造 `ClaudeProvider`**：把硬编码的 base URL / models / max_tokens / thinking / cache / fallbacks
  参数化到 `AnthropicProviderConfig`，新增 `.compatible`（Anthropic 兼容）配置；**文件名、类名、默认
  `init()` 保持不变**（`Tests/Electronics/RemoteProviders/run.sh` 直接编译并调用它）。
- **`AnthropicStreamAssembler` 增加 `strictStopReasons`**：兼容端点返回未知 `stop_reason` 时不再直接判为无效，
  其余流完整性校验（started/finished/content_block_stop/重复 tool id）全部保持 fail-closed。
- **应用注册顺序**：Claude → ChatGPT → DeepSeek → Anthropic 兼容 → OpenAI 兼容 → Apple Intelligence（macOS 27）；
  `OpenAIProvider`（Responses）保留在源码里作为电子测试用的适配器，但不再注册到会话。
- **设置页重写**：按已注册 provider 渲染分区；一等公民用模型 Picker，兼容入口多一个 base URL 文本框与模型文本框，
  密钥编辑抽成一个可复用子视图（每区独立草稿）。
- **草图工具（`CADToolCatalog` 27 → 31）**：`list_sketches`、`get_sketch`、`add_sketch`、`extrude_sketch`；
  后者自动带内孔与正确的工作平面/反向放置，一次调用一步 undo。
- **测试**：`Tests/AssistantProviders`（离线 fixture + 可选 `--live` DeepSeek）、`scripts/test-assistant-deepseek.sh`；
  MCP 集成测试 37 → 41 工具并新增草图往返；`Tests/AssistantTools` 断言 27 → 31。
- **文档**：`docs/connectors/E2E.md`（T55）记录实际验证范围、命令、证据与仍需人工确认的部分。

**不属于本次**：删除或重写 `OpenAIProvider`、`OpenAIStream.swift`、`Tests/OpenAIProvider`；改 `Tests/Electronics/**`；
给 `CADCore` 加任何新 API（草图工具只用现有公开 API）；把 API key 写进仓库。

## Impact

- Affected specs: T150（assistant providers）、T149（sketch MCP）、T55（connector E2E）。
- Affected code:
  `App/Sources/Integration/Assistant/`、`App/Sources/Integration/OpenAI/`、`App/Sources/UI/Assistant/`、
  `App/Sources/UI/FusionTakeoffApp.swift`、`App/Resources/Localizable.xcstrings`、
  `App/Sources/Model/Tools/`、`App/Sources/Model/DesignModel.swift`、
  `Tests/AssistantProviders/`、`Tests/MCPIntegration/`、`Tests/AssistantTools/`、
  `scripts/test-assistant-deepseek.sh`、`scripts/test-mcp-integration.sh`、`docs/connectors/E2E.md`。
- 兼容性：协议请求体变化只影响 `.compatible` 配置；`.claude` 与 `.chatGPT` 的请求保持与今天等价
  （`.chatGPT` 从 Responses 改为 Chat Completions 是有意的 **BREAKING**，但设置页与用户偏好沿用同一个 Keychain service）。

## ADDED Requirements

### Requirement: 一等公民 Claude、ChatGPT、DeepSeek 并行

系统 SHALL 在同一会话里注册 Claude、ChatGPT、DeepSeek 三个已配置即可用的 provider，且模型选择器能同时看到它们。

#### Scenario: 同时配置三家
- **WHEN** 用户在 设置 → 助手 里分别填入 Anthropic、OpenAI、DeepSeek 的 key
- **THEN** 三个分区都显示「已保存」，聊天面板的 provider 选择器可切到 Claude / ChatGPT / DeepSeek，切换会重置对话

#### Scenario: 只配一家
- **WHEN** 只填了 DeepSeek key
- **THEN** `AssistantSession` 自动选中第一个 `isConfigured` 的 provider（DeepSeek），其余显示 `setupHint`

### Requirement: 两种兼容入口

系统 SHALL 提供「Anthropic 兼容」与「OpenAI 兼容」两个可自定义 base URL 与模型名的入口，使用户能接入任意遵循对应协议的模型。

#### Scenario: 接入第三方 Anthropic 兼容端点
- **WHEN** 用户在 Anthropic 兼容分区填入 base URL `https://api.deepseek.com/anthropic`、模型 `deepseek-flash`、key
- **THEN** `ClaudeProvider(config: .compatible)` 向 `<base>/v1/messages` 发 `x-api-key` + `anthropic-version` 请求，不发送 thinking / cache_control / eager_input_streaming / fallbacks

#### Scenario: 接入第三方 OpenAI 兼容端点
- **WHEN** 用户填入 base URL `https://api.deepseek.com`、模型 `deepseek-flash`、key
- **THEN** `OpenAIChatProvider(config: .openAICompatible)` 向 `<base>/chat/completions` 发 `Authorization: Bearer`，不附加任何厂商私有字段

### Requirement: Chat Completions 的工具调用

系统 SHALL 通过 Chat Completions 完成与本机工具层的往返：`tools[].function` 声明、`tool_calls` 增量拼装、
`role: "tool"` 回传结果、`finish_reason` 决定 `AssistantStop`。

#### Scenario: 模型要求调用工具
- **WHEN** 流里出现 `delta.tool_calls[]`（按 `index` 分片，`function.arguments` 分片到达）且 `finish_reason == "tool_calls"`
- **THEN** 返回 `.toolCalls`，参数是完整 JSON，`id`/`name` 不为空；下一轮把每个结果作为一条 `role: "tool"` 消息回传

#### Scenario: 流被截断
- **WHEN** `finish_reason == "length"`
- **THEN** 返回 `.truncated`，该轮的工具调用不执行，也不进入历史（与 Claude 一致）

#### Scenario: 内容被过滤
- **WHEN** `finish_reason == "content_filter"`
- **THEN** 返回 `.refused`，该轮不进入历史

#### Scenario: 不完整或自相矛盾的流
- **WHEN** 流结束时没有 `finish_reason`，或 `finish_reason == "stop"` 却带 tool_calls，或出现重复 tool id，或 HTTP 非 200
- **THEN** 抛出 `AssistantError`，文档与历史都不受影响（fail closed）

### Requirement: 草图工具（MCP 与助手共用同一目录）

系统 SHALL 在工具目录里提供 4 个草图工具，参数校验、revision 与 undo 语义与现有 CAD 工具一致。

#### Scenario: 创建并读取草图
- **WHEN** 模型调用 `add_sketch`（plane `xy`，一个 40×30 的 rectangle）随后 `get_sketch`
- **THEN** 文档多出一个草图，`get_sketch` 返回该 rectangle 的 `kind`、`width`、`height`、`area = 1200`，revision 已推进

#### Scenario: 追加实体
- **WHEN** 对同一草图再次 `add_sketch`（`replace` 缺省/false，追加一个圆心 (20,15) 半径 5 的 circle）
- **THEN** 草图有两个实体，一次 undo 只回退这一次追加

#### Scenario: 拉伸指定区域，自动带孔
- **WHEN** `extrude_sketch` 指定 `shape_id` = 外矩形、`height` = 5
- **THEN** 生成一个 extrude 特征，孔来自 `Sketch.regions` 里属于该矩形的内轮廓，体积等于外面积减孔面积乘高度；一次 undo 回退该特征

#### Scenario: 多个闭合轮廓却不指定
- **WHEN** 草图有两个闭合轮廓（矩形 + 圆）而 `extrude_sketch` 没有 `shape_id`
- **THEN** 返回错误，列出可选的 `shape_id`，文档不变

#### Scenario: 陈旧 revision
- **WHEN** 用过期的 `expected_revision` 调用 `add_sketch` 或 `extrude_sketch`
- **THEN** 返回错误且文档不变（现有 `call` 的校验路径直接生效）

## MODIFIED Requirements

### Requirement: Claude provider 可配置化

`ClaudeProvider` SHALL 保留默认 `init()`（= `.claude` 配置）与类名/文件名，同时接受 `init(config:)`：
`baseURL`、`modelID`、`max_tokens`、`thinking`、`cache_control`、`eager_input_streaming`、`fallbacks` 由配置决定。
`.claude` 的请求体与今天等价（`max_tokens: 64000`，adaptive summarized thinking，ephemeral cache，opus fallbacks）。

#### Scenario: 电子测试仍可编译
- **WHEN** `Tests/Electronics/RemoteProviders/run.sh` 编译 `ClaudeProvider.swift` 并调用 `ClaudeProvider()`
- **THEN** 编译通过，行为与今天一致（fixture 断言不变）

### Requirement: 设置页按 provider 渲染

设置页 SHALL 不再硬编码 Claude/OpenAI 两段，而是遍历 `session.providers` 的已知类型，
按 `config.kind` 渲染：Claude、ChatGPT、DeepSeek 用模型 Picker；两个兼容入口多 base URL 与模型文本框；
每个分区独立密钥草稿，可保存/移除。

## 技术设计（decision-complete）

### A. 共享类型 — `App/Sources/Integration/Assistant/AssistantProvider.swift`

在 `ToolCallRequest` 之前新增（此文件被 4 个测试脚本编译，是唯一安全的共享位置）：

```swift
struct ModelChoice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}
```

### B. Anthropic 侧 — `App/Sources/Integration/Assistant/ClaudeProvider.swift`

同文件内新增（放在 `ClaudeProvider` 之前；**不要新建文件**，否则 `Tests/Electronics/RemoteProviders/run.sh` 不编译它）：

```swift
struct AnthropicProviderConfig: Sendable, Equatable {
    enum Kind: String, Sendable { case claude, compatible }
    let kind: Kind
    let displayName: String
    let keychainService: String
    let defaultsKey: String            // UserDefaults 前缀，model 用 "<defaultsKey>.model"，base 用 "<defaultsKey>.base"
    let defaultBaseURL: String
    let defaultModel: String
    let models: [ModelChoice]
    let maxTokens: Int
    let adaptiveThinking: Bool
    let promptCaching: Bool
    let eagerToolStreaming: Bool
    let serverFallbacks: Bool
    let strictStopReasons: Bool

    static let claude = AnthropicProviderConfig(
        kind: .claude, displayName: "Claude",
        keychainService: "com.takeoff.fusiontakeoff.anthropic-api-key",
        defaultsKey: "assistant.claude",
        defaultBaseURL: "https://api.anthropic.com",
        defaultModel: "claude-opus-5",
        models: [ModelChoice(id: "claude-opus-5", name: "Claude Opus 5"),
                 ModelChoice(id: "claude-sonnet-5", name: "Claude Sonnet 5")],
        maxTokens: 64000, adaptiveThinking: true, promptCaching: true,
        eagerToolStreaming: true, serverFallbacks: true, strictStopReasons: true)

    static let compatible = AnthropicProviderConfig(
        kind: .compatible, displayName: String(localized: "Anthropic compatibile"),
        keychainService: "com.takeoff.fusiontakeoff.anthropic-compatible-api-key",
        defaultsKey: "assistant.anthropic-compatible",
        defaultBaseURL: "", defaultModel: "", models: [],
        maxTokens: 8192, adaptiveThinking: false, promptCaching: false,
        eagerToolStreaming: false, serverFallbacks: false, strictStopReasons: false)
    var allowsCustomEndpoint: Bool { kind == .compatible }
}
```

`ClaudeProvider` 变更：

- `let config: AnthropicProviderConfig`
- `init(config: AnthropicProviderConfig = .claude)`；`displayName = config.displayName`；
  `modelID` 初值 `UserDefaults(config.defaultsKey+".model") ?? config.defaultModel`；
  `baseURL` 初值 `UserDefaults(config.defaultsKey+".base") ?? config.defaultBaseURL`；
  `modelID`/`baseURL` 的 `didSet` 写入对应 UserDefaults（去掉过期值时空串保存）。
- `var models: [ModelChoice] { config.models }`
- `var modelName: String { config.models.first { $0.id == modelID }?.name ?? (modelID.isEmpty ? String(localized: "non configurato") : modelID) }`
- `isConfigured`: `hasKey && !modelID.isEmpty && !baseURL.isEmpty && !endpoint.absoluteString.isEmpty`
- `setAPIKey(_:)` 用 `config.keychainService`
- 请求 URL 归一化（`private var endpoint: URL?`）：

```swift
let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmed.hasSuffix("/v1/messages") { return URL(string: trimmed) }
if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/messages") }
return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")
```

- 请求体按 config 构建：
  - `max_tokens`: `config.maxTokens`
  - `thinking` / `cache_control` 只在 `adaptiveThinking` / `promptCaching` 为真
  - `system`: `adaptiveThinking` 时保持 `[{"type":"text","text":…}]`，否则退化为普通字符串
  - `tools[]`: `eager_input_streaming` 只在 `eagerToolStreaming` 为真
  - `fallbacks` + `anthropic-beta` 只在 `serverFallbacks && modelID == "claude-opus-5"`
- 组装器 `AnthropicStreamAssembler(strictStopReasons: config.strictStopReasons)`
- 错误文案用 `displayName` 代替硬编码 “Claude”/“Anthropic”（`httpError` 增加 `name:` 参数）

### C. `AnthropicStream.swift`

```swift
init(strictStopReasons: Bool = true)
```

`incompleteness` 的 `default:` 分支：`strictStopReasons ? "fine «…» non gestita" : nil`。
其它校验一字不动（`started`、`finished`、未闭合 block、重复 tool id、`end_turn`/`stop_sequence` 带调用 仍为错）。

### D. OpenAI Chat — 新文件 `App/Sources/Integration/OpenAI/`

依赖仅限：Foundation、Observation、`AssistantProvider.swift`、`ToolBridge.swift`、`OpenAISSEDecoder`（同目录 `OpenAIStream.swift`）。
**不得** import ClaudeProvider/AppKit/UI，否则 `scripts/test-openai-provider.sh` 与电子测试会断。

#### D1. `OpenAIChatConversation.swift`

```swift
struct OpenAIChatConversation {
    var messages: [JSONValue] = []

    mutating func addUser(_ text: String)
    mutating func addAssistant(content: String, toolCalls: [OpenAIChatToolCall])   // content="" 时不写 content
    mutating func addToolResults(_ results: [(ToolCallRequest, ToolResult)])       // 每条一个 role:"tool"
    func request(model: String, system: String, tools: [ToolSpec], options: OpenAIChatRequestOptions) -> JSONValue
}

struct OpenAIChatToolCall: Sendable, Equatable { let id, name, arguments: String }
struct OpenAIChatRequestOptions: Sendable {
    let includeUsage: Bool        // stream_options.include_usage
    let thinking: Bool            // DeepSeek: {"type":"enabled"}
    let reasoningEffort: String?  // "medium" | nil
}
```

`request` 产出：

```json
{"model": …, "stream": true, "messages": [{"role":"system","content":system}, …],
 "tools": [{"type":"function","function":{"name":…,"description":…,"parameters":…}}],
 "stream_options": {"include_usage": true},   // 仅 includeUsage
 "thinking": {"type":"enabled"},              // 仅 thinking
 "reasoning_effort": "medium"}                // 仅 reasoningEffort != nil
```

`tools` 为空时省略 `tools`/`tool_choice`。

#### D2. `OpenAIChatStream.swift` — `OpenAIChatStreamAssembler`

```swift
struct OpenAIChatStreamAssembler {
    mutating func consume(_ payload: JSONValue) -> [AssistantEvent]
    var streamError: String?
    var incompleteness: String?
    var finishReason: String?
    var toolCalls: [ToolCallRequest]
    var content: String
    var usage: (input: Int, output: Int)?
}
```

规则：
- `choices[n].delta.content` → `.textDelta`
- `delta.reasoning_content`（DeepSeek）→ `.thinkingDelta`
- `delta.tool_calls[]`：按 `index` 建槽；首次见到 `id`+`function.name` → `.toolCallStarted`；此后每个
  `function.arguments` 片段 → `.toolArgumentsDelta(id:partial:)` 并拼接
- 顶层 `usage`（含 `prompt_tokens`/`completion_tokens`）→ `.usage`
- `choices[n].finish_reason` 记录（后续空 choices 的 usage 块不再覆盖）
- `error` 对象 → `streamError`
- `incompleteness`（在流结束时由 provider 检查）：
  - 无 `finishReason` → `"stream interrotto"`
  - `tool_calls` 但无有效调用 → `"tool_calls senza chiamate"`
  - `stop` 却带调用 → `"chiamate con fine «stop»"`
  - 重复 tool id → `"ID di chiamata duplicati"`
- `toolCalls` 的 `arguments` 必须是合法 JSON 且含对象，否则该调用 `arguments = nil`（沿用 `ToolCallRequest` 语义，不执行）

#### D3. `OpenAIChatProvider.swift`

```swift
struct OpenAIChatProviderConfig: Sendable, Equatable {
    enum Kind: String, Sendable { case chatGPT, deepSeek, compatible }
    let kind: Kind
    let displayName: String
    let keychainService: String
    let defaultsKey: String
    let defaultBaseURL: String
    let defaultModel: String
    let models: [ModelChoice]
    let includeUsage: Bool
    let thinking: Bool
    let reasoningEffort: String?
    let allowsCustomEndpoint: Bool

    static let chatGPT = OpenAIChatProviderConfig(
        kind: .chatGPT, displayName: "ChatGPT",
        keychainService: "com.takeoff.fusiontakeoff.openai-api-key",
        defaultsKey: "assistant.openai",
        defaultBaseURL: "https://api.openai.com/v1",
        defaultModel: "gpt-6-sol", models: [ModelChoice(id: "gpt-6-sol", name: "GPT-6 Sol")],
        includeUsage: true, thinking: false, reasoningEffort: nil, allowsCustomEndpoint: false)

    static let deepSeek = OpenAIChatProviderConfig(
        kind: .deepSeek, displayName: "DeepSeek",
        keychainService: "com.takeoff.fusiontakeoff.deepseek-api-key",
        defaultsKey: "assistant.deepseek",
        defaultBaseURL: "https://api.deepseek.com",
        defaultModel: "deepseek-flash",
        models: [ModelChoice(id: "deepseek-flash", name: "DeepSeek Flash"),
                 ModelChoice(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro")],
        includeUsage: true, thinking: true, reasoningEffort: "medium", allowsCustomEndpoint: false)

    static let compatible = OpenAIChatProviderConfig(
        kind: .compatible, displayName: String(localized: "OpenAI compatibile"),
        keychainService: "com.takeoff.fusiontakeoff.openai-compatible-api-key",
        defaultsKey: "assistant.openai-compatible",
        defaultBaseURL: "", defaultModel: "", models: [],
        includeUsage: false, thinking: false, reasoningEffort: nil, allowsCustomEndpoint: true)
}
```

Provider：
- `@MainActor @Observable final class OpenAIChatProvider: AssistantProvider`
- `init(config: OpenAIChatProviderConfig, session: URLSession = .shared)`
- `displayName`、`modelID`、`baseURL`、`models`、`modelName`、`hasKey`、`isConfigured`、`setupHint`、`setAPIKey`
  与 B 节同构（`isConfigured` 额外要求 `baseURL`/`modelID` 非空）
- 请求 URL 归一化：

```swift
let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
if trimmed.hasSuffix("/chat/completions") { return URL(string: trimmed) }
return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions")
```

- `runTurn`：读 key → 取 `conversation` 快照 → `OpenAIChatConversation.request(...)` → POST
  `Authorization: Bearer`、`Content-Type: application/json`、`timeoutInterval = 600` →
  非 200 读最多 64 KB body 并抛 `httpError`（401/403/429/5xx 文案含 `displayName`）→
  `OpenAISSEDecoder` 逐事件 `assembler.consume` → `onEvent`
- 结束：`generation` 比对（reset 中途则抛错，同 Claude 的 `conversation` 语义）；`streamError` → 抛；
  按 `finishReason` 分派：
  - `"length"` → `.truncated`（不写历史，或只写无 tool_calls 的 content）
  - `"content_filter"` → `.refused(nil)`
  - `"tool_calls"` → 写 assistant（content + toolCalls），返回 `.toolCalls(assembler.toolCalls)`
  - `"stop"` / 其它（`strictStopReasons` 类似物：Chat Completions 只有这几个已知值，未知值按 `stop` 处理但记录）
    → 写 assistant，`.done`
- `addToolResults`：每个结果一条 `role:"tool"`（`content` = `r.text` + `"\n"` + `structured.jsonString` 若有）

`setupHint` 文案（新本地化键）：
- ChatGPT：`"Per usare ChatGPT inserisci la tua API key OpenAI in Impostazioni → Assistente."`
- DeepSeek：`"Per usare DeepSeek inserisci la tua API key in Impostazioni → Assistente."`
- OpenAI 兼容：`"Per un modello compatibile OpenAI inserisci base URL, modello e API key in Impostazioni → Assistente."`
- Anthropic 兼容：`"Per un modello compatibile Anthropic inserisci base URL, modello e API key in Impostazioni → Assistente."`

### E. 注册 — `App/Sources/UI/FusionTakeoffApp.swift`

```swift
var providers: [AssistantProvider] = [
    ClaudeProvider(config: .claude),
    OpenAIChatProvider(config: .chatGPT),
    OpenAIChatProvider(config: .deepSeek),
    ClaudeProvider(config: .compatible),
    OpenAIChatProvider(config: .compatible),
]
if #available(macOS 27.0, *) { providers.append(AppleIntelligenceProvider()) }
```

`OpenAIProvider()` 不再注册（源码与测试保留）。

### F. 设置页 — `App/Sources/UI/Assistant/AssistantSettings.swift`

- `providers` 派生的局部常量：`claude`（kind `.claude`）、`chatGPT`、`deepSeek`、`anthropicCompatible`、`openAICompatible`
- 分区顺序：Claude (Anthropic) → ChatGPT (OpenAI) → DeepSeek → Anthropic compatibile → OpenAI compatibile
- 兼容分区：`TextField("Base URL", text: $provider.baseURL, prompt: …)` + `TextField("Modello", …)`
- 抽子视图：

```swift
private struct ProviderKeyRow: View {
    let hasKey: Bool
    let placeholder: String
    let linkTitle: String?
    let linkURL: URL?
    let caption: String
    let save: (String) -> Void
    let remove: () -> Void
    @State private var draft = ""
}
```

（`SecureField` + 保存/移除 + 可选 Link + caption；每个分区自己的 `@State`，互不影响）

### G. 系统提示 — `App/Sources/Integration/Assistant/AssistantSession.swift`

在「Scelte da officina」段落追加一句（不改结构）：
`"Per gli schizzi: list_sketches / get_sketch per rivedere, add_sketch per creare entità su XY/XZ/YZ o su una faccia, extrude_sketch per il profilo (anche con isole)."`

### H. 草图工具 — `App/Sources/Model/Tools/CADToolCatalog.swift`

在 `tools` 数组末尾（`export_flat_dxf` 之后、`undo` 之前）新增 4 个 `ToolSpec`。
复用现有 `tool(...)`、`object(...)`、`number`、`coordinate`、`point`、`position`、`name`、`color`、`operation`。

新增局部 JSONValue：

```swift
let sketchID: JSONValue = ["type": "string", "format": "uuid",
    "description": "Sketch ID from list_sketches; never guess."]
let shapeID: JSONValue = ["type": "string", "format": "uuid",
    "description": "Closed shape ID from get_sketch."]
let sketchPoint: JSONValue = object(["x": coordinate, "y": coordinate], required: ["x", "y"])
let sketchShape: JSONValue = ["type": "object", "additionalProperties": false, "required": ["kind"],
    "properties": [
        "kind": ["type": "string", "enum": ["line", "polyline", "rectangle", "circle", "polygon",
                                            "slot", "arc", "spline", "bezier"]],
        "points": ["type": "array", "minItems": 2, "maxItems": 256, "items": sketchPoint],
        "closed": ["type": "boolean"],
        "corner": sketchPoint, "width": number, "height": number,
        "center": sketchPoint, "radius": number,
        "sides": ["type": "integer", "minimum": 3, "maximum": 64],
        "rotation": ["type": "number", "minimum": -360, "maximum": 360],
        "circumscribed": ["type": "boolean"],
        "start": sketchPoint, "end": sketchPoint,
        "start_angle": ["type": "number", "minimum": -360, "maximum": 360],
        "end_angle": ["type": "number", "minimum": -360, "maximum": 360],
        "control1": sketchPoint, "control2": sketchPoint,
        "construction": ["type": "boolean"]
    ]]
let skPlane: JSONValue = ["type": "string", "enum": ["xy", "xz", "yz"], "description": "Sketch plane. Default xy (print bed)."]
```

工具定义：

```swift
tool("list_sketches", "Elenco schizzi",
     "List sketches with plane, visibility, entity count and closed area. Sketches are timeline steps: edits are undoable."),
tool("get_sketch", "Leggi schizzo",
     "Read one sketch: plane, every entity with its ID and parameters, and its closed regions (outline + holes) usable with extrude_sketch.",
     ["sketch_id": sketchID], required: ["sketch_id"]),
tool("add_sketch", "Crea schizzo",
     "Create a sketch or append entities to it. One undo step per call. Shapes: line/polyline/spline need points; rectangle needs corner+width+height; circle center+radius; polygon center+radius+sides (+rotation, circumscribed); slot start+end+width; arc center+radius+start_angle+end_angle; bezier start+control1+control2+end. Set construction true for reference geometry (it never forms profiles). On a face pass face_point (a point on the planar face) and face_normal (its outward normal).",
     ["sketch_id": sketchID, "name": name, "plane": skPlane,
      "face_point": position, "face_normal": position,
      "offset": ["type": "number", "minimum": -100000, "maximum": 100000],
      "shapes": ["type": "array", "minItems": 1, "maxItems": 256, "items": sketchShape],
      "replace": ["type": "boolean"],
      "visible": ["type": "boolean"]],
     required: ["shapes"], write: true),
tool("extrude_sketch", "Estrudi schizzo",
     "Extrude one closed region of a sketch. Omit shape_id only when the sketch has exactly one closed profile. Holes nested inside the profile are kept automatically. Height is along the sketch normal; reversed flips it. On XY with no offset the result starts at Z=0.",
     ["sketch_id": sketchID, "shape_id": shapeID, "height": number, "reversed": ["type": "boolean"]]
       .merging(["name": name, "color": color, "operation": operation]) { _, b in b },
     required: ["sketch_id", "height"], write: true)
```

策展注意：`add_extrude` 的 `points/height` 语义与 `extrude_sketch` 不同，工具描述里要明确「已有草图时优先 `extrude_sketch`」。

### I. 工具实现 — `App/Sources/Model/Tools/DesignModel+Tools.swift`

`call(_:)` switch 增加只读分支（放在 `case "get_feature"` 之后）：

```swift
case "list_sketches": return try listSketches()
case "get_sketch": return try getSketch(args)
```

`mutate(_:args:title:)` 在 `if name == "add_chamfer"` **之前** 增加：

```swift
if name == "add_sketch" { return try addSketch(args) }
if name == "extrude_sketch" { return try extrudeSketch(args) }
```

新增私有帮助函数（文件尾部，`points(_:)` 之后）：

```swift
// —— 草图 ——
private func listSketches() throws -> ToolResult
private func getSketch(_ args: [String: JSONValue]) throws -> ToolResult
private func addSketch(_ args: [String: JSONValue]) throws -> ToolResult
private func extrudeSketch(_ args: [String: JSONValue]) throws -> ToolResult

private func sketchIndex(_ args: [String: JSONValue]) throws -> Int
private func vec2JSON(_ p: Vec2) -> JSONValue
private func shapeJSON(_ s: SketchShape) -> JSONValue
private func sketchPlane(_ args: [String: JSONValue]) throws -> SketchPlane
private func planeJSON(_ p: SketchPlane) -> JSONValue
private func sketchShape(_ json: JSONValue) throws -> SketchShape
private func nextSketchName() -> String
private func nextExtrudeName() -> String
```

**`sketchShape(_:)` 映射**（`kind` 必填，按 kind 校验必需字段，错误信息用意大利语）：

| kind | 必需 | 可选 | 结果 |
|---|---|---|---|
| `line` | `points`（恰好 2） | `construction` | `.polyline(points, closed: false)` |
| `polyline` | `points` ≥ 2 | `closed`, `construction` | `.polyline(points, closed: closed ?? false)` |
| `spline` | `points` ≥ 2 | `closed`, `construction` | `.spline(points:closed:)` |
| `rectangle` | `corner`, `width`, `height` | `construction` | `.rectangle(corner:width:height:)`（负 w/h 归一化：取绝对值并回移 corner） |
| `circle` | `center`, `radius` | `construction` | `.circle(center:radius:)` |
| `polygon` | `center`, `radius`, `sides` | `rotation`(度→弧度), `circumscribed`, `construction` | `.polygon(...)` |
| `slot` | `start`, `end`, `width` | `construction` | `.slot(start:end:width:)` |
| `arc` | `center`, `radius`, `start_angle`, `end_angle` | `construction` | `.arc(...)`，角度→弧度 |
| `bezier` | `start`, `control1`, `control2`, `end` | `construction` | `.bezier(...)` |

数值校验：所有坐标 `try CADToolValidation.coordinate(...)`，所有尺寸 `try CADToolValidation.dimension(...)`；
`sides` 必须 3…64；`points` 超过 256 拒绝（schema 已限，但仍校验）。
**不**允许 `kind: point3D/line3D/workplane`（3D 草图工具留到以后；schema enum 已排除）。

**`sketchPlane(_:)`**：
1. `face_point`/`face_normal` 必须成对，否则 `CADToolFailure("face_point e face_normal vanno insieme.")`；
   有则 `SketchPlane.onFace(point:normal:)`（法线为零向量 → 错误）。
2. 否则 `plane` → `.xy` / `.xz` / `.yz`。
3. `offset` 非零 → `.offset(by:)`。

**`listSketches`** 返回：

```json
{"count": n, "sketches": [{"id": …, "name": …, "plane": "XY"|"XZ"|"YZ"|"custom",
  "origin": {x,y,z}, "normal": {x,y,z}, "visible": bool,
  "shape_count": n, "closed_count": n, "area": number}]}
```

**`getSketch`** 返回：

```json
{"sketch": {"id","name","plane","origin","normal","visible","area","length",
  "shapes": [{"id","kind","construction", <参数>, "closed", "area"}],
  "regions": [{"shape_id","hole_shape_ids":[…],"area","holes":[{"shape_id","area"}]}]}}
```

`shape` 的参数按 kind 输出现有字段名（`corner`,`width`,`height`,`center`,`radius`,`sides`,`rotation`,`circumscribed`,`start`,`end`,`width`,`start_angle`,`end_angle`,`points`,`closed`,`control1`,`control2`），
角度字段由弧度转回度（与输入同单位；描述里写明「gradi」）。

**`addSketch` 算法**：
1. 解析全部 shape（先全部成功再动文档，事务性）。
2. 有 `sketch_id`：找到（找不到 → 错误）；若给了 `plane`/`face_*`/`offset` 且与现有平面不等
   → `CADToolFailure("Lo schizzo esiste già su un altro piano; creane uno nuovo.")`。
3. `replace == true`：`sketch.shapes = []`，随后 `sketch.solve()` 清理悬空约束。
4. 追加新 shape；`visible` 若给出则更新。
5. 新草图：`Sketch(name: name ?? nextSketchName(), plane:, shapes:, isVisible:)`。
6. `next.upsert(sketch)`；已有草图再 `next.regenerate(from: sketch)`（更新以 shape 为 seed 的 extrude）。
7. `commitEdit(next, selected: .some(sketch.id), title: "Assistente: \(title)", changed: [])`。
8. 返回 `{"changed": true, "sketch_id", "name", "shape_ids": […], "shape_count", "revision"}`。

**`extrudeSketch` 算法**：
1. `sketch_id` → 草图（找不到 → 错误）。
2. 目标 shape：`shape_id` 给了就用（必须存在于该草图且有 `profile`，否则错误）；
   没给：`regions` 里 `outline` 非空的候选，若数量 ≠ 1 → 错误列出 `shape_id`。
3. `profile = shape.profile!`；`region = sketch.regions.first { $0.shapeID == shape.id }`；
   `holes = region?.holes.map { Profile2D(points: $0) } ?? []`。
4. `height`：`CADToolValidation.dimension`；`operation` 默认 `.newBody`。
5. `placement`：`sketch.plane.isXY && !reversed && sketch.plane.origin == .zero` 时 `nil`，
   否则 `FeaturePlacement(plane: sketch.plane, reversed: reversed)`（注意 `.xy` 但带 offset 也必须给 placement）。
6. `Feature(name: name ?? nextExtrudeName(), position: .zero, kind: .extrude(profile:height:),
   operation:, placement:, holes:)`；`feature.keyProfile(from: sketch)`；
   `try CADToolValidation.feature(feature)`。
7. `next.features.append(feature)`；`next.sketchLinks.append(SketchLink(featureID: feature.id,
   sketchID: sketch.id, shapeID: shape.id, holeShapeIDs: region?.holeShapeIDs ?? []))`。
8. `commitEdit(next, selected: .some(feature.id), title: "Assistente: \(title)", changed: [feature.id])`。
9. 返回 `{"changed": true, "feature_id", "name", "height", "hole_count", "revision"}`。

### J. 测试

**`Tests/MCPIntegration/Runner.swift`**（在电路用例之后、`print("PASS: …")` 之前）：
- 工具数由 `37` 改 `41`，说明文本 `"31 CAD + 10 circuit tools via HTTP"`。
- 草图用例（全部走真实 loopback HTTP）：

```swift
let s0 = try await call("list_sketches", [:])
expect(s0["isError"]?.bool == false && s0["structuredContent"]?["count"]?.number == 0, "no sketches initially")
let rev0 = model.designRevision
let made = try await call("add_sketch", ["plane": "xy",
    "shapes": [["kind": "rectangle", "corner": ["x": 0, "y": 0], "width": 40, "height": 30]],
    "expected_revision": .string(rev0)])
expect(made["structuredContent"]?["shape_count"]?.number == 1, "sketch created")
let sketchID = made["structuredContent"]?["sketch_id"]?.string ?? ""
let read = try await call("get_sketch", ["sketch_id": .string(sketchID)])
expect(read["structuredContent"]?["sketch"]?["shapes"]?.array?.first?["width"]?.number == 40, "rectangle read back")
expect(abs((read["structuredContent"]?["sketch"]?["area"]?.number ?? 0) - 1200) < 1e-9, "rectangle area")
// 追加圆
let added2 = try await call("add_sketch", ["sketch_id": .string(sketchID),
    "shapes": [["kind": "circle", "center": ["x": 20, "y": 15], "radius": 5]],
    "expected_revision": .string(model.designRevision)])
expect(added2["structuredContent"]?["shape_count"]?.number == 2, "circle appended")
// 多个闭合轮廓不指定 -> 错误
let ambiguous = try await call("extrude_sketch", ["sketch_id": .string(sketchID), "height": 5,
    "expected_revision": .string(model.designRevision)])
expect(ambiguous["isError"]?.bool == true, "ambiguous profile refused")
// 指定矩形 -> 体积 12000
let rectID = read["structuredContent"]?["sketch"]?["shapes"]?.array?
    .first { $0["kind"]?.string == "rectangle" }?["id"]?.string ?? ""
let extruded = try await call("extrude_sketch", ["sketch_id": .string(sketchID),
    "shape_id": .string(rectID), "height": 5, "expected_revision": .string(model.designRevision)])
expect(extruded["isError"]?.bool == false && extruded["structuredContent"]?["hole_count"]?.number == 0, "extrude from sketch")
expect(abs(model.document.buildMesh().volume - 6000 - 12000) < 1e-6, "sketch extrusion volume")
// undo/redo
let undoSketch = try await call("undo", ["expected_revision": .string(model.designRevision)])
expect(undoSketch["isError"]?.bool == false && model.document.features.count == 1, "undo extrusion")
_ = try await call("redo", ["expected_revision": .string(model.designRevision)])
// 非法 kind + 陈旧 revision
let badKind = try await call("add_sketch", ["shapes": [["kind": "hexahedron"]],
    "expected_revision": .string(model.designRevision)])
expect(badKind["isError"]?.bool == true, "unknown shape kind refused")
let staleSketch = try await call("add_sketch", ["shapes": [["kind": "circle", "center": ["x": 0, "y": 0],
    "radius": 2], "expected_revision": .string(rev0)])
expect(staleSketch["isError"]?.bool == true && model.document.sketches.count == 1, "stale sketch write refused")
```

（原有 add_box 的体积断言 6000 在草图拉伸后仍成立，因为 extrude 的 shape 与 box 不重叠；
若实现后发现基准体被 join 影响，则把体积断言改成「box 体积仍 6000 + 新特征体积 12000」分别断言。）

**`Tests/AssistantTools/Runner.swift`**：`27` → `31`，说明 `"31 unique tools"`。

**`Tests/AssistantProviders/Runner.swift`**（新）：
- 顶部定义 `enum Keychain`（stub：`read` 仅对 `com.takeoff.fusiontakeoff.deepseek-api-key` 返回
  `ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]`，其它 nil；`write` 返回 true），
  `FixtureProtocol`（与电子测试同构，仅 200 + `text/event-stream`）。
- 纯函数断言：`OpenAIChatProvider.endpoint(for:)` 与 `ClaudeProvider.endpoint(for:)` 归一化
  （`https://api.deepseek.com` → `…/chat/completions`；`…/v1` → `…/v1/chat/completions`；
  已带路径原样；Anthropic 同理 `/v1/messages`）。
- 组装器用例：完整单调用、分片参数、并行两调用、`stop`+content、`length`、`content_filter`、
  缺 `finish_reason`、`tool_calls` 空、重复 id、`reasoning_content`、usage。
- `--live` 段（仅当命令行含 `--live` 且 `DEEPSEEK_API_KEY` 存在；最多 3 个请求，`max_tokens` 16/32/64，无重试）：
  1. `OpenAIChatProvider(config: .deepSeek)` 普通文本 → 非空 `textDelta`，`.done`
  2. 同上带一个 `probe_tool` 定义，提示「Chiama probe_tool」→ 接受 `.toolCalls` 或 `.done`（只打印）
  3. `ClaudeProvider(config: .compatible)` + base `https://api.deepseek.com/anthropic` + model `deepseek-flash` → `.done`

**`scripts/test-assistant-deepseek.sh`**（新，仿 `Tests/Electronics/RemoteProviders/run.sh`）：

```bash
xcrun swiftc -swift-version 6 -parse-as-library \
  App/Sources/Integration/ToolBridge.swift \
  App/Sources/Integration/Assistant/AssistantProvider.swift \
  App/Sources/Integration/Assistant/AnthropicStream.swift \
  App/Sources/Integration/Assistant/ClaudeProvider.swift \
  App/Sources/Integration/OpenAI/*.swift \
  Tests/AssistantProviders/Runner.swift \
  -o "$qa_dir/assistant-provider-tests"
"$qa_dir/assistant-provider-tests"   # 传 --live 才联网
```

### K. 本地化 — `App/Resources/Localizable.xcstrings`

新增键（it / en / zh-Hans，`extractionState: manual`，与 T138 相同格式）：

| 键（源语言 it） | en | zh-Hans |
|---|---|---|
| `ChatGPT (OpenAI)` | 同 | 同 |
| `DeepSeek` | 同 | 同 |
| `Anthropic compatibile` | Anthropic-compatible | 兼容 Anthropic |
| `OpenAI compatibile` | OpenAI-compatible | 兼容 OpenAI |
| `Base URL` | 同 | 接口地址 |
| `Modello`（若缺） | Model | 模型 |
| `La chiave resta nel Portachiavi di macOS e viene inviata solo all'API scelta.` | The key stays in the macOS Keychain and is sent only to the chosen API. | 密钥仅保存在 macOS 钥匙串，只发送到所选 API。 |
| `Per usare ChatGPT inserisci la tua API key OpenAI in Impostazioni → Assistente.` | … | … |
| `Per usare DeepSeek inserisci la tua API key in Impostazioni → Assistente.` | … | … |
| `Per un modello compatibile OpenAI inserisci base URL, modello e API key in Impostazioni → Assistente.` | … | … |
| `Per un modello compatibile Anthropic inserisci base URL, modello e API key in Impostazioni → Assistente.` | … | … |
| `non configurato` | not configured | 未配置 |

已有键复用：`Claude (Anthropic)`、`OpenAI`、`Modello`、`API key`、`Salvata nel Portachiavi`、`Rimuovi`、`Salva`。

### L. T55 — `docs/connectors/E2E.md`（新建）

内容：
- 环境与日期、macOS 版本、构建命令。
- **实际跑过的**：DeepSeek（OpenAI 格式 + Anthropic 格式）真实调用；离线 fixture 覆盖 Claude/ChatGPT 的
  流组装与错误路径（说明为什么不是真实调用：无对应账号 key）。
- 每条：命令、输入摘要、预期、实际输出摘要（**key 只写「已设置 DEEPSEEK_API_KEY」，绝不回显**）。
- **需要 Ross 人工确认**：Claude（真实 Anthropic key）与 ChatGPT（真实 OpenAI key）在应用内各发一轮
  「读 scene_info 并加一个 10×10×2 的盒子」，确认工具卡片与撤销。
- 失败时的排查顺序（401/403/429/base URL/模型名）。

### M. 任务图与登记（流程，不是代码）

- `python3 scripts/graph.py paths T150 <新增路径> --by claude`（加入 `App/Sources/UI/FusionTakeoffApp.swift`）
- `python3 scripts/graph.py paths T149 <新增路径> --by claude`（加入 `Tests/AssistantTools`）
- 每次 paths 变更在 `docs/COLLAB.md` 追加一条 `PATHS` 说明，然后 `claim` 已在手（in_progress）。
- 完成后分别 `done T149` / `done T150` / `done T55`，`--note` 写清变更与测试结果。

## 非目标（明确不做）

- 不做 Responses API 的工具/推理迁移；`OpenAIProvider` 不动。
- 不做多轮对话持久化、不做成本统计、不做流式取消的新 UI。
- 不做 3D 草图（`point3D`/`line3D`/`workplane`）的 MCP 工具。
- 不在 spec/代码/脚本里写任何真实 key。

## 验证

1. `swift test --package-path Packages/CADCore`（应仍 266 绿；本次不改 CADCore）。
2. `scripts/test-assistant-tools.sh`（31 工具）。
3. `scripts/test-openai-provider.sh`（旧 Responses 测试仍绿，新 chat 文件可独立编译）。
4. `Tests/Electronics/RemoteProviders/run.sh`（codex 的 26 项 fixture 全绿，`ClaudeProvider()` 默认 init 不变）。
5. `scripts/test-apple-intelligence.sh`（`AssistantSession` 文案改动不破）。
6. `scripts/test-mcp-integration.sh`（41 工具 + 草图用例）。
7. `scripts/test-assistant-deepseek.sh`（离线全绿；再 `--live` 跑 3 个小请求）。
8. `scripts/test-sketch.sh`、`scripts/test-shaders.sh`（回归）。
9. `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" scripts/build.sh` → BUILD SUCCEEDED。
10. 设置页人工检查（Ross）：5 个分区、密钥保存/移除、兼容分区 base URL 与模型可编辑、重启后保留。
11. 真实凭据冒烟（T55 记录）：DeepSeek 两种协议各 1 轮 + 1 次工具调用。
