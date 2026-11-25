# 0022 引入 spoke 与 spoke_eggy：纯拷贝落位，宿主包独立且依赖单向

**Status**: accepted（合并原 ADR-0024）

`spoke`（上游仓库 `../spoke`）是 Spoke 响应式运行时的 Lua 5.4 纯 Lua 移植，配套 `spoke_eggy` 为 SE（世界编辑器）宿主层，将树生命周期绑到 `Unit.Destroying`（先翻 `is_alive` 再 detach）并注入带树名前缀的 logger。本 ADR 记录两包的引入方式与边界。

## 决定

- **纯拷贝落位 `common/packages/`**：
  - 核心包落 `common/packages/spoke/`（门面 `require("common.packages.spoke.api")`，零宿主依赖）；
  - 宿主包落 `common/packages/spoke_eggy/`（门面 `require("common.packages.spoke_eggy.api")`，与核心平级不嵌套）。
  - `deploy` 整棵镜像三端 `packages/`，落位即部署，不新增部署步骤。
- **依赖单向**：`spoke_eggy` 只 `require` `common.packages.spoke.*`；核心包不得反向 `require` 宿主包（两包同属 L6，方向由评审与包内注释守）。
- **同源同 SHA、不就地修改**：核心包、宿主包与配套技能（`.dsh/skills/spoke/`，`.gitignore` 唯一例外）必须来自同一个上游 commit，SHA 记账在[官方包接入参考](../packages-reference.md)「自研包」一节。要改回上游仓改，再整体重拷，不在本仓改写库或技能。
- **不搬上游测试**：上游 `*_spec.lua` 不进本仓；加载与宿主契约由 `tests/probes/spoke_load.lua` 与 `tests/probes/spoke_eggy_load.lua` 探针覆盖（不入 `.busted` 车道）。

## 拒绝的方案

1. **git submodule**：缺 `--recurse-submodules` 会得到空目录导致整条 `require` 链断裂，且子模块 `.git` 指针会被 `deploy` 无过滤镜像进宿主。
2. **git subtree**：整仓 subtree 会把上游 `docs/`、`tests/` 带进宿主；split 后 subtree 每次同步机械成本过高。
3. **将 `spoke_eggy` 并入 `common/packages/spoke/host/`**：破坏核心包零宿主依赖边界。
4. **改写上游技能或搬运上游 spec**：等于在本仓维护分叉，并引入只服务包的测试车道。

## 后果

- 同步升级时须将核心包、宿主包与 `.dsh/skills/spoke/` 一起重拷并更新同一个 SHA，避免说明书与代码错版。
- `spoke_eggy` 的 `is_alive` 只覆盖显式销毁（含级联），**不覆盖关局**（SE 关局不触发 `Destroying`）。
- 两包随 `common/packages/` 自动退出架构图与质量度量（[ADR-0021](0021-packages-outside-business-scope.md)），并保留在分层门禁 L6。
