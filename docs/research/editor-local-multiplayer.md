# 当前编辑器的本地模拟多人功能调查

- **调查日期**：2026-11-20（Asia/Shanghai）
- **调查对象**：蛋仔世界编辑器（状态同步，SE）当前本机实例
- **编辑器版本**：1.0.37（当前窗口底部所示完整构建串为 `1.0.37(1794484929.37d345623a.4478607.37-0)`）
- **editor-cli**：0.20.17，commit `184bb043d85bd6aa532f937ab2fd5b09231235ef`
- **调查方式**：只读 `status`、`--help`、`docs search`、官方网页、安装资源文本检索、按规范截图；未保存地图、未改代码或配置、未创建房间、未启动或停止试玩、未执行输入注入或运行时 `exec`
- **结论口径**：“未找到”只表示下列版本与证据范围内没有命中，不推断功能不存在。

## 一、结论摘要

**截至本次调查，未找到当前编辑器或 editor-cli 0.20.17 提供“在单个本地试玩中添加多个虚拟玩家/机器人，并生成多个真实 `Player`”的公开入口或参数。** 已找到的相近能力属于四个不同类别，不能混称“本地模拟多人”：

1. **PC 编辑器多开**：官方确认支持同机同时多开，公告用途是多地图切换对照或协同编辑；没有证据证明它必然生成多个游戏客户端、多个真实 `Player`，或让这些实例共享一个试玩服务器。[E7]
2. **实时共建与多人测试**：官方描述为邀请地图权限人、创建多人测试房间、其他真实玩家随进随出；官方教程明确把多人验收建立在“真实第二客户端/真正双客户端联机环境”上，并明确不能用模拟玩家对象宣称通过。[E4][E5][E6]
3. **输入注入与客户端执行目标选择**：`play input ... --player` 和 `exec --player` 选择目标玩家 id/name；没有创建玩家参数。新的 `input key`、`input move-to` 帮助反而没有 `--player`。[E2]
4. **服务端 `EggyUnit` NPC**：官方允许用 `World:CreateUnit` 创建可作为怪物或 NPC 的 `EggyUnit`，但 `Player` 不能自行创建、必须从 `Players` 获取。因此 NPC 不是额外真实玩家，也不能替代真实多客户端验收。[E8][E9]

## 二、能力结论表

| 能力 | 已找到的具体入口/参数 | 同机多进程/多客户端 | 是否生成真实 `Player` | 是否共享服务器/房间 | 输入如何分派 | 人数与限制 | 本次判定 |
|---|---|---|---|---|---|---|---|
| 单编辑器本地虚拟玩家/机器人 | 未找到；`play start` 只有等待就绪相关参数，无人数、机器人、玩家创建参数 | 未找到 | 未找到 | 未找到 | 不适用 | 未找到 | **未找到公开入口，不断言不存在** |
| PC 编辑器多开 | 官方公告“【PC编辑器】支持多开” | 明确是同机多编辑器；是否同机多游戏客户端未验证 | 公告未说明 | 公告未说明 | 公告未说明 | 多开数量未公布 | **是编辑器多开，不等于本地模拟多人** [E7] |
| 实时共建 | `主菜单 → 共建`，在“共建房间”邀请当前编辑器在线的地图权限人 | 跨手机/PC 的真实协作者；同机多开能否参与未验证 | 面向真实地图权限人 | 属共建房间；底层服务器拓扑未公开 | 各真实客户端自行输入 | 共建人数上限 20；不是多人测试人数上限 | **真实协同编辑** [E5][E7] |
| 实时共建中的多人测试/多人试玩 | 官方公告称“通过多人测试创建房间进入试玩”；本次未点击实际房间入口 | 需要真实第二客户端；同机实现方式未验证 | 官方语义为其他真实玩家加入 | 同时仅一个多人试玩房间；地图版本以首位开始游戏者为准；是否单一服务器进程未说明 | 未实测多玩家分派 | 多人测试人数上限未找到；随进随出 | **真实玩家房间，不是本地机器人证据** [E4][E6] |
| `input` 输入模拟 | `input key/touch/joystick/move-to/state/stop` | 不创建进程/客户端 | 否；作用于活动试玩 | 不改变房间/服务器 | `key`、`move-to` 无 `--player`；面向活动试玩玩家 | 需 `in_game_runtime=true` | **输入注入，不增加玩家** [E2] |
| `play input` 引擎输入注入 | `press/move/look ... --player <id/name>` | 不创建进程/客户端 | 否；选择已有目标 | 不改变房间/服务器 | 按玩家 id/name 定向 | `--duration-ms` 1..5000；需活动试玩与 `play_input` 能力 | **已有玩家的输入目标选择** [E2] |
| `exec --player` | `exec --platform client --player <id/name>` | 不创建进程/客户端 | 否；选择客户端运行时玩家 | 不改变房间/服务器 | 不是输入注入；选择执行 Lua 的客户端玩家上下文 | `exec` 属可变更运行时的命令，本次未执行 | **客户端执行目标选择** [E2] |
| 服务端 `EggyUnit` NPC | `World:CreateUnit("EggyUnit", ...)` | 同运行时单位，不是新客户端 | **不是 `Player`** | 位于创建它的运行时；不是新房间 | 由 NPC/服务端逻辑驱动，不是真实客户端输入 | 不触发真实玩家身份、客户端和连接语义 | **NPC 模拟，可补充但不能替代多人联机验收** [E8][E9] |

> 特别注意：官方“共建人数上限 20”只用于实时共建，不应转写成“多人测试支持 20 人”。多人测试的独立人数上限在本次资料中未找到。

## 三、本机实际状态与 UI 证据

### E1. 当前实例、版本和状态

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" --version
"$USERPROFILE/.eggitor/cli/editor-cli.exe" status --json
"$USERPROFILE/.eggitor/cli/editor-cli.exe" editor-instances list --json
```

输出摘要：

- `editor-cli 0.20.17`；`cli_build.commit_short=184bb04`。
- `running=true`、`editor_state="playing"`、`in_game_runtime=true`、`edit_mode=false`。
- `editor_mode="se"`、`is_se_mode=true`、`play_session="dd43567"`。
- 当前只列出一个已注册编辑器实例：PID 42444、HTTP 19859，安装工程目录 `C:\FeverApps\party_pc`。
- 只读 `get-Process -Name client` 也只返回一个 `client.exe` 进程：PID 42444，路径 `C:\FeverApps\party_pc\bin\client.exe`。该文件没有可读 `FileVersion/ProductVersion`，编辑器版本以窗口画面为准。

这只能证明**调查时只有一个实例**，不能证明编辑器不支持多开；官方多开公告见 E7。

### E2. CLI 完整相关帮助

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" --help --include-internal
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play start --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" input --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" input key --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" input move-to --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play input --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play input press --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play input move --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" play input look --help
"$USERPROFILE/.eggitor/cli/editor-cli.exe" exec --help
```

输出摘要：

- `play` 公开子命令为 `start/stop/restart/input`；含内部命令的总帮助中未出现添加玩家、机器人、玩家数量或本地多人房间命令。
- `play start` 仅有 `--wait-ready`、`--wait-timeout`、`--log-path` 及通用连接/输出参数；没有人数或机器人数值参数。
- `input` 描述为活动试玩中的 joystick/key/touch/move-to/state/stop；`input key` 与 `input move-to` 的选项均不含 `--player`。
- `play input` 描述为“Inject engine-level test input ... This is not OS SendKeys”，其 `press/move/look` 都有 `--player <player>  Target player id/name`，并有 `--duration-ms` 1..5000。
- `exec` 的 `--player <player>` 描述为“Player id/name for client runtime execution”。它选择执行客户端 Lua 的玩家上下文，不是创建玩家或注入输入的接口。

因此，“所有 `input/play input/exec --player` 都相同”的说法不准确：至少当前 `input key/move-to` 没有 `--player`，而 `play input` 与 `exec` 有，且用途不同。

### E3. 当前编辑器只读截图

先执行：

```bash
lua tools/cli.lua screenshot --info
```

输出确认目标为标题“钓鱼怎么这么危险啊喂！”的 `client` 窗口，1872×1080，NVIDIA GeForce GTX 1080 Ti，非虚拟屏，采用后台 `PrintWindow` 通道。随后执行：

```bash
lua tools/cli.lua screenshot --out tmp/editor-local-multiplayer-20261120.png
```

证据文件：[当前编辑器截图](../../tmp/editor-local-multiplayer-20261120.png)。

画面可见：

- 底部编辑器版本 `1.0.37(1794484929.37d345623a.4478607.37-0)`。
- 顶部有“共建”“教程”等入口；试玩左上角为“退出”分裂按钮。
- 当前展开画面未显示“本地多人、模拟多客户端、虚拟玩家、机器人、添加玩家、玩家数量”等控件。

本次没有点击“共建”或“退出”旁的下拉菜单，因为继续操作可能进入邀请、建房或试玩状态控制；故**深层菜单是否有其他入口未验证**，不能由这张截图推断不存在。

## 四、官方文档、公告与教程

### E4. 多人测试是房间与其他玩家加入

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "多人测试" --docset manual --world-mode se --limit 5 --json
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "随进随出" --docset manual --world-mode se --limit 5 --json
```

官方 SE 手册结果：

- 《2026.8.20 蛋仔世界编辑器更新公告》（条目内官方短链 <https://g.126.fm/00JnYHT>）：“【实时共建】现已支持多人随进随出的试玩模式，通过多人测试创建房间进入试玩，后续其他玩家可以随时加入该地图。”
- 《2026.8.13 蛋仔世界编辑器更新公告》（<https://g.126.fm/01Xstzb>）：“多人共建的多人试玩功能现已支持随进随出。试玩地图版本以首位开始游戏的玩家版本为准。当前仅支持同时存在一个多人试玩房间。”

这些原文支持“真实玩家房间”的解释，但没有公开具体服务器进程拓扑，也没有给多人测试人数上限。

### E5. 实时共建的官方教程入口

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "实时共建" --docset manual --world-mode se --limit 3 --json
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "多人测试 邀请" --docset manual --world-mode se --limit 5 --json
```

《多人协同：地图共建》（<https://g.126.fm/02HUvix>）给出：

- 地图内路径为 `主菜单 → 共建`。
- 在“共建房间”中选择当前编辑器在线的地图权限人并“邀请”。
- 被邀请人收到弹窗并确认后进入实时共建。
- 地图工程必须上传云端才能发起共建邀请，本地工程无法发起。

这与当前截图顶部“共建”入口相互印证，但本次未打开该界面。

### E6. 官方教程要求真实第二客户端

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "模拟多人" --docset manual --world-mode se --limit 3 --json
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "多人试玩" --docset manual --world-mode se --limit 5 --json
```

官方教程结果：

- 《10 整理代码并交付小游戏》（<https://g.126.fm/00xT9nb>）：“多人项需要实际联机环境。若只有单客户端，先完成其余项，并把多人项明确留作待验证，不能用模拟玩家对象宣称通过。”验收行写明“有真实第二客户端时中途加入”。
- 《05 把分数记给正确玩家》：“两名玩家之间的归属必须在真正的双客户端联机环境验证，单人日志不能证明这一点。”
- 《完成小游戏后选择扩展挑战》要求“能验证两名真实玩家的环境”，并称“只能启动单客户端时，不能声称多人测试通过”。

### E7. 官方多开与共建人数公告

第一方网页全文已抓取并核对：

- [2026-08-27 乐园&工坊更新](https://party.163.com/202507/eggyuni/news/update/20260827/42709_1312437.html)：“PC编辑器现已支持同时多开，方便创作者在多地图间切换对照或协同编辑。”同页另述“共建的人数上限提升至20人”。
- [2026-09-03 乐园&工坊更新](https://party.163.com/202507/eggyuni/news/update/20260903/42709_1313025.html)：“现已支持手机端和PC端实时共建，共建人数上限提升至20人。”
- [2026-07-30 乐园&工坊更新](https://party.163.com/202507/eggyuni/news/update/20260730/42709_1309611.html)：“PC端编辑器现已支持实时共建协作”。

公告没有把“多开”描述为“生成多个本地机器人/虚拟玩家”，也没有给多开数量上限。

### E8. `Player` 不能自行创建

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "Player 创建" --docset game-api --world-mode se --limit 5 --json
```

官方 `Player` API 条目原文：“Player 不能自行创建，应从 Players 获取。”同一条目说明 `Player` 以 `UserId` 标识，通过 `Character` 关联操控单位，通过 `PlayerGui` 访问玩家界面。

### E9. `EggyUnit` NPC 与网络所有权

执行：

```bash
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "EggyUnit NPC" --docset game-api --world-mode se --limit 5 --json
"$USERPROFILE/.eggitor/cli/editor-cli.exe" docs search "CreateUnit Player" --docset game-api --world-mode se --limit 5 --json
```

官方 `EggyUnit` API 条目说明：

- `EggyUnit` 可由玩家操控，也可作为怪物或 NPC。
- 创建单位应使用 `World:CreateUnit`，示例创建 `EggyUnit`。
- `SetNetworkOwner(player: Player)` 接收真实 `Player`；网络拥有者决定哪个客户端主导同步。

所以“创建一个高仿真 `EggyUnit`”不等于“创建一个 `Player` 或客户端”，也不能凭空提供网络所有权所需的真实玩家。

### 官方链接可访问性说明

`docs search` 返回的多数条目 `source` 与 `canonical_url` 为空，上文保留了条目内 `g.126.fm` 官方短链。抓取短链时发生到 `ugc.163.com` 的跨源跳转，随后 `curl -I` 得到 404；因此 E4/E5/E6 的证据基准是**本机官方 `docs search` 的完整条目输出**，不是对短链网页全文的独立抓取。E7 的 `party.163.com` 页面则已直接取得并核对原文。

## 五、本机第一方安装资源检索

在以下目录检索了 `json/lua/py/js/html/qml/xml/ini/txt` 可读文本：

- `C:\FeverApps\party_pc\bin`：返回 11 个此类文件，主要为日志与配置/说明。
- `C:\FeverApps\party_pc\res`：1 个（`res\log.txt`）。
- `C:\FeverApps\party_pc\ExternalResource`：1 个许可证文本。
- `C:\FeverApps\party_pc\ccmini`、`ppk`：上述扩展名返回 0 个。
- `C:\FeverApps\party_pc\Documents`：返回 1140 个此类文件，包含本机地图、缓存和日志等内容。

中文检索式：

```text
多人测试|多人试玩|实时共建|本地多人|模拟多人|多客户端|虚拟玩家|添加玩家|玩家数量|多开
```

英文检索式（忽略大小写）：

```text
multi.?player|play.?test|virtual.?player|player.?count|add.?player|multi.?client|co.?build|\bbots?\b
```

结果：上述可读文本中没有匹配行。但安装根目录还存在大型二进制/打包资源（例如 `C:\FeverApps\party_pc\gui2.npk`、`char.npk`）以及可执行文件，本次未解包或反编译。因此此处只能记录“**可读文本未命中**”，不能据此否定打包 UI 或二进制中存在入口；也没有可引用的功能配置文件行号。

## 六、已验证与未验证清单

### 已验证

- [x] 本机 editor-cli 为 0.20.17，编辑器画面版本为 1.0.37，当前为 SE 且处于既有试玩中。[E1][E3]
- [x] `play start` 没有人数/机器人参数；公开及含内部命令帮助未显示本地玩家创建命令。[E2]
- [x] `play input --player` 与 `exec --player` 是目标选择；`input key/move-to` 没有 `--player`。[E2]
- [x] 官方 `Player` 不能自行创建；`EggyUnit` 可作为 NPC 且可创建。[E8][E9]
- [x] 官方支持 PC 编辑器多开；官方实时共建有邀请、房间和 20 人共建上限。[E5][E7]
- [x] 官方多人测试描述为创建房间、其他玩家加入；官方教程要求真实第二客户端。[E4][E6]
- [x] 当前画面顶层未显示本地模拟多人控件；已保留截图。[E3]

### 未验证/未找到

- [ ] “共建”“退出”下拉菜单及其他深层 UI 是否另有“添加玩家/虚拟玩家/机器人”入口：未点击，未验证。
- [ ] 多人测试的独立人数上限：未找到；不能用共建 20 人代替。
- [ ] 同机多开能否运行多个游戏客户端、是否需不同账号、能否加入同一多人测试房间：未实验，公告未说明。
- [ ] 多人测试是否共享单一服务器进程及其网络拓扑：未找到；只确认“同时一个多人试玩房间”和地图版本规则。
- [ ] 多真实玩家存在时 `play input --player` 的实际路由、失败行为和 `exec --player` 的隔离边界：未注入、未执行。
- [ ] 打包 `.npk` 与二进制内的 UI 字符串：未解包/反编译；可读文本无命中不构成不存在证明。

## 七、对“服务端高仿真 `EggyUnit` NPC”方案的影响

### 可以承担的验证

- 在服务端创建可控的蛋形单位，验证服务端权威单位逻辑、场景交互、碰撞/战斗、NPC 行为和性能等“单位级”问题；官方 API 本身支持 `EggyUnit` 作为 NPC。[E9]
- 作为真实玩家之外的对手/目标，补充单客户端试玩中的服务端玩法覆盖。

### 不能冒充的多人验证

- 不会增加 `Players:GetPlayers()` 的真实玩家数，不能替代 `PlayerAdded/PlayerRemoving`、真实 `UserId`、加入/离开/掉线等玩家生命周期。
- 没有独立真实客户端，不能验证双端 UI、玩家输入路由、网络所有权归属、客户端执行上下文、联机同步与随进随出。
- 涉及 `PlayerGui`、存档、社交、传送等以真实 `Player` 为身份主体的流程，仍需真实玩家环境。
- `SetNetworkOwner` 需要已有 `Player`，NPC 自身不能解决“第二个网络所有者”的来源。[E8][E9]

**方案结论**：服务端高仿真 `EggyUnit` NPC 适合作为“服务端单位/玩法高仿真补充测试”，不应命名为“本地模拟多人已通过”。多人归属、双客户端同步、加入离开和玩家输入等验收必须继续保留为真实第二客户端测试项；这与官方教程的要求一致。[E6]

## 八、最终判断

当前能确认的不是“一键本地模拟多人”，而是：

- **编辑器可以多开**；
- **实时共建/多人测试使用真实协作者和房间**；
- **CLI 可向活动试玩注入输入或选择已有玩家执行客户端代码**；
- **`EggyUnit` 可做 NPC，但不是 `Player`**。

因此，对当前项目最稳妥的口径是：**单客户端 + 服务端 NPC 可覆盖部分服务端高仿真场景；真正多人验收仍需真实第二客户端/多人测试房间。是否存在未公开的本地虚拟玩家入口，本次未找到且未验证，不作不存在断言。**
