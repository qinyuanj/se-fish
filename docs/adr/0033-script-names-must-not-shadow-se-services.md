# 0033 脚本目录与文件名不得与 SE 内置服务名同名

**Status**: accepted

编辑器按**内置服务名**索引 Lua 工程，三端（`client/`、`common/`、`server/`）下的目录或脚本名一旦与内置服务同名，同步时整棵子树被跳过，并在编辑器面板报 `warn/editor`「以下Lua文件或目录名与SE内置服务名冲突，已跳过同步，不会生效」。2026-11-24 13:52 本图实测 `server/World/` 中招：该目录承载服务端 Spoke 世界宿主（`ServerRuntime`、`SharedWorldTree`、`PlayerTree`、`FishTree` 等 35 个模块），与内置全局服务 `World`（`EggyAPI.lua` 的 `---@class World : WorldRoot`）重名。

决定：世界宿主包改名 **`server/WorldHost/`**，模块前缀随之变为 `server.WorldHost.*`；新增顶层目录或脚本文件前先按内置服务名核对。已知 `World` 在其中，`MapData`、`Game`、`Camps` 与 `*Service` 一族同为内置全局名，一并避让。规则同时写进 [架构分层「关键边界」](../architecture.md) 与 [CODING_STANDARDS.md](../../CODING_STANDARDS.md)。

观测口径：编辑器告警只说明同步被跳过，不等于文件不在本地地图里——`code diff` 仍可能报 `unchanged`（残留副本或缓存）。因此不拿 diff 干净当"已生效"的证据，判定标准是告警消失。

## 备选方案（拒绝）

- **保留 `server/World` 并忽略告警**：编辑器自己声明该子树「不会生效」，把整棵世界宿主留在同步盲区里；出问题只会在试玩时以更难定位的形态出现。
- **改成小写 `server/world`**：大小写是否参与重名判定没有依据；靠大小写绕开保留名，编辑器行为一变就复发。
- **把 35 个模块摊到 `server/` 根下**：`server/` 根只放入口与少量宿主文件，摊平后入口、宿主、树混在一起，也破坏 [`tools/arch_policy.lua`](../../tools/arch_policy.lua) 里 `server.WorldHost` 的命名空间归属。
- **挪进 `server/packages/`**：包不属于业务范围（[ADR-0021](0021-packages-outside-business-scope.md)），会同时退出分层门禁与架构图。
