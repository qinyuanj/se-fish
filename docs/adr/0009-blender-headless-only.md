# 0009 Blender 只走无头，唯一入口为 CLI 的 blender 子命令

**Status**: accepted

agent 驱动 Blender 原本有 2 种模式、5 个入口：实时模式有 Blender MCP 的 `execute_blender_code` 与鲤鱼试点的 socket 桥接脚本 `blend.py`；无头模式有裸调 `blender.exe -b`、blmcp 的 `execute_blender_code_for_cli`、上游 blender-core skill 的 `run_in_blender.py`。agent 每次先试实时通道（需要有人开着 Blender 界面），失败再回退；`BLENDER_PATH` / `BLENDER_EXE` 两个变量互不相认；上游执行脚本在 WSL 下找不到 Windows 的 Blender。2026-10-25 军舰鸟冒烟就是三条通道依次失败，最后靠裸调并手写审计代码跑完（#125）。

决定：Blender 只走无头，开发端唯一入口为 `lua5.4 tools/cli.lua blender`（`tools/blender.lua`）。

- **调用契约**：`blender <脚本.py> [--blend <输入.blend>] [-- <脚本参数>...]`，`--expr <代码>` 执行内联代码，`--which` 打印将用的 Blender 路径与版本。
- **跨接缝**：复用 [ADR-0008](0008-wsl-development-windows-deploy.md) 的 `tools/wsl_seam.lua`（interop 预检、`wslpath`、Windows 变量推导），不新增接缝。脚本、`--blend` 与 `--` 之后像开发端路径的参数（`/`、`./`、`../` 开头，含 `--key=/path`）先绝对化再转成 Windows 形式；`--expr` 原文不转换。
- **Blender 定位**：只认 `BLENDER_EXE`（接受 `/mnt/c/...` 与 `C:\...`，空串当未设置）；未设置时在 `%ProgramFiles%\Blender Foundation` 与 `%LOCALAPPDATA%\Programs\Blender Foundation` 下按版本号数值取最新。`BLENDER_PATH` 不再使用。
- **执行**：由 WSL 的 `python3` 运行上游 `run_in_blender.py`，并把 `BLENDER_EXE` 以 `/mnt/c/...` 形式传给它；该脚本负责 `-b --factory-startup --python-exit-code 1`，且只输出 `@@JSON@@` 行。interop、Blender、`python3`、上游脚本或输入文件缺失时，在启动 Blender 前以退出码 1 失败。
- **退出码**：透传上游脚本的退出码。上游会把 Blender 的非零退出码归一成 1（实测 `SystemExit(3)` 也得到 1），所以入口的语义是「0 成功 / 非零失败」，不承诺保留 Blender 的原始数值。
- **上游 skill 不改**：blender-* skill 被 gitignore，重装会覆盖本地修改。它们写着的「Live 优先」与不存在的 `look` 工具，改由 `AGENTS.md` 的「美术资产」条目覆盖：跳过 Live/MCP 段落，用 `blender` 子命令。
- **人工修模**：只靠中间件 `.blend` 交接。agent 每步把中间件存到固定位置，人在 GUI 里打开、修改、存盘，agent 接着用无头模式往下跑。

实测结论（2026-10-25，Blender 5.2.1 LTS，WSL2 Ubuntu-24.04）：

- Windows 侧 Blender 能直接读写 `\\wsl.localhost\...` 形式的 UNC 路径，包括 `-P` 脚本、`--blend` 输入与 `save_as_mainfile` 输出；中文与空格目录都可以，脚本同目录的依赖（`_bpyx.py`）也能 import。所以入口**不**把脚本复制到 Windows 临时目录。
- `wslpath -w` 对相对路径只给出相对的 Windows 路径，因此入口先绝对化，再转换。
- 由 WSL 拉起的 Windows 进程以当前目录对应的 UNC 路径为 cwd。

备选方案（拒绝）：

1. **实时 MCP**：需要有人开着 Blender 界面，agent 会先试错再回退；无人值守时必然失败。
2. **裸调 `blender.exe -b`**：能跑，但用不上上游 skill 的 QA、审阅渲染与环境报告脚本，每只资产都要手写审计代码。
3. **blmcp 的 `execute_blender_code_for_cli`**：依赖已撤掉的 MCP，变量名与 `BLENDER_EXE` 不统一，在 WSL 下报 `Blender executable not found at 'blender'`。
4. **修改上游 skill 的执行脚本**：重装或升级 skill 时修改会丢失。
5. **在 `tools/` 下另写 shell 包装**：会多出一个没有测试车道的接缝；CLI 子命令能复用现有接缝与 fast/slow 车道。

后果：

- 测试分两层：fast 车道（`tests/native/blender_cli_test.lua`）用桩验证命令拼接、路径转换、定位与拒绝执行；slow 车道（`tests/native/slow/blender_transport_test.lua`）用真 interop 与真 `blender.exe` 跑环境报告与 QA 检查，产物只落 Windows `%TEMP%`。
- 去掉 MCP 自带的 Blender API 与手册检索，改由上游 skill 的 `references/` 覆盖。
- 视口截图改为无头渲染（上游 `blender-asset-qa/scripts/review_shots.py`）。
- 海鸥 01~05、军舰鸟冒烟与鲤鱼的历史脚本不迁移，作为留痕保留；鲤鱼脚本 docstring 里的 `blend.py` 用法已失效（桥接脚本已改名为 `blend.py.bak`），需要重跑时改用 `blender` 子命令。
