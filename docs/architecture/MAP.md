# Mappa architetturale esplorativa

Generata dal dataset `graph.json`. Metodo manuale/testuale; nessun arco RESOLVED.

```mermaid
flowchart LR
  app["FusionTakeoffApp"]
  content["WorkspaceView"]
  inspector["InspectorPanel"]
  viewport["MetalViewport"]
  model["DesignModel"]
  document["CADCore.CADDocument"]
  feature["CADCore.Feature"]
  kind["Feature.Kind"]
  profile["Profile2D"]
  primitives["Primitives"]
  operations["Operations"]
  mesh["Mesh"]
  vec3["Vec3"]
  vec2["Vec2"]
  stl["STLExporter"]
  validator["MeshValidator"]
  filesystem["File system · .ftk / .stl / .3mf"]
  metal["Metal / GPU"]
  swiftui["SwiftUI lifecycle"]
  representable["NSViewRepresentable"]
  codable["Codable"]
  chat["AssistantSession"]
  chatui["AssistantPanel"]
  claude["ClaudeProvider"]
  assistantprotocol["AssistantProvider"]
  openai["OpenAIProvider"]
  openaihistory["OpenAIConversation"]
  openaistream["OpenAIStreamAssembler"]
  chatgpt["ChatGPTConnector"]
  toolprotocol["CADToolProvider"]
  toolmodel["DesignModel + tools"]
  toolcatalog["CADToolCatalog"]
  toolvalidation["CADToolValidation"]
  mcphost["MCPHost"]
  mcpserver["MCPServer"]
  http["LocalHTTPTransport"]
  renderer["ViewportRenderer"]
  bridge["ftk-mcp stdio bridge"]
  openaiapi["OpenAI Responses API"]
  anthropicapi["Anthropic Messages API"]
  tunnel["Secure MCP Tunnel"]
  partcolor["PartColor"]
  threeMFpart["ThreeMFPart"]
  threeMF["ThreeMFExporter"]
  threeMFprofile["ThreeMFExportProfile"]
  zip["StoredZIP"]
  kernel["PrimitiveKernel"]
  brepbody["BRepBody"]
  brepvertex["BRepVertex"]
  brepedge["BRepEdge"]
  brepface["BRepFace"]
  brephalfedge["BRepHalfEdge"]
  faceid["FaceID"]
  edgeid["EdgeID"]
  vertexid["VertexID"]
  surface["SurfaceDescriptor"]
  bodysnapshot["BodySnapshot"]
  faceinfo["FaceInfo"]
  edgeinfo["EdgeInfo"]
  designsnapshot["DesignSnapshot"]
  projectlibrary["ProjectLibrary"]
  workspacestate["WorkspaceState"]
  viewportstate["ViewportState"]
  app -->|"owns_observable_state · SYNTACTIC"| model
  model -->|"owns_state · SYNTACTIC"| document
  model -->|"constructs_type · SYNTACTIC"| feature
  model -->|"calls_direct · SYNTACTIC"| document
  model -->|"calls_direct · SYNTACTIC"| stl
  model -->|"calls_direct · SYNTACTIC"| validator
  model -->|"persists_model · RUNTIME/EXTERNAL"| filesystem
  model -->|"loads_resource · RUNTIME/EXTERNAL"| filesystem
  model -->|"writes_export · RUNTIME/EXTERNAL"| filesystem
  document -->|"references_symbol · SYNTACTIC"| feature
  feature -->|"owns_state · SYNTACTIC"| kind
  feature -->|"calls_direct · SYNTACTIC"| primitives
  feature -->|"calls_direct · SYNTACTIC"| operations
  feature -->|"calls_direct · SYNTACTIC"| mesh
  document -->|"calls_direct · SYNTACTIC"| mesh
  primitives -->|"calls_direct · SYNTACTIC"| operations
  primitives -->|"references_symbol · INFERRED"| profile
  operations -->|"calls_direct · SYNTACTIC"| profile
  operations -->|"constructs_type · SYNTACTIC"| mesh
  mesh -->|"references_symbol · SYNTACTIC"| vec3
  profile -->|"references_symbol · SYNTACTIC"| vec2
  stl -->|"calls_direct · SYNTACTIC"| mesh
  validator -->|"reads_state · SYNTACTIC"| mesh
  document -->|"type_conforms_protocol · SYNTACTIC"| codable
  profile -->|"type_conforms_protocol · SYNTACTIC"| codable
  feature -->|"type_conforms_protocol · SYNTACTIC"| codable
  app -->|"constructs_type · SYNTACTIC"| content
  app -->|"owns_state · SYNTACTIC"| chat
  app -->|"owns_state · SYNTACTIC"| mcphost
  app -->|"casts_protocol · SYNTACTIC"| toolprotocol
  content -->|"constructs_type · SYNTACTIC"| chatui
  inspector -->|"binds_state · SYNTACTIC"| model
  chatui -->|"observes_state · SYNTACTIC"| chat
  chat -->|"protocol_dispatch · INFERRED"| assistantprotocol
  chat -->|"protocol_dispatch · INFERRED"| toolprotocol
  claude -->|"type_conforms_protocol · SYNTACTIC"| assistantprotocol
  openai -->|"type_conforms_protocol · SYNTACTIC"| assistantprotocol
  openai -->|"owns_state · SYNTACTIC"| openaihistory
  openai -->|"constructs_type · SYNTACTIC"| openaistream
  openai -->|"http_request · RUNTIME/EXTERNAL"| openaiapi
  claude -->|"http_request · RUNTIME/EXTERNAL"| anthropicapi
  chatgpt -->|"prepares_setup_command · INFERRED"| tunnel
  mcphost -->|"constructs_type · SYNTACTIC"| mcpserver
  mcphost -->|"constructs_type · SYNTACTIC"| http
  mcpserver -->|"protocol_dispatch · INFERRED"| toolprotocol
  bridge -->|"loopback_http_request · RUNTIME/EXTERNAL"| http
  toolmodel -->|"extension_adds_conformance · SYNTACTIC"| toolprotocol
  toolmodel -->|"extends_type · SYNTACTIC"| model
  toolmodel -->|"reads_catalog · SYNTACTIC"| toolcatalog
  toolmodel -->|"calls_direct · SYNTACTIC"| toolvalidation
  toolmodel -->|"calls_direct · SYNTACTIC"| stl
  viewport -->|"constructs_type · SYNTACTIC"| renderer
  viewport -->|"assigns_delegate · RUNTIME/EXTERNAL"| renderer
  renderer -->|"calls_direct · SYNTACTIC"| feature
  renderer -->|"runtime_gpu_boundary · RUNTIME/EXTERNAL"| metal
  swiftui -->|"runtime_callback · RUNTIME/EXTERNAL"| viewport
  viewport -->|"type_conforms_protocol · SYNTACTIC"| representable
  feature -->|"references_symbol · SYNTACTIC"| partcolor
  model -->|"calls_direct · SYNTACTIC"| threeMF
  model -->|"constructs_type · SYNTACTIC"| threeMFpart
  threeMFpart -->|"references_symbol · SYNTACTIC"| mesh
  threeMFpart -->|"references_symbol · SYNTACTIC"| partcolor
  threeMF -->|"calls_direct · SYNTACTIC"| zip
  threeMF -->|"references_symbol · SYNTACTIC"| threeMFprofile
  toolmodel -->|"calls_direct · SYNTACTIC"| model
  model -->|"persists_model · RUNTIME/EXTERNAL"| filesystem
  model -->|"calls_direct · SYNTACTIC"| kernel
  model -->|"constructs_type · SYNTACTIC"| designsnapshot
  designsnapshot -->|"references_symbol · SYNTACTIC"| bodysnapshot
  kernel -->|"constructs_type · SYNTACTIC"| brepbody
  kernel -->|"constructs_type · SYNTACTIC"| profile
  brepbody -->|"references_symbol · SYNTACTIC"| brepface
  brepbody -->|"references_symbol · SYNTACTIC"| brepedge
  brepbody -->|"references_symbol · SYNTACTIC"| brepvertex
  brepbody -->|"references_symbol · SYNTACTIC"| brephalfedge
  brepbody -->|"constructs_type · SYNTACTIC"| mesh
  brepbody -->|"constructs_type · SYNTACTIC"| bodysnapshot
  brepface -->|"references_symbol · SYNTACTIC"| surface
  bodysnapshot -->|"references_symbol · SYNTACTIC"| faceinfo
  bodysnapshot -->|"references_symbol · SYNTACTIC"| edgeinfo
  faceinfo -->|"references_symbol · SYNTACTIC"| faceid
  edgeinfo -->|"references_symbol · SYNTACTIC"| edgeid
  brepvertex -->|"references_symbol · SYNTACTIC"| vertexid
  content -->|"reads_state · SYNTACTIC"| projectlibrary
  content -->|"constructs_type · SYNTACTIC"| workspacestate
  content -->|"constructs_type · SYNTACTIC"| viewportstate
```

## Evidenze

| Arco | Relazione | Stato | File e riga |
|---|---|---|---|
| app → model | owns_observable_state | SYNTACTIC | `App/Sources/UI/FusionTakeoffApp.swift:5` |
| model → document | owns_state | SYNTACTIC | `App/Sources/Model/DesignModel.swift:21` |
| model → feature | constructs_type | SYNTACTIC | `App/Sources/Model/DesignModel.swift:66` |
| model → document | calls_direct | SYNTACTIC | `App/Sources/Model/DesignModel.swift:142` |
| model → stl | calls_direct | SYNTACTIC | `App/Sources/Model/DesignModel.swift:149` |
| model → validator | calls_direct | SYNTACTIC | `App/Sources/Model/DesignModel.swift:150` |
| model → filesystem | persists_model | RUNTIME/EXTERNAL | `App/Sources/Model/DesignModel.swift:124` |
| model → filesystem | loads_resource | RUNTIME/EXTERNAL | `App/Sources/Model/DesignModel.swift:134` |
| model → filesystem | writes_export | RUNTIME/EXTERNAL | `App/Sources/Model/DesignModel.swift:149` |
| document → feature | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:52` |
| feature → kind | owns_state | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:13` |
| feature → primitives | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:39` |
| feature → operations | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:41` |
| feature → mesh | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:43` |
| document → mesh | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:58` |
| primitives → operations | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Operations.swift:28` |
| primitives → profile | references_symbol | INFERRED | `Packages/CADCore/Sources/CADCore/Operations.swift:32` |
| operations → profile | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Operations.swift:12` |
| operations → mesh | constructs_type | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Operations.swift:9` |
| mesh → vec3 | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Mesh.swift:6` |
| profile → vec2 | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Sketch.swift:5` |
| stl → mesh | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Export.swift:13` |
| validator → mesh | reads_state | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Export.swift:77` |
| document → codable | type_conforms_protocol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:48` |
| profile → codable | type_conforms_protocol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Sketch.swift:4` |
| feature → codable | type_conforms_protocol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:4` |
| app → content | constructs_type | SYNTACTIC | `App/Sources/UI/FusionTakeoffApp.swift:12` |
| app → chat | owns_state | SYNTACTIC | `App/Sources/UI/FusionTakeoffApp.swift:8` |
| app → mcphost | owns_state | SYNTACTIC | `App/Sources/UI/FusionTakeoffApp.swift:6` |
| app → toolprotocol | casts_protocol | SYNTACTIC | `App/Sources/UI/FusionTakeoffApp.swift:21` |
| content → chatui | constructs_type | SYNTACTIC | `App/Sources/UI/Workspace/WorkspaceView.swift:67` |
| inspector → model | binds_state | SYNTACTIC | `App/Sources/UI/Workspace/InspectorPanel.swift:21` |
| chatui → chat | observes_state | SYNTACTIC | `App/Sources/UI/Assistant/AssistantPanel.swift:6` |
| chat → assistantprotocol | protocol_dispatch | INFERRED | `App/Sources/Integration/Assistant/AssistantSession.swift:99` |
| chat → toolprotocol | protocol_dispatch | INFERRED | `App/Sources/Integration/Assistant/AssistantSession.swift:174` |
| claude → assistantprotocol | type_conforms_protocol | SYNTACTIC | `App/Sources/Integration/Assistant/ClaudeProvider.swift:9` |
| openai → assistantprotocol | type_conforms_protocol | SYNTACTIC | `App/Sources/Integration/OpenAI/OpenAIProvider.swift:7` |
| openai → openaihistory | owns_state | SYNTACTIC | `App/Sources/Integration/OpenAI/OpenAIProvider.swift:19` |
| openai → openaistream | constructs_type | SYNTACTIC | `App/Sources/Integration/OpenAI/OpenAIProvider.swift:67` |
| openai → openaiapi | http_request | RUNTIME/EXTERNAL | `App/Sources/Integration/OpenAI/OpenAIProvider.swift:47` |
| claude → anthropicapi | http_request | RUNTIME/EXTERNAL | `App/Sources/Integration/Assistant/ClaudeProvider.swift:72` |
| chatgpt → tunnel | prepares_setup_command | INFERRED | `App/Sources/Integration/ChatGPT/ChatGPTConnector.swift:18` |
| mcphost → mcpserver | constructs_type | SYNTACTIC | `App/Sources/Integration/MCP/MCPHost.swift:28` |
| mcphost → http | constructs_type | SYNTACTIC | `App/Sources/Integration/MCP/MCPHost.swift:60` |
| mcpserver → toolprotocol | protocol_dispatch | INFERRED | `App/Sources/Integration/MCP/MCPServer.swift:82` |
| bridge → http | loopback_http_request | RUNTIME/EXTERNAL | `Tools/ftk-mcp/main.swift:80` |
| toolmodel → toolprotocol | extension_adds_conformance | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:17` |
| toolmodel → model | extends_type | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:17` |
| toolmodel → toolcatalog | reads_catalog | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:18` |
| toolmodel → toolvalidation | calls_direct | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:69` |
| toolmodel → stl | calls_direct | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:152` |
| viewport → renderer | constructs_type | SYNTACTIC | `App/Sources/UI/Viewport/MetalViewport.swift:33` |
| viewport → renderer | assigns_delegate | RUNTIME/EXTERNAL | `App/Sources/UI/Viewport/MetalViewport.swift:35` |
| renderer → feature | calls_direct | SYNTACTIC | `App/Sources/UI/Viewport/ViewportRenderer.swift:140` |
| renderer → metal | runtime_gpu_boundary | RUNTIME/EXTERNAL | `App/Sources/UI/Viewport/ViewportRenderer.swift:8` |
| swiftui → viewport | runtime_callback | RUNTIME/EXTERNAL | `App/Sources/UI/Viewport/MetalViewport.swift:41` |
| viewport → representable | type_conforms_protocol | SYNTACTIC | `App/Sources/UI/Viewport/MetalViewport.swift:7` |
| feature → partcolor | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Document.swift:16` |
| model → threeMF | calls_direct | SYNTACTIC | `App/Sources/Model/DesignModel.swift:169` |
| model → threeMFpart | constructs_type | SYNTACTIC | `App/Sources/Model/DesignModel.swift:167` |
| threeMFpart → mesh | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/ThreeMFExporter.swift:7` |
| threeMFpart → partcolor | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/ThreeMFExporter.swift:8` |
| threeMF → zip | calls_direct | SYNTACTIC | `Packages/CADCore/Sources/CADCore/ThreeMFExporter.swift:101` |
| threeMF → threeMFprofile | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/ThreeMFExporter.swift:30` |
| toolmodel → model | calls_direct | SYNTACTIC | `App/Sources/Model/Tools/DesignModel+Tools.swift:172` |
| model → filesystem | persists_model | RUNTIME/EXTERNAL | `App/Sources/Model/DesignModel.swift:179` |
| model → kernel | calls_direct | SYNTACTIC | `App/Sources/Model/DesignModel.swift:54` |
| model → designsnapshot | constructs_type | SYNTACTIC | `App/Sources/Model/DesignModel.swift:59` |
| designsnapshot → bodysnapshot | references_symbol | SYNTACTIC | `App/Sources/Model/DesignModel.swift:13` |
| kernel → brepbody | constructs_type | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/PrimitiveKernel.swift:122` |
| kernel → profile | constructs_type | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/PrimitiveKernel.swift:40` |
| brepbody → brepface | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:80` |
| brepbody → brepedge | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:78` |
| brepbody → brepvertex | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:77` |
| brepbody → brephalfedge | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:79` |
| brepbody → mesh | constructs_type | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:86` |
| brepbody → bodysnapshot | constructs_type | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/BodySnapshot.swift:101` |
| brepface → surface | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:70` |
| bodysnapshot → faceinfo | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/BodySnapshot.swift:37` |
| bodysnapshot → edgeinfo | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/BodySnapshot.swift:38` |
| faceinfo → faceid | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/BodySnapshot.swift:4` |
| edgeinfo → edgeid | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/BodySnapshot.swift:12` |
| brepvertex → vertexid | references_symbol | SYNTACTIC | `Packages/CADCore/Sources/CADCore/Kernel/Topology.swift:40` |
| content → projectlibrary | reads_state | SYNTACTIC | `App/Sources/UI/Workspace/WorkspaceView.swift:8` |
| content → workspacestate | constructs_type | SYNTACTIC | `App/Sources/UI/Workspace/WorkspaceView.swift:9` |
| content → viewportstate | constructs_type | SYNTACTIC | `App/Sources/UI/Workspace/WorkspaceView.swift:10` |
