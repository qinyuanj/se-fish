# SE 界面设计规范

通用 EUI API、坐标系、预设 ID、蛋仔默认金蓝配色、弹窗按钮选型与节点 `Name` 规范以 `.dsh/skills/eggy-se-lua-coding/references/features/eggy-se-lua-coding-eui/` 为准。本文件只规定本仓独有的设计收紧、架构覆盖与验收判据。

## 版式与层级

- 用单层扁平布局、对齐与留白建立层级，只保留玩家操作或读取所需的标签与数值；去掉嵌套框、多余分割线、标语、副标题与解释性文案。
- 所有尺寸、字号与间距取 `4` 的整数倍（将技能中的最小内边距 `30` 收紧为 `32`），留白宁可留空也不塞满。
- 自定义 HUD 避让 `client/main_hud_layout.lua` 中 `ENGINE_RESERVED` 标定的引擎预置控件区，并保持屏幕中央主视野无遮挡。

## 字形与克制装饰

- 字体只选内置圆体：标题用 `Enums.TextFontType.YUANTI_BOLD`，正文与次级信息用 `Enums.TextFontType.YUANTI_REGULAR`。
- `EUITextLabel` 保持无阴影、无多余描边；仅当文字直接叠在复杂 3D 场景或亮色按钮底图时，才开启轻量描边保证可读性。

## 交互与宿主收口

- 次要操作按钮按游戏态上下文显隐：平时隐藏，仅在玩家进入交互范围、选中目标或切换到对应状态时显示。
- 次级展开项（如装备候选行、下拉选项）用点击切换，支持点击空白处或关闭按钮收起。
- 视图挂载、显隐与清理统一走 `client/views/root_view.lua`（`Phase` 控显隐、`store.active_modal` 保证单弹窗互斥、`ctx.create_node` 与 `ctx.connect` 作用域对称释放），覆盖技能文档默认的独立 `Init()` 模块写法。
- 纯展示文本与装饰图片显式设置 `TouchEnabled = false` 与 `SwallowTouchEnabled = false`，避免抢占摇杆与按钮触控。
- 面板开关与位置过渡时长控制在 `0.15` 到 `0.25` 秒，并设置 `override = true` 防止连点冲突。

## 实机验收

- 每次改动界面后，用 `lua tools/cli.lua screenshot` 取试玩实机截图（口径见 `docs/agents/editor-cli.md`），逐项核验：对齐、换行与无裁切、4 倍数留白、可读对比度、零遮挡（不盖中央主视野与 `ENGINE_RESERVED`）。全部通过才算完成，不以 HTML 预览、Lua 计算值或 `SetProperty` 返回值替代。
