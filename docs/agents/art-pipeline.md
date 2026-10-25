# 美术资产流水线

为地图产出鱼类等模型与动画时读本文。尺寸口径见 [ADR-0004](../adr/0004-fish-asset-scale.md)。

## 定位

本仓只管**接入方式与约定**：Blender 怎么执行、Meshy 怎么接入、导出怎么命名与分件、验收看什么。**资产本体不进本仓**——正式资产走编辑器导入，预设随地图存档（见 [官方包接入参考](../packages-reference.md)）。生成某个模型的具体过程不在此记录。

## 接入

Blender 只走无头模式，唯一入口是开发端的 CLI 子命令 `blender`；AI 生成模型走 `meshy` MCP server。决定与被拒的备选见 [ADR-0009](../adr/0009-blender-headless-only.md)。

### blender —— CLI 子命令（只走无头）

在仓库根执行（开发端 WSL，Blender 装在部署端 Windows）：

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
- **上游 skill 的脚本优先**：QA（`blender-asset-qa/scripts/qa_check.py`）、审阅渲染（`review_shots.py`）、环境报告（`blender-core/scripts/env_report.py`）都直接调用，不再为每只资产手写审计代码。上游脚本都遵守 `run(**kw) -> dict` 契约，`--` 之后的参数见各脚本的 argparse。
- **跳过上游 skill 的 Live/MCP 段落**：上游 blender-* skill 写着「Live 优先」和 MCP `look` 工具，本项目一律不用；看图改用 `review_shots.py` 无头渲染。上游 skill 不在本仓管理，不改其文件。
- 资产自己的步骤脚本也照此调用；脚本写法与上游一致最省事（`_bpyx.cli` 负责解析 `--` 后参数、`--save` 与 JSON 输出）。

**中间件 `.blend` 交接**：每一步把结果存成一个中间件，失败只重跑那一步。位置固定为美术工作区该资产目录下的 `work/`，按步骤编号命名（`<资产目录>/work/NN-<步骤>.blend`，例如 `军舰鸟/work/03-model.blend`）。人工修模时，人在 Blender GUI 里打开最新的中间件，修改后**原地存盘**，然后通知 agent；agent 用 `--blend` 读这份文件，接着跑后续步骤。不经任何实时通道。

无头模式下两条注意事项：`bpy.ops.wm.open_mainfile` / `read_homefile` 会弄脏执行 context，
换文件用 `--blend` 交给入口，重建场景用逐个删除对象；`view_transform` 不设 `Standard` 时，
AgX 会把已按显示编码存盘的贴图再压一遍，自检渲染看起来像全黑。

历史脚本（海鸥 01~05、军舰鸟冒烟、鲤鱼）不迁移，作为留痕保留。鲤鱼脚本 docstring 里的 `blend.py` 用法已失效：socket 桥接脚本已改名为 `blend.py.bak`，需要重跑时改用 `blender` 子命令。

### meshy

`npx -y @meshy-ai/meshy-mcp-server`，凭据走环境变量 **`MESHY_API_KEY`**。

**密钥永不入库。** 仓库内引用与本地配置一切写 `MESHY_API_KEY` 变量名，值只放在本机环境（用户级环境变量）。

**执行端必须在 Windows。** 开发端是 WSL，但 WSL 里没有 Node、也没有 `MESHY_API_KEY`；MCP 的启动命令写成
`cmd.exe /c npx.cmd -y @meshy-ai/meshy-mcp-server`，由 WSL interop 拉起 Windows 的 Node 进程，
它继承 Windows 用户级环境变量、走 Windows 的 TLS 栈。这样 Codex 照常拿到 `mcp__meshy__*` 工具，
而真正的 API 调用发生在 Windows 侧。裸 `npx` 在 WSL 会报找不到 node。

> 2026-10-22 实测（海鸥试点 #124）：上述 `cmd.exe /c npx.cmd` 接法可用，MCP 工具正常注册。
> 早前「MCP 在 Node/undici 下 TLS 断开、改走 REST」的记录是鲤鱼试点时裸 `npx` 的结论，已过时。
> REST 后备仍是 `tools/meshy.py`（同样用 `curl.exe` 走 Windows TLS），参数与任务 ID 一并留痕。
>
> `file_path` 由 Windows 侧的 Node 进程读取，所以**必须写 Windows 绝对路径**
> （`C:\Users\<用户名>\...`，中文目录可以）；`/mnt/c/...`、`/home/...` 这类 WSL 路径一律报 `File not found`。
> 报 `File not found` 时先核对用户名目录与路径视图，别急着换通道（海鸥试点就是用户名目录写错，误判成了 server 缺陷）。
> 想不花额度确认文件读得到：传一个超过 20 MB 的 `.png`。server 读到文件后会先报 `File too large`，不会发出 API 请求。

### 前端配置

仓库不提交 MCP 配置，也不再维护 DSH 接入。在所用前端（目前是 Codex）里只接入 `meshy` MCP server，key 走环境变量 `MESHY_API_KEY`；接入后核对工具已注册。**不要注册 Blender MCP**：注册了 agent 就会被诱导去试实时通道。

## 制作约定

范围与待定预算见 [美术资产概要](../art-asset-overview.md)，复用取舍见 [ADR-0006](../adr/0006-structural-asset-reuse.md)。

- 建模前先定尺度：按 [ADR-0004](../adr/0004-fish-asset-scale.md) 的单位方块口径做，别在游戏对象上补缩放。
- 模型与动画分件导出，贴图按 ADR-0004 的编码约定。
- 蒙皮导入器可能拒绝 UCX 碰撞网格。碰撞体在游戏引擎侧搭，Blender 里的碰撞代理只作编辑参考，不随导出交付。
- 导出的对照文件与验收数据放在美术工作区，**不进本仓**。
- 历史面数与贴图参照：罗非鱼为 8268 三角面、1 个材质、1K 贴图，且当前仍有非流形边问题。这不是引擎限制，也不是后续全员预算；新资产按 [美术资产概要](../art-asset-overview.md#待定) 的分档候选试点校准。
- 过程留痕：每条鱼的 Blender Python 脚本、Meshy 任务 ID 与参数存在美术工作区该鱼目录下（脚本 + `NOTES.md`），本仓文档只引用，不复制。

## 验收

1. 逐文件按类型重导入验收：模型量尺寸、核对网格数并跑**网格封闭性审计**（硬门槛，见下节）；蒙皮模型另核对骨骼与权重；纯骨架动画核对骨架兼容性、帧区间与有效运动，不要求存在网格或独立网格审计段。固定姿态检查预期变换与蒙皮结果，不以帧间无运动判失败。完整资产报告的模型 `mesh` 段仍不可缺失。
2. 在游戏场景内按 [ADR-0004](../adr/0004-fish-asset-scale.md)「验收」一节，放到单位方块旁与参考鱼比对。
3. 播放动画后尺寸保持稳定，碰撞体同比例。
4. **运行时性能基线（待启动）**：首条合规模型产出后，在最大同屏密度场景下测 FPS 与 CPU 蒙皮耗时占比，作为骨数候选（见 [美术资产概要](../art-asset-overview.md#待定)）是否需要下压的输入。基线未测前，骨数预算保持候选值，不作引擎上限。

第 1 步只证明导出链路自洽；**不完成第 2 步不得宣布资产可用**。

第 1 步里的重导入量测已脚本化：报告落在美术工作区该鱼目录的 `validation/` 下，由 `art` 车道的 Gherkin（`features/art/`，读 `validation/validation.json` 断言）复核。报告不存在时验收直接失败——验收跑不起来正好等于「没做重导入校验」。美术资产根目录可用 `EGGY_ART_ASSETS` 覆盖；换机器没带美术工作区时这条车道会失败，这是有意的，别把它的绿色当成资产可用。

### 网格封闭性（硬门槛）

口径见 [#112](https://github.com/qinyuanj/se-fish/issues/112)。`04-validate.py` 把审计并入同一份 `validation.json` 的 `mesh` 段，`05-mesh-audit.py` 仍保留作单独排查。`features/art/mesh_topology.feature` 读该段断言，feature 里不写任何阈值。

- **硬性为 0**：非流形边（>2 面）、绕向不一致的边、游离顶点。
- **预算上限**（默认值）：连通块 ≤ 8、开放边占比 ≤ 3%、最大边界环 ≤ 40 边。
- **豁免**：只能放宽数值，不能关闭硬性 0 项。在该鱼目录放 `mesh-budget.json`，写明 `reason` 与要放宽的数值；报告会原样带上豁免理由，Gherkin 每次重读磁盘预算比对，改过预算却没重跑 `04-validate.py` 会判报告过期。
- **缺段即失败**：`mesh` 段缺失（旧报告）或预算文件读不到，`art` 车道直接失败，不会被静默放过。[#111](https://github.com/qinyuanj/se-fish/issues/111) 的教训正是「重导入校验全绿，网格却碎成 435 片」。
- **量法**：顶点先搬到世界空间，按包围盒对角线 `1e-5` 焊接后统计；开放边占比按「只属于 1 个面的边 / 焊接后总边数」计算。与 `05-mesh-audit.py` 同一套口径。

当前状态（2026-10-17 实测）：鲤鱼 435 连通块 / 49.49% 开放边 / 326 游离顶点，按口径判不合格，`art` 车道保持红色直到网格修好。罗非鱼基准 3 连通块 / 0.68% 开放边 / 0 游离顶点，但焊接后仍有 **4 条非流形边**（眼/嘴附近的退化微折叠，边长约为体长的 0.3%~1%），按「硬性为 0」也不合格；把它当基准前需要先清理微面，或单独记录把它定为基线的决定，不要为了让基线变绿去放宽硬性 0 项。

海鸥（2026-10-22 实测）：1 连通块 / 0 开放边 / 0 非流形 / 0 绕向不一致 / 0 游离顶点，
一次通过硬门槛。加工顺序是**体素重建 → 减面 → 贴图投射**——先重建让网格封闭，再减面就不会
像鲤鱼那样碎成 435 片；同一条路径值得作为新资产的默认做法。

## 试点复盘（鲤鱼，2026-10-16）

过程数据、任务 ID、脚本与校验报告都在美术工作区 `Desktop/dev/eggy/美术资产/鲤鱼/`（脚本工具 `meshy.py` 走 Meshy REST，位于同级的 `Desktop/dev/eggy/tools/`；当时直连 Blender 的 `blend.py` 已退役为 `blend.py.bak`）。这里只留可复用的结论。

- **额度口径要按模型档位算**：`meshy-7.1` 的预览是 **20** 额度（低模档才是 5），精修 10。一条鱼实扣 **30**；开工前按 20 报预览价。
- **精修只回 BaseColor**：Normal 与 ORM 必须在 Blender 自烘（high-poly → low-poly，roughness 值对齐参照鱼的 ORM G 通道均值）。
- **蒙皮别用 `ARMATURE_AUTO`**：本机对整条鱼求解失败（`Bone Heat Weighting: failed to find solution`），顶点组会全空、摆姿不形变。用参考鱼网格的顶点组做 Data Transfer。
- **动画源必须用已导出的动画 FBX**：从参考 `.blend` 里 `wm.append` 出来的 action 绑到同名骨架上位移恒 0，导出的是一堆静帧。另外 FBX 往返固定 **+1 帧**（导出按 `t=frame/fps`，导入按 `frame=t*fps+1`），导出前把区间平移回 1..N 才能与参照鱼逐段对齐；导出统一 `add_leaf_bones=False`，否则多出 `*_end` 骨骼、与参照件不同构。
- **尺度变换要排在烘焙之后**：把网格搬进骨架局部空间（`data.transform` + 零 `matrix_parent_inverse`）必须在渲染与法线烘焙之后做，提前换尺度会把烘焙打糊。
- **空动画探针要取全帧**：有些段的中间帧正好回到静止姿态，只对比首帧与中点会把真动画判成静帧。
- **Meshy 的参数探针要当心副作用**：`raw` 直发请求不受本地校验，服务端忽略未知字段，探测试验也可能真建任务。核账靠任务列表 + 余额差值。

## 已知缺口

- **游戏内导入**：罗非鱼已于 2026-10-16 由用户口头确认通过游戏内导入验证；模型、动画、尺寸各自的验证范围与碰撞体搭法**未留书面记录**，补齐前不要据此推定「带动画 FBX 导入已解决」。[技术难点识别](../技术难点识别.md) §1 仍是待做原型的表述，待记录补齐后再改。
- **导入路径须为纯 ASCII**：编辑器导入器的 `GetComponentData` 读不了含中文的路径，会报「加载fbx资源失败，资源不合法」并说文件不存在（2026-10-17 鲤鱼实测：从 `美术资产\鲤鱼\` 导入失败，复制到纯英文目录 `eggy\assets_import\carp\` 后导入成功）。导入前先把 FBX 与贴图复制到纯 ASCII 路径，不要直接从中文目录导入。
- **鲤鱼的游戏内验收（接缝 A）未做**：试点收尾时本机没有运行中的编辑器实例（`editor-cli status` 报 `NO_EDITOR_INSTANCES`），重导入校验与 `art` 车道虽然全绿，但按上面「验收」的口径**鲤鱼仍不能算可用**。执行步骤与取证要求见美术工作区的 `NOTES.md`。
- **鲤鱼模型有较多网格漏洞（2026-10-17，用户在编辑器里确认）**：已查明是整体碎片化（435 连通块、约 49% 开放边、326 游离顶点），现在由「网格封闭性」硬门槛拦下，`art` 车道保持红色。已决定**不重新生成**（Meshy 精修已实扣 30），留待后续工作，优先考虑在 Blender 里修补。修复前鲤鱼不可用，接缝 A 其余项（尺寸、动画、碰撞体）也等修复后再验。
- **生成段无记录**：罗非鱼从提示词到可用模型的这一段没有留下过程数据，只能按本接入口径重新生成；鲤鱼起按「制作约定」的过程留痕要求记录。
