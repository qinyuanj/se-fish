# 0040 本地模拟多人不可用，多人验收必须真实第二客户端

**Status**: accepted（2026-11-20 取证，2026-11-24 收口为能力事实型 ADR）

单客户端试玩是日常开发的主路径，多人功能却必须有两个真实玩家才谈得上验收。这条 ADR 只记**在钉子版本上查到了什么、没查到什么、验收因此被约束在哪**；它不对「官方是否另有未公开入口」下结论。

## 版本钉子

- 编辑器 1.0.37（窗口底部构建串 `1.0.37(1794484929.37d345623a.4478607.37-0)`）。
- editor-cli 0.20.17，commit `184bb04`（`status --json` 的 `cli_build.commit_short`）。

版本一变就按本节重新取证：本文所有结论只在这些版本、本机 `docs search` 内容与下方「查了什么」的范围内成立。

## 查了什么

查过：

- 0.20.17 的完整帮助：`--help --include-internal`、`play --help`、`play start --help`、`input --help`、`input key --help`、`input move-to --help`、`play input press|move|look --help`、`exec --help`。
- `docs search` 的 `manual` 与 `game-api` 两个 docset（SE），检索「多人测试」「多人试玩」「实时共建」「模拟多人」「Player 创建」「EggyUnit NPC」「CreateUnit Player」等词。
- 官方更新公告网页全文（多开、实时共建）与官方教程（小游戏交付、分数归属、扩展挑战）。
- 本机安装目录 `C:\FeverApps\party_pc` 可读文本的关键词检索（`bin` / `res` / `ExternalResource` / `Documents` 下的 json、lua、js、html、qml、xml、ini、txt），以及编辑器运行画面的只读截图。

没查：

- 编辑器深层 UI：「共建」「退出」下拉菜单与其他二级入口未逐项点开。
- 打包资源与二进制：`gui2.npk`、`char.npk` 等 `.npk` 未解包，可执行文件未反编译。
- 多开实验：没有用两个编辑器实例实际进入同一试玩房间。
- 多玩家输入路由：没有在真实多人房间执行 `play input --player` 或 `exec --player`。

「未找到」只在本节列出的版本与范围内成立，不能读成「官方没有这个能力」。

## 结论

- **`play start` 没有人数或机器人参数**：选项只有 `--wait-ready`、`--wait-timeout`、`--log-path` 与通用连接 / 输出参数；含内部命令的总帮助里也没有添加玩家、机器人或本地多人房间的命令。
- **`input key` / `input move-to` 没有 `--player`**：`input` 一族向活动试玩注入输入，不选目标玩家。`play input press|move|look` 才有 `--player <id/name>`，那是选择已有玩家，不是创建玩家；`exec --player` 同理，选的是客户端 Lua 的执行上下文。
- **`--duration-ms` 上限 5000**：`play input` 的持续时间取值 1..5000，单次注入跨不过一段完整多人流程。
- **`Player` 不能自行创建**：官方 API 原文是「Player 不能自行创建，应从 Players 获取」；`Player` 以 `UserId` 标识，经 `Character` 关联操控单位。
- **NPC 不能替代真实玩家**：`World:CreateUnit` 可以创建 `EggyUnit` 当怪物或 NPC，但它不进 `Players:GetPlayers()`，没有真实 `UserId`、独立客户端与连接，也提供不了 `SetNetworkOwner` 需要的第二个真实 `Player`。
- **官方教程要求真实联机环境**：多人项「需要实际联机环境」；只有单客户端时必须明确留作待验证，「不能用模拟玩家对象宣称通过」；玩家归属一类判定必须在真正的双客户端环境验证。
- 官方公告里的「PC 编辑器多开」是多编辑器同机运行，公告用途是多地图对照与协同编辑，没有说它生成多个游戏客户端或多个真实 `Player`。实时共建 / 多人测试走的是邀请真实地图权限人、创建房间、其他玩家随进随出。

## 验收后果

- 多人条款的证据只能是**真实第二客户端**（或真实多人测试房间）的联机结果；单客户端里跑通的服务端逻辑测试只证明代码路径，不证明多人行为。
- 服务端高仿真 `EggyUnit` NPC 可用于单位级玩法、碰撞与性能的补充测试，但命中不了玩家生命周期（`PlayerAdded` / `PlayerRemoving`、加入 / 离开 / 掉线）、双端 UI、输入路由、网络所有权与随进随出；把它写成「本地模拟多人已通过」是错误结论。
- 没有第二客户端时，多人相关条款按[验收矩阵](../acceptance/README.md)保留 `unverified` / `blocked`，不得用单客户端试玩或 NPC 结果改状态（口径见 [ADR-0027](0027-clause-matrix-as-sole-acceptance-surface.md)）。
- 条款缺口的处理仍按 [ADR-0029](0029-scope-completeness-and-placeholder-first.md)：本地能完成的部分先做完并留证，依赖外部环境的部分单列，不写永久出界。

## 仍未验证

- **多开是否产生多个客户端**：同机多开能否同时运行多个游戏客户端、是否需不同账号、能否进入同一多人测试房间，公告未说明，也未实验。
- **多人测试的人数上限**：未找到公开上限；共建人数上限不是多人测试上限，不能互相转写。
- **`.npk` 内是否有入口**：打包 UI 与二进制未解包 / 反编译，可读文本无命中不构成不存在证明。
- **深层 UI 是否有添加玩家入口**：「共建」「退出」等下拉菜单未点开。
- **多玩家下的输入路由与执行隔离**：`play input --player` 在多名真实玩家存在时的实际分派与失败行为，以及 `exec --player` 的隔离边界，未实测。
