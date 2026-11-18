# 0022 引入 spoke 运行时：整包落位 `common/packages/spoke/`，本轮不接业务

**Status**: accepted

`spoke`（同级仓库 `../spoke`）是 Spoke C# 响应式运行时的 Lua 5.4 移植，纯 Lua 库交付：35 个文件，门面 `api.lua` 导出 13 个类（运行时层 `Epoch`/`Ticker`/`SpokeTree`/`Dock`/`LambdaEpoch`/`SpokeHandle`，响应式层 `Trigger`/`State`/`Effect`/`Reaction`/`Memo`/`Phase`/`EffectBuilder`）。它已按本仓布局落位（spoke ADR-0009），但本仓此前零引用。本 ADR 记录引入方式与边界。

决定：

- **落位 `common/packages/spoke/`**，模块前缀 `common.packages.spoke.`，消费方写 `require("common.packages.spoke.api")`。选择这里是因为 `deploy` 已经把三端 `packages/` 整棵镜像到宿主目录，落位即部署，不需要新增部署步骤。
- **传递形态是纯拷贝**：不挂 submodule，不做 subtree。整仓 subtree 会把上游仓根的 `docs/`、`tests/`、`AGENTS.md` 一并带进 `packages/`，而 deploy 会原样镜像进宿主目录；split 后再 subtree 则每次同步都要在上游检出里手工 `git subtree split`。纯拷贝的代价是同步靠人，因此把上游 commit SHA 记在[官方包接入参考](../packages-reference.md) 的「自研包」一节，一次同步记一个 SHA。
- **库与配套技能同源**：上游 `.agents/skills/spoke/` 破例复制进本仓 `.dsh/skills/spoke/`（`.gitignore` 的唯一例外条目），两者必须来自同一个上游 commit。副本原样引用、不就地改写：上游在 `19f1009` 已把技能改成面向消费方的写法（删掉 `testing.md` 与 `upstream-porting.md`，通篇不再出现「本仓」指代库仓库），只剩 `references/eggy-integration.md` 的「submodule 固定 SHA」一句不合本仓，由 `AGENTS.md` 的「按任务读取」一行覆盖。
- **不搬测试、不跑测试**：上游 22 个 `*_spec.lua` 不进本仓；`require` 链与基本行为由 `tests/probes/spoke_load.lua` 探针覆盖，`tests/probes/` 不在任何 `.busted` 车道内（见 `.busted`）。
- **不就地修改**这 35 个文件：要改回上游仓库改，再整体重新拷贝。
- **本轮业务零改动**，且不限制后续使用范围：13 个类全部开放，用哪几个、管哪一种生命周期由后续业务自行决定。

备选方案（拒绝）：

1. **submodule**：它的文件同样落在工作树里，门禁与探针都看得见，SHA 也由 git 自动记录——这一点比纯拷贝强。真正的成本在克隆与部署：少了 `--recurse-submodules` 就得到空目录，而这个库一缺整条 `require` 链就断，本仓协作者不止一种角色、不止一种工具链；子模块根还会多出一个 `.git` 指针文件，`deploy` 对 `<端>/<child>` 做无过滤字节镜像，会把它一起送进宿主目录。
2. **整仓 subtree 到 `common/packages/spoke/`**：上游仓根的 `docs/`、`tests/`、`AGENTS.md`、`.busted` 会一起进包，再经 deploy 进宿主目录。
3. **split 后 subtree**：可行，但每次同步要在上游检出里跑一次 split，机械成本抵不过收益。
4. **改写配套技能成本仓口径**：上游在数小时内连续更新该技能且仍有在途改动，改写等于本仓接手维护一份分叉。

后果：

- 本轮结束时，仓库里有一套没有调用方、也没有业务测试覆盖的库；「它能不能在宿主上加载」在跑过探针之前是未知的。下一轮的第一步是用它接管一处生命周期，而不是继续铺基础设施。
- 包不进架构图、不进质量指标（[ADR-0021](0021-packages-outside-business-scope.md)）；`tools/arch_policy.lua` 不需要改动，`common.packages` 的 L6 归属自动覆盖这 35 个文件。
- 上游继续演进时，库与技能要一起重拷并更新同一个 SHA；两者错版会出现「说明书说的和代码做的不一致」。