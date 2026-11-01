# CAD Takeoff 现代 macOS UI (Liquid Glass) 与多语言 i18n 重构实施规范

> **目标受众**：下游执行代理（如 DeepSeek）或开发人员。
> **目标**：
> 1. 将原有的 Windows / Fusion 360 风格紧凑暗色拼接界面与大 Ribbon 栏，重构为符合最新 macOS Human Interface Guidelines (HIG) 的 **Liquid Glass（流动磨砂玻璃 / 悬浮 HUD 岛屿）** 现代质感体系（参考 Pixelmator Pro 与 Xcode 16）；
> 2. 将全工程硬编码的意大利语（Italian）解耦，基于 Apple 最新的 **String Catalogs (`.xcstrings`)** 体系，建立完整的 **意大利语 (it)**、**英语 (en)** 与 **简体中文 (zh-Hans)** 国际化系统。

---

## 目录
1. [现状剖析与重构对照图景](#1-现状剖析与重构对照图景)
2. [UI 视觉与交互体系重构 (Liquid Glass System)](#2-ui-视觉与交互体系重构-liquid-glass-system)
   - 2.1 窗口整体拓扑架构（Window Topology）
   - 2.2 Liquid Glass 设计令牌与材质实现（SwiftUI Tokens）
   - 2.3 核心组件库设计（GlassCard, GlassCapsule, ModernToolbar）
   - 2.4 关键视图重构指南（WorkspaceView, Browser, Inspector, Toolbox）
3. [i18n 多语言架构设计 (String Catalogs)](#3-i18n-多语言架构设计-string-catalogs)
   - 3.1 为什么采用 String Catalogs (`.xcstrings`)
   - 3.2 工程配置与目录集成（XcodeGen `project.yml`）
   - 3.3 字符串解耦与代码调用规范（SwiftUI & AppKit）
   - 3.4 核心 CAD 词汇三语对照标准表（it / en / zh-Hans）
4. [执行步骤与落地指令 (DeepSeek 执行清单)](#4-执行步骤与落地指令-deepseek-执行清单)

---

## 1. 现状剖析与重构对照图景

### 1.1 现状缺陷（图 1 现状）
- **Ribbon 顶栏沉重过时**：顶部高度达 94pt 的 Ribbon 工具栏充斥着生硬的灰色色块、纵向排列的文字与小图标，这是 2010 年代 Windows Office / AutoCAD 的遗留设计，严重挤占垂直设计画布空间。
- **生硬的纯色面板拼接**：视口（Viewport）、左侧浏览器（Browser）、右侧检查器（Inspector）通过 `VStack(spacing: 0)` 和 `HStack(spacing: 0)` 紧密相扣，使用固定 Hex 颜色（`0x2A2F34` 等）和不透明 `Divider()` 区分，视觉压抑，毫无层次感与通透感。
- **与 macOS HIG 背道而驰**：未采用 macOS 的标准窗口标题栏融合（Unified Toolbar），未利用 macOS 现代系统材质（`Material`、`NSVisualEffectView`）、系统模糊、动态高光和柔和阴影。
- **语言单一与硬编码**：全界面超过 300+ 处硬编码意大利文字符串（如 `"Senza titolo"`, `"SOLIDO"`, `"Estrudi"`, `"Raccordo"`, `"Corpi"` 等），非意大利语用户无法使用。

### 1.2 目标效果（图 2 Pixelmator Pro / Xcode 风格）
- **全屏通底画布（Edge-to-Edge Canvas）**：3D Metal 视口作为整个窗口的唯一主底色，贯穿整个窗口边缘（包括标题栏下方）。
- **统一轻量标题栏（Unified Toolbar）**：移除 Ribbon，改为 macOS 标准原生 Toolbar，集成文档名、当前工作模式 SegmentedControl、视图缩放控制及核心快捷按钮。
- **悬浮液体玻璃岛屿（Floating Liquid Glass Islands / HUD Panels）**：
  - **左侧浏览器（Tree/Browser）**：浮动圆角半透明玻璃卡片（`Floating HUD`），可折叠或自动隐藏。
  - **右侧检查器（Inspector）**：浮动圆角玻璃卡片，支持 Tab 切换（参数、AI 助手、制造信息）。
  - **工具箱（Toolbox Capsule）**：吸附在右侧或顶部的精美胶囊栏（Capsule Bar），图标精美，悬浮交互灵动。
  - **时间轴与状态栏（Timeline & Status Dock）**：悬浮于视口底部的微型胶囊浮岛，不遮挡大面积零件显示。
- **自适应深色/浅色模式**：利用系统级 Vibrancy 材质，在不同壁纸和系统外观下呈现极致的通透感和高级感。

---

## 2. UI 视觉与交互体系重构 (Liquid Glass System)

### 2.1 窗口整体拓扑架构（Window Topology）

```
+------------------------------------------------------------------------------------+
| [o][o][o]  [ ◫ ▾ ]  [ === 缩放滑动条 === ]  CAD Takeoff — 轴承支架.ftk   [ 💬 ][ ⛭ ]|  <- macOS Unified Window Toolbar
+------------------------------------------------------------------------------------+
|                                                                                    |
|  +--------------------+        3D METAL VIEWPORT (EDGE-TO-EDGE)     +-----------+  |
|  | [浏览器]    [+][⋯] |                                             | [检查器]  |  |
|  |                    |                                             |           |  |
|  | v ⚙️ 原点          |                                             | ▾ 特征属性|  |
|  | v ✏️ 草图 1        |                                             | 尺寸: 40mm|  |
|  | v 🧊 实体          |                                             |           |  |
|  |    ◽ 支承基座     |                                             | ▾ AI 助手 |  |
|  |                    |                                             | [输入框]  |  |
|  |                    |                                             +-----------+  |
|  +--------------------+                                             | [工具胶囊]|  |
|   (Floating Glass)                                                  | ✏️ ⬆️ ⭕   |  |
|                                                                     | 🪚 🪞 🧮  |  |
|                                                                     +-----------+  |
|                                                                                    |
|                  +----------------------------------------+                        |
|                  | ⏪ ⏸️ ⏩ [ ■ 草图1 ]->[ ⬡ 拉伸1 ]->[ ⚪ 孔1 ]|                        |
|                  +----------------------------------------+                        |
|                     (Floating Timeline Glass Capsule)                              |
|                                                                                    |
|       [ 1 实体 · 12 三角面 · 6.00 cm³ ]                [ mm · Z↑ · ● MCP ]        |
+------------------------------------------------------------------------------------+
```

### 2.2 Liquid Glass 设计令牌与材质实现（SwiftUI Tokens）

我们需要对 `App/Sources/UI/DesignSystem/Theme.swift` 进行重构，引入 Liquid Glass 的视觉规范：

```swift
// App/Sources/UI/DesignSystem/LiquidGlassTheme.swift
import SwiftUI
import AppKit

public enum LiquidGlass {
    // MARK: - 材质规格
    public static let panelMaterial: Material = .ultraThinMaterial
    public static let barMaterial: Material = .thinMaterial
    public static let popupMaterial: Material = .regularMaterial

    // MARK: - 圆角规范 (Apple HIG 标准)
    public enum CornerRadius {
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let capsule: CGFloat = 100
    }

    // MARK: - 阴影与微光描边规范
    public struct GlassModifier: ViewModifier {
        var cornerRadius: CGFloat
        var isInteractive: Bool = false
        @Environment(\.colorScheme) private var colorScheme

        public func body(content: Content) -> some View {
            content
                .background(panelMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    // 双层微光边框：模拟厚度玻璃边缘的自然光线折射
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.white.opacity(0.20), Color.white.opacity(0.05), Color.black.opacity(0.2)]
                                    : [Color.white.opacity(0.80), Color.white.opacity(0.30), Color.black.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12),
                    radius: 14,
                    x: 0,
                    y: 7
                )
        }
    }

    // MARK: - 胶囊工具条专用高光
    public struct CapsuleModifier: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme

        public func body(content: Content) -> some View {
            content
                .background(barMaterial)
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [Color.white.opacity(0.25), Color.white.opacity(0.08)]
                                    : [Color.white.opacity(0.85), Color.white.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }
}

public extension View {
    func liquidGlassPanel(cornerRadius: CGFloat = LiquidGlass.CornerRadius.large) -> some View {
        modifier(LiquidGlass.GlassModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassCapsule() -> some View {
        modifier(LiquidGlass.CapsuleModifier())
    }
}
```

### 2.3 核心组件库设计

#### 1. 悬浮玻璃面板卡片 (`GlassPanel`)
用于左侧浏览器树、右侧检查器和设置浮层：
```swift
struct GlassPanel<Header: View, Content: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder var headerTrailing: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titleKey)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                headerTrailing
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            
            Divider().opacity(0.3)
            
            content
                .padding(12)
        }
        .liquidGlassPanel(cornerRadius: LiquidGlass.CornerRadius.large)
    }
}
```

#### 2. 工具胶囊条 (`ToolboxCapsule`)
取代原有大 Ribbon 堆叠图标：
```swift
struct ModernToolButton: View {
    let icon: String // SF Symbol 名字
    let label: LocalizedStringKey
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .frame(width: 48, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
    }
}
```

### 2.4 主工作区布局重构 (`WorkspaceView.swift`)
原实现使用平铺分块 `VStack/HStack`，重构后采用 `ZStack` 实现**视口全屏铺底 + 悬浮岛屿覆盖**：

```swift
struct WorkspaceView: View {
    @Environment(DesignModel.self) private var model
    @Environment(WorkspaceState.self) private var workspace
    @State private var viewport = ViewportState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. 底层：全屏 Metal 3D 渲染视口 (Edge-to-Edge)
            ViewportContainer(viewport: viewport)
                .ignoresSafeArea()

            // 2. 覆盖层：悬浮玻璃岛屿群
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 14) {
                    // 左侧悬浮浏览器面板
                    if workspace.showBrowser {
                        BrowserPanel()
                            .frame(width: 250)
                            .frame(maxHeight: proxy.size.height - 100)
                            .liquidGlassPanel()
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    Spacer()

                    // 右侧悬浮工具与检查器面板
                    VStack(alignment: .trailing, spacing: 12) {
                        if workspace.showInspector {
                            SidePanel()
                                .frame(width: 290)
                                .frame(maxHeight: proxy.size.height - 160)
                                .liquidGlassPanel()
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // 3. 底部悬浮时间轴与状态指示胶囊
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    TimelineCapsuleBar()
                        .liquidGlassCapsule()
                }
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: workspace.showBrowser)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: workspace.showInspector)
    }
}
```

---

## 3. i18n 多语言架构设计 (String Catalogs)

### 3.1 为什么采用 String Catalogs (`.xcstrings`)
苹果自 Xcode 15 起引入 **String Catalogs (`Localizable.xcstrings`)**，取代老旧且易出错的 `.strings` / `.stringsdict`。
- **单一真理来源**：一个 `.xcstrings` 文件以格式化 JSON 管理所有目标语言（`it`, `en`, `zh-Hans` 等）；
- **编译期自动提取**：Swift 编译器扫描代码中的 `Text("key")`、`LocalizedStringKey`、`String(localized: ...)` 并自动补全 key；
- **状态追踪**：Xcode 会直接标记每条翻译状态（`new`、`translated`、`stale`、`needs_review`）；
- **内建复数与变格**：告别晦涩的 XML plist 语法，JSON 结构直接定义 zero/one/other 复数逻辑。

### 3.2 工程配置与目录集成（XcodeGen `project.yml`）

在 `project.yml` 中确保资源包含并声明支持的多语言：
```yaml
targets:
  FusionTakeoff:
    type: application
    platform: macOS
    sources:
      - App/Sources
      - App/Resources
    settings:
      base:
        KNOWN_REGIONS:
          - en
          - it
          - zh-Hans
        DEVELOPMENT_LANGUAGE: en # 开发基准语言设为 en
```
资源文件存放路径：`App/Resources/Localizable.xcstrings`。

### 3.3 字符串解耦与代码调用规范

#### 1. 统一 Key 命名规范
采用小写点分语义命名法：`<模块>.<子域>.<属性/动作>`。
- 工具栏操作：`action.extrude.title`, `action.extrude.tooltip`
- 面板标题：`panel.browser.title`, `panel.parameters.title`
- 实体与特征名称：`feature.cylinder.default_name`, `feature.fillet.radius`
- 对话框与通用操作：`common.cancel`, `common.confirm`, `common.delete`

#### 2. SwiftUI 调用方式
```swift
// 推荐：直接传递语义 Key，SwiftUI 会自动调用 LocalizedStringKey
Text("action.extrude.title")

// 带有上下文注释（注释会被提取到 String Catalog 的 comment 字段中）
Text("action.extrude.title", comment: "Label for the 3D extrusion feature button")

// 带动态参数的字符串（插值）
Text("status.body_summary \(bodyCount) \(triangleCount) \(volume)")
```

#### 3. 非 View 逻辑与 ViewModel 中调用
使用 Swift Foundation 原生 `String(localized:)`：
```swift
let message = String(localized: "error.sketch.unclosed_profile", comment: "Error shown when extrusion profile is not closed")
```

#### 4. 枚举类型的本地化模式
所有工具类型、材料种类、特征类型的枚举统一实现 `CustomStringConvertible` 或本地化计算属性：
```swift
public enum SolidToolKind: String, CaseIterable {
    case box, cylinder, extrude, revolve, hole, fillet, chamfer

    public var localizedTitle: LocalizedStringKey {
        switch self {
        case .box: return "tool.solid.box"
        case .cylinder: return "tool.solid.cylinder"
        case .extrude: return "tool.solid.extrude"
        case .revolve: return "tool.solid.revolve"
        case .hole: return "tool.solid.hole"
        case .fillet: return "tool.solid.fillet"
        case .chamfer: return "tool.solid.chamfer"
        }
    }
}
```

---

### 3.4 核心 CAD 词汇三语对照标准表（it / en / zh-Hans）

执行代理（DeepSeek）在提取和填充 `Localizable.xcstrings` 时，**必须严格遵循以下术语对照标准**：

#### 1. 全局与主菜单 (Global & Workspace)
| 语义 Key | 意大利语 (it - 原代码) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `app.name` | CAD Takeoff | CAD Takeoff | CAD Takeoff |
| `workspace.untitled` | Senza titolo | Untitled | 未命名 |
| `workspace.tab.solid` | SOLIDO | SOLID | 实体 |
| `workspace.tab.sheet_metal`| LAMIERA | SHEET METAL | 钣金 |
| `workspace.tab.assembly` | ASSIEME | ASSEMBLY | 装配 |
| `workspace.tab.drawings` | TAVOLA / STAMPA | DRAWINGS | 工程图 |
| `workspace.tab.circuits` | CIRCUITI | CIRCUITS | 电路集成 |
| `panel.browser` | BROWSER | Browser | 浏览树 |
| `panel.parameters` | Parametri | Parameters | 参数 |
| `panel.assistant` | Assistente | Assistant | AI 助手 |
| `status.ready` | Pronto | Ready | 就绪 |

#### 2. 草图图元与约束 (Sketch Entities & Constraints)
| 语义 Key | 意大利语 (it) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `sketch.tool.line` | Linea | Line | 直线 |
| `sketch.tool.rect` | Rettangolo | Rectangle | 矩形 |
| `sketch.tool.circle` | Cerchio | Circle | 圆 |
| `sketch.tool.arc` | Arco | Arc | 圆弧 |
| `sketch.tool.polygon` | Poligono | Polygon | 多边形 |
| `sketch.tool.slot` | Asola | Slot | 长圆孔 |
| `sketch.tool.spline` | Spline | Spline | 样条曲线 |
| `sketch.tool.trim` | Taglia | Trim | 修剪 |
| `sketch.tool.extend` | Estendi | Extend | 延伸 |
| `sketch.tool.offset` | Offset | Offset | 偏移 |
| `sketch.tool.dimension` | Quota | Dimension | 标注/尺寸 |
| `constraint.coincident` | Coincidente | Coincident | 重合 |
| `constraint.horizontal` | Orizzontale | Horizontal | 水平 |
| `constraint.vertical` | Verticale | Vertical | 垂直 |
| `constraint.parallel` | Parallelo | Parallel | 平行 |
| `constraint.perpendicular` | Perpendicolare | Perpendicular | 垂直相交 |
| `constraint.tangent` | Tangente | Tangent | 相切 |
| `constraint.concentric` | Concentrico | Concentric | 同心 |
| `constraint.symmetric` | Simmetrico | Symmetric | 对称 |
| `constraint.equal` | Uguale | Equal | 相等 |
| `constraint.fixed` | Fisso | Fixed | 固定 |

#### 3. 3D 实体特征建模 (Solid Modeling Operations)
| 语义 Key | 意大利语 (it) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `feature.extrude` | Estrudi | Extrude | 拉伸 |
| `feature.revolve` | Rivoluzione | Revolve | 旋转 |
| `feature.hole` | Foro | Hole | 孔 |
| `feature.hole.counterbore` | Lamato | Counterbore | 沉头孔 |
| `feature.hole.countersink` | Svasato | Countersink | 埋头孔 |
| `feature.fillet` | Raccordo | Fillet | 圆角 |
| `feature.chamfer` | Smusso | Chamfer | 倒角 |
| `feature.shell` | Guscio | Shell | 抽壳 |
| `feature.thread` | Filetto | Thread | 螺纹 |
| `feature.pattern.rect` | Serie rettangolare | Rectangular Pattern | 矩形阵列 |
| `feature.pattern.circular`| Serie circolare | Circular Pattern | 环形阵列 |
| `feature.mirror` | Specchio | Mirror | 镜像 |
| `feature.split` | Dividi | Split | 分割 |
| `feature.combine` | Combina | Combine | 组合/布尔运算 |
| `feature.press_pull` | Premi/Tira | Press/Pull | 按压/拉动 |
| `boolean.join` | Unisci | Join / Union | 求并 |
| `boolean.cut` | Taglia | Cut / Subtract | 求差 (剪切) |
| `boolean.intersect` | Interseca | Intersect | 求交 |

#### 4. 钣金与生产制造 (Sheet Metal & Manufacture)
| 语义 Key | 意大利语 (it) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `sheet_metal.flange` | Flangia | Flange | 翻边/凸缘 |
| `sheet_metal.flat_pattern`| Sviluppo | Flat Pattern | 展开平铺 |
| `sheet_metal.k_factor` | Fattore K | K-Factor | K 因子 |
| `sheet_metal.bend_radius` | Raggio di piega | Bend Radius | 折弯半径 |
| `sheet_metal.relief` | Scarico | Relief | 释压槽 |
| `sheet_metal.hem` | Orlo | Hem | 卷边 |
| `sheet_metal.export_dxf` | Esporta DXF | Export DXF | 导出 DXF |

#### 5. 装配与机构 (Assembly & Joints)
| 语义 Key | 意大利语 (it) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `assembly.insert_part` | Inserisci pezzo | Insert Component | 插入零部件 |
| `assembly.joint` | Giunto | Joint | 关节/约束 |
| `assembly.joint.rigid` | Rigido | Rigid | 刚性关节 |
| `assembly.joint.revolute` | Rotazione | Revolute | 旋转关节 |
| `assembly.joint.slider` | Scorrimento | Slider | 滑动关节 |
| `assembly.joint.cylindrical`| Cilindrico | Cylindrical | 圆柱关节 |
| `assembly.interference` | Interferenze | Interference Check | 干涉碰撞检查 |
| `assembly.bom` | Distinta base (BOM) | Bill of Materials (BOM) | 物料清单 (BOM) |
| `assembly.exploded_view` | Vista esplosa | Exploded View | 爆炸视图 |

#### 6. AI 助手与提示文案 (AI Assistant)
| 语义 Key | 意大利语 (it) | 英语 (en) | 简体中文 (zh-Hans) |
| :--- | :--- | :--- | :--- |
| `assistant.title` | Assistente di progettazione | Design Assistant | AI 设计助手 |
| `assistant.subtitle` | Descrivi il pezzo a parole... | Describe the part in words... | 用自然语言描述零件，AI 将直接建模... |
| `assistant.input_placeholder`| Chiedi all'assistente... | Ask the assistant... | 向 AI 助手提问或描述操作... |
| `assistant.settings` | Apri Impostazioni | Open Settings | 打开设置 |
| `assistant.mcp_connected` | MCP collegato | MCP Connected | MCP 服务已连接 |

---

## 4. 执行步骤与落地指令 (DeepSeek 执行清单)

请 DeepSeek 按照以下 6 个 Phase 逐步推进，保持每个 Phase 可独立编译运行通过：

### Phase 1: 建立 String Catalog 资源底座
1. 在 `App/Resources/` 目录下创建 `Localizable.xcstrings` 骨架文件（JSON 格式），声明源语言 `en` 并设置目标语言 `["en", "it", "zh-Hans"]`。
2. 更新 `project.yml` 中的语言区域 `KNOWN_REGIONS`，运行 `xcodegen generate` 确保工程正确加载该 Catalog。
3. 将上述【3.4 核心 CAD 词汇三语对照标准表】的内容完整填入 `Localizable.xcstrings`。

### Phase 2: 全局 Liquid Glass 视觉材质重写
1. 在 `App/Sources/UI/DesignSystem/` 中新增 `LiquidGlassTheme.swift`，包含 `LiquidGlass` 命名空间、材质修饰器（`GlassModifier`、`CapsuleModifier`）与动态自适应颜色。
2. 重构 `Theme.swift`：
   - 弃用生硬的固定调色板 `0x2A2F34`、`0x1E2226`；
   - 将 `Theme.Palette.canvas` 改为自适应视口底色，各 Panel 改用系统 `Material`。
   - 保留原有几何体渲染的颜色向量（`SIMD3<Float>`）。

### Phase 3: 主工作区 WorkspaceView 拓扑改造
1. 打开 `App/Sources/UI/Workspace/WorkspaceView.swift`：
   - 将原有的 `VStack { DesignTabs(); Ribbon(); HStack { ... } }` 布局改为 `ZStack`。
   - 使 `ViewportContainer` 铺满整个安全区域。
   - 将 `BrowserPanel`（左侧）与 `SidePanel`（右侧）改造成悬浮的 `GlassPanel`，添加平滑的 `.spring()` 弹出与收起动画。
   - 将底部 `TimelineBar` 与 `StatusBar` 提炼为悬浮胶囊组件。

### Phase 4: 弃用旧 Ribbon，引入 Modern Toolbar & Tool Capsules
1. 废弃或重构 `App/Sources/UI/Workspace/Ribbon.swift`：
   - 移除笨重的多行分组卡片与大文字图标。
   - 实现符合 macOS HIG 的顶栏快速模式切换（实体 / 钣金 / 装配 / 图纸 / 电路）。
   - 将常用特征命令（拉伸、旋转、打孔、圆角、倒角等）提取为一个紧凑型工具胶囊栏 `ToolboxCapsule`，悬浮于视口右上角或停靠于侧边。

### Phase 5: 全量扫描解耦硬编码字符串
1. 搜索 `App/Sources/UI/` 下的所有 `.swift` 文件：
   - 将所有界面的硬编码意大利文字符串替换为标准的 `LocalizedStringKey` 或 `String(localized:)`。
   - 重点文件：
     - `App/Sources/UI/Workspace/BrowserPanel.swift`
     - `App/Sources/UI/Workspace/InspectorPanel.swift`
     - `App/Sources/UI/Workspace/TimelineBar.swift`
     - `App/Sources/UI/Workspace/StatusBar.swift`
     - `App/Sources/UI/Assistant/AssistantPanel.swift`
     - `App/Sources/UI/Features/*.swift`
     - `App/Sources/UI/Sketch/*.swift`
2. 同步向 `Localizable.xcstrings` 中补全所有新提取的 key，并按字典准确填入三种语言的对应翻译。

### Phase 6: 验收与回归验证
1. 运行 `swift test --package-path Packages/CADCore`，确保底层几何内核不受 UI 与本地化变更的影响。
2. 运行 `scripts/build.sh` 编译 app，并在 macOS 系统设置中切换系统语言（分别测试 简体中文、English、Italiano），验证：
   - 界面文字正确匹配系统语言；
   - 浅色模式（Light Mode）与深色模式（Dark Mode）下，毛玻璃质感、微光边框与文字对比度均符合苹果 HIG 规范；
   - 3D Viewport 与悬浮面板交互流畅无卡顿，无遮挡。
