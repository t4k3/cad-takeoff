# Checklist — T112 follow-up：i18n 清理 + Pixelmator 风格主页

逐条核对（源码 / 行为 / 文档）。通过后勾选。

## 一、国际化（it / en / zh-Hans）

- [x] 窗口标题：中文界面下显示「未命名 — 已修改」而不是意大利语；`.ftk` 与 `.ftkc` 两条路径都已本地化。
- [x] `ProjectLibrary`：默认名（Senza titolo / Senza nome / « copia»）、保存确认 NSAlert（标题、正文、按钮）、`LibraryError.exists`、`chooseRoot` 面板文案均已本地化。
- [x] `CommandPanel`：标题不再 `uppercased()`（中文下显示「壳体」而不是「GUSCIO」），字段 label/help/note/options/prompt/validation 全部本地化。
- [x] `UI/Features/*`：壳体、孔、倒角、钣金、阵列、螺纹、分割、组合、移动、按下拉、关节、爆炸的 label/help/note/标题/选项均已本地化。
- [x] 草图面板：形状类型名（Profilo/Linea/Polilinea/Rettangolo/Cerchio/Poligono/Asola/Arco/Spline）按语言显示。
- [x] 状态栏与提示：`WorkspaceState`、`ViewportContainer`、`DrawingWindow`、`SketchSession*`、`Circuits`、`DesignModel` 的运行期消息都经 `String(localized:)`。
- [x] `CircuitModel.summary` 及电子板 workspace 可见文案本地化（技术层名/网络名保持原样）。
- [x] `Localizable.xcstrings`：所有 key 都有 `en` 与 `zh-Hans`，状态 `translated`；`sourceLanguage` 仍为 `it`。
- [x] 占位符一致性：`%@` / `%lld` / `%.2f` / 位置参数在源串与译文之间数量与顺序一致。
- [x] 声明为 out of scope 的残留（assistant/MCP/`CADToolCatalog` 诊断、ElectronicsCore 引擎 issue 文本）已写入 `docs/DA_PROVARE.md` 与 `docs/COLLAB.md`。

## 二、主页（Pixelmator 风格 + macOS 26 Liquid Glass）

- [x] 主页为两栏：左侧 300 pt 欢迎栏（应用图标 96×96、应用名、版本号、4 个全宽胶囊按钮、更多菜单、项目选择）。
- [x] 右侧：面包屑 + 搜索框 + 新建文件夹图标按钮 + 最近/结果网格或空状态。
- [x] 原有全部功能仍可达：新建设计、新电路、打开文件、选择文件夹、新建文件夹/项目、安装 add-in、导入 STL/3MF、重命名/复制/在 Finder 显示/移到废纸篓、返回已打开文档。
- [x] Liquid Glass 与 `Theme` 一致（深浅色均正常），最小窗口 1100×700 下不裁切。

## 三、构建与测试

- [x] `xcodebuild … build`（签名关闭）BUILD SUCCEEDED。
- [x] `swift test --package-path Packages/CADCore` 全绿（205+）。
- [x] UI 路径审计：`App/Sources/UI`、`App/Sources/Integration/Projects` 无未本地化的用户可见意大利语字面量（技术数据除外）。

## 四、文档与交付

- [x] `docs/DA_PROVARE.md` 增加中文/英文界面核对步骤与已知残留。
- [x] `docs/COLLAB.md` 追加本轮 NOTA/DONE 记录。
- [x] `tasks.md` 勾选完成项。
- [x] 提交 `[T112]`，只包含任务路径（不含未跟踪的 `docs/UI_LIQUID_GLASS_AND_I18N_SPEC.md`、`skills/`）。
