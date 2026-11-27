# 0009 Blender 只走无头，唯一入口为 CLI 的 blender 子命令

**Status**: deprecated（美术创作工作流已从主线移除，相关代码与文档保留在 git tag `art-workflow-archive-v1`；以下为历史记录，其中的路径与命令在主线已不存在）

agent 驱动 Blender 原本存在实时通道（MCP、socket 桥接）与多种无头裸调并存，无人值守时先试实时通道再回退导致反复失败、环境变量不统一，且裸调无法复用上游 skill 的 QA 与渲染脚本。

## 决定

Blender 只走无头，唯一入口为 `lua tools/cli.lua blender`（`tools/blender.lua`）。

- **调用契约**：`blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`，`--expr <代码>` 执行内联代码，`--which` 打印 Blender 路径与版本。
- **接缝与路径**：复用唯一接缝 `tools/seam.lua`（[ADR-0017](0017-windows-native-only.md)）；路径参数先绝对化再归一为正斜杠 Windows 形式，`--expr` 原文不转换。
- **定位**：只认 `BLENDER_EXE`（空串当未设置）；未设置时在 `%ProgramFiles%\Blender Foundation` 与 `%LOCALAPPDATA%\Programs\Blender Foundation` 按版本号数值取最新。不再使用 `BLENDER_PATH`。
- **执行与退出码**：由 `python`（3.x）运行上游 `run_in_blender.py`（`-b --factory-startup --python-exit-code 1`，仅输出 `@@JSON@@` 行）。缺 Blender / `python` / 脚本 / 输入文件时在启动前以退出码 3（外部工具不可用）失败；运行期透传上游退出码（语义为 `0` 成功 / 非零失败，不承诺保留 Blender 原始数值）。
- **上游 skill 不改**：`blender-*` skill 被 gitignore，其「Live 优先」由 `AGENTS.md`「美术资产」条目覆盖。
- **人工修模**：只靠固定位置的中间件 `.blend` 交接，人工在 GUI 修改存盘后由 agent 无头继续。

## 拒绝的方案

1. **实时 MCP / 插件 Meshy 集成**：需有人开着 Blender 界面，无人值守必然失败；Meshy 请求直接走独立 MCP 或 REST。
2. **裸调 `blender.exe -b`**：用不上上游 skill 的 QA、审阅渲染与环境报告脚本。
3. **修改上游 skill 或另写 shell 包装**：升级 skill 会覆盖修改；另起包装会多出无测试车道的接缝。

## 后果

- 测试分两层：fast 车道（`tests/native/blender_cli_test.lua`）桩测拼接、路径与定位；art 车道（`tests/native/art/blender_transport_test.lua`）真机跑环境报告与 QA。
- 视口截图改用无头渲染（上游 `blender-asset-qa/scripts/review_shots.py`）；API 查上游 skill `references/`。
