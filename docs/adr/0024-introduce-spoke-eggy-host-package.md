# 0024 引入 spoke_eggy 宿主包：独立成包，依赖单向

**Status**: accepted

上游 spoke 在 `4d10e907`（2026-11-19）新增 `common/packages/spoke_eggy/api.lua`：SE（世界编辑器）宿主层，把树的生命周期绑到 `Unit.Destroying`（先翻 `is_alive` 再 detach）、给树注入带树名前缀的 logger、暴露 `State<boolean> is_alive`。边界与形状由上游 ADR-0011（SE 是唯一宿主）与 ADR-0012（宿主包在核心包之外）定稿，`is_alive` 的边界由上游 issue #28 的真机关局探针改写。本仓核心包此前零业务引用，本 ADR 记录引入宿主包的方式与边界。

决定：

- **整包复制** `common/packages/spoke_eggy/api.lua`（单文件），落位 `common/packages/spoke_eggy/`，门面 `require("common.packages.spoke_eggy.api")`。它与 `spoke` 同源同 SHA，`deploy` 镜像三端 `packages/` 整棵，落位即部署，不新增部署步骤。
- **不进核心包**：它不是 `spoke/api.lua` 的 13 类之一，核心包零宿主依赖，两包平级不嵌套。
- **依赖单向**：`spoke_eggy` 只 require `common.packages.spoke.api` 与 `common.packages.spoke.runtime.spoke_error`；核心不 require 宿主包。架构门禁不额外写规则：两包同属 L0 `common.packages`，反向依赖在门禁眼里同层；方向由包内注释与评审守。
- **不搬宿主测试**：上游 `tests/host/spoke_eggy_spec.lua` 不进本仓；落位、Auto 首帧同步、Destroying 顺序、dispose 幂等与「不读宿主全局」由 `tests/probes/spoke_eggy_load.lua` 探针覆盖，`tests/probes/` 不入任何 `.busted` 车道，与 [ADR-0022](0022-introduce-spoke-runtime.md) 的口径一致。
- **不就地修改**包内文件；要改回上游改，再整体重拷。

备选方案（拒绝）：

1. **并进核心包 `common/packages/spoke/host/`**：上游 ADR-0012 已否——部署是整目录字节镜像，进包就进每个消费方的目录；核心包的「零宿主依赖」也会当场作废。
2. **搬上游 spec 进 `tests/native/`**：与 [ADR-0022](0022-introduce-spoke-runtime.md)「不搬测试、不跑测试」冲突，且会为本仓引入一条只服务包的车道。
3. **等业务需要时再拷**：宿主包是消费方写面板或实体的第一层装配，引入不改变业务零引用的现状，但能把包位、依赖方向与加载探针一次定清。

后果：

- 业务首次引用时，`deploy` 把 `common/packages/spoke_eggy/` 与 `common/packages/spoke/` 一起镜像进宿主；不用宿主包就只镜像核心包，它是可选依赖。
- `is_alive` 只覆盖显式销毁（含级连），不覆盖关局：关局不触发 `Destroying`，没有回调可翻它（上游 issue #28 实测）。
- 包不进架构图与质量工具：[ADR-0021](0021-packages-outside-business-scope.md) 的目录级排除覆盖新包，`policy.edn` 与 `uml-quality.json` 不需要改动。
