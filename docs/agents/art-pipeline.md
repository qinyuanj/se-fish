# Blender 与 Meshy 使用

用无头 Blender 加工模型、用 Meshy 生成模型前读本文。决定与被拒的备选见 [ADR-0009](../adr/0009-blender-headless-only.md)。

## 工作区导航

美术文件在部署端 `C:\Users\<用户名>\Desktop\dev\eggy\` 下；开发端对应 `/mnt/c/Users/<用户名>/Desktop/dev/eggy/`。部署端路径可用 `wslpath -u '<Windows 路径>'` 转为开发端路径，反向用 `wslpath -w`。按下表定位后只搜索目标目录，避免递归扫描整个 `Desktop/dev/`。

| 位置（相对美术工作区） | 用途 |
| --- | --- |
| `美术资产/mesh-budget.json` | 默认网格预算；验收口径见[美术资产概要](../art-asset-overview.md#验收) |
| `美术资产/<资产名>/scripts/` | 单资产步骤脚本；既有重导入校验先例为 `鳄雀鳝/scripts/06-validate.py`、`海鸥/scripts/05-validate.py` |
| `美术资产/<资产名>/work/`、`output/`、`validation/` | 中间件、导出物与报告；实际路径以对应任务单为准 |
| `assets_import/<稳定 ID>/` | 纯 ASCII 导入副本，也可能包含诊断失败件；存在文件不表示已发布或已通过验收。导入编辑器前读[验收](../art-asset-overview.md#验收)的纯 ASCII 路径与动画随模型导入两条 |

用户提供的源素材目录以任务单为准，与上述加工工作区分开。例如正式素材可能在 `eggitor/1_开发中/渔力全开/正式模型动画/`；不要因文件同名改用其他目录的历史副本。先读任务单的来源和证据索引，再查已有脚本；共用工具归项目工具体系，资产与执行报告留在工作区。

## blender —— CLI 子命令（只走无头）

Blender 只走无头模式，唯一入口是开发端的 CLI 子命令 `blender`。在仓库根执行（开发端 WSL，Blender 装在部署端 Windows）：

```bash
lua5.4 tools/cli.lua blender --which                       # 核对将用的 Blender 路径与版本
lua5.4 tools/cli.lua blender .agents/skills/blender-core/scripts/env_report.py   # 会话首调：环境报告
lua5.4 tools/cli.lua blender .agents/skills/blender-asset-qa/scripts/qa_check.py \
  --blend <中间件.blend> -- --objects Fish
lua5.4 tools/cli.lua blender <资产目录>/scripts/03-model.py --blend <上一步.blend> -- --save <本步.blend>
lua5.4 tools/cli.lua blender --expr "import bpy; print(len(bpy.data.objects))"
```

- **路径写开发端形式**：脚本、`--blend` 与 `--` 之后以 `/`、`./`、`../` 开头的参数（含 `--key=/path`）由入口转成 Windows 形式；美术工作区写 `/mnt/c/Users/<用户名>/...`。`--expr` 里的代码原样传递，里面的路径要自己写 Windows 形式。
- **输出与退出码**：stdout 只有脚本的 JSON（`@@JSON@@` 行去掉标记），不夹带 Blender 启动日志；脚本失败时退出码非零，并输出 `{"ok": false, ...}`。interop 不可用或找不到 Blender 时，在启动 Blender 前以退出码 1 失败。
- **Blender 定位**：只认 `BLENDER_EXE`（接受 `/mnt/c/...` 与 `C:\...`）；未设置时在 Windows 标准安装目录下按版本号取最新。`BLENDER_PATH` 不再使用。
- **上游 skill 的脚本优先**：QA（`blender-asset-qa/scripts/qa_check.py`）、审阅渲染（`review_shots.py`）、环境报告（`blender-core/scripts/env_report.py`）都直接调用，不为每只资产手写审计代码。上游脚本都遵守 `run(**kw) -> dict` 契约，`--` 之后的参数见各脚本的 argparse。资产自己的步骤脚本照此写最省事（`_bpyx.cli` 负责解析 `--` 后参数、`--save` 与 JSON 输出）。
- **跳过上游 skill 的 Live/MCP 段落**：上游 blender-* skill 写着「Live 优先」和 MCP `look` 工具，本项目一律不用；看图改用 `review_shots.py` 或自写脚本无头渲染。上游 skill 不在本仓管理，不改其文件。
- **中间件 `.blend` 交接**：每一步把结果存成 `<资产目录>/work/NN-<步骤>.blend`，失败只重跑那一步。人工修模时，人在 Blender GUI 里打开最新中间件、修改后原地存盘再通知 agent；agent 用 `--blend` 读这份文件接着跑。不经任何实时通道。

### 上游 blender-* skill

`.agents/skills/blender-*`（gitignored，不归本仓管理）由 magpie 资源库复制而来：来源是部署端 `C:\Users\<用户名>\.config\magpie\library\skills\<skill 名>`，经 magpie 复制的 skill 目录下有 magpie 写入的 `.magpie-library`，记录来源路径（`copied from ...`）与 `hash`；资源库源目录里没有这个文件。`blender` 子命令依赖其中的 `blender-core/scripts/run_in_blender.py`，缺失时报「上游 blender-core skill 未安装」并指向本节。

缺失或损坏时按 [workflow「worktree 起手式」](workflow.md) 用 `worktree-init` 补齐（开发端资源库路径 `/mnt/c/Users/<用户名>/.config/magpie/library/skills/`）。复制不会生成 `.magpie-library`，用 `diff -rq` 对照资源库确认内容一致即可；再跑 `lua5.4 tools/cli.lua blender --which` 与 `env_report.py` 确认可用。改动一律回资源库做，再删掉本地目录后重跑。

### 无头 Blender 踩坑

- **换文件**：`bpy.ops.wm.open_mainfile` / `read_homefile` 会弄脏执行 context；换文件用 `--blend` 交给入口，重建场景用逐个删除对象。
- **自检渲染**：`view_transform` 设 `Standard`，否则 AgX 会把已按显示编码存盘的贴图再压一遍，看起来像全黑。
- **看图**：`view_image` 只认 `/mnt/c/...` 路径，读不了 `/tmp`；重渲同名 PNG 可能拿到旧图，换新文件名再看。
- **贴图投射压暗**：EMIT 投射到 Non-Color 缓冲前，源贴图也要设为 Non-Color，否则按 sRGB 解码会整体压到约 40%。
- **`ARMATURE_AUTO` 会静默失败**：求解失败或网格有重合点（如切口）时不抛异常、顶点组全空。热权重要在切口之前求；求完核对顶点组非空，失败改用参考网格的顶点组做 Data Transfer。
- **FBX 动画往返**：动画源用已导出的动画 FBX；从 `.blend` 里 `wm.append` 出的 action 绑到同名骨架上位移恒 0。往返固定 **+1 帧**（导出按 `t=frame/fps`，导入按 `frame=t*fps+1`）。导出统一 `add_leaf_bones=False`，否则多出 `*_end` 骨骼。
- **空动画探针要取全帧**：有些段中间帧正好回到静止姿态，只比首帧与中点会把真动画判成静帧。

## meshy —— MCP server

`npx -y @meshy-ai/meshy-mcp-server`，凭据走环境变量 **`MESHY_API_KEY`**。**密钥永不入库**：仓库内引用与本地配置只写变量名，值只放在本机用户级环境变量。

**执行端必须在 Windows。** 开发端 WSL 里没有 Node、也没有 `MESHY_API_KEY`；MCP 启动命令写成
`cmd.exe /c npx.cmd -y @meshy-ai/meshy-mcp-server`，由 WSL interop 拉起 Windows 的 Node 进程，
继承 Windows 用户级环境变量、走 Windows 的 TLS 栈。裸 `npx` 在 WSL 会报找不到 node。
REST 后备是美术工作区同级的 `Desktop/dev/eggy/tools/meshy.py`（不在本仓，同样用 `curl.exe` 走 Windows TLS）。

- **`file_path` 写 Windows 绝对路径**（`C:\Users\<用户名>\...`，中文目录可以）；`/mnt/c/...`、`/home/...` 一律报 `File not found`。报这个错时先核对用户名目录，别急着换通道。不花额度确认文件读得到：传一个超过 20 MB 的 `.png`，server 会先报 `File too large`，不发 API 请求。
- **额度按模型档位算**：`meshy-7.1` 图生 3D 不带贴图 20、带 2K 贴图 30；低模档才是 5。开工前按档位报价并等用户确认。
- **只回 BaseColor**：Normal 与 ORM 要在 Blender 自烘。
- **不传 `auto_size` 与 `origin_at`**：`auto_size` 按现实米数估高度，与 [ADR-0004](../adr/0004-fish-asset-scale.md) 的单位方块口径冲突；尺寸与原点只在 Blender 步骤脚本里设定一次，避免多环节重复补偿。
- **首领走三视图**：先用 image-to-image（`generate_multi_view`）从已确认的概念图出正、侧、背三视图，再用 multi-image-to-3d 生成。该接口把第一张图当正面，而返回的视图顺序不一定是正面在前，提交前按画面核对顺序（三头鲨返回的是背、侧、正），用 `file_paths` 重排后提交。三视图会沿用概念图的机位：概念图是俯视时，返回的是俯视和仰视，交进去会被当成竖立的物体重建。因此提示词要写明 `camera always horizontal at body height (no top view, no bottom view)`，并逐张写出 front / side / back。哪些鱼走三视图见[美术资产概要](../art-asset-overview.md)「已定」的三视图范围。
- **参数探针有副作用**：`raw` 直发请求不受本地校验，服务端忽略未知字段，探测也可能真建任务。核账靠任务列表 + 余额差值。
- **过程留痕**：Meshy 任务 ID 与参数记在美术工作区该资产目录下，本仓不复制。

### 前端配置

Codex 的 MCP 注册在仓库内 `.codex/config.toml`（gitignored，不入库），只有 `[mcp_servers.meshy]` 一个条目，启动命令即上节的 `cmd.exe /c npx.cmd ...` 接法；文件里不写密钥值。改动后重启会话，核对 `mcp__meshy__*` 工具已注册。**不要注册 Blender MCP**：注册了 agent 就会被诱导去试实时通道。
