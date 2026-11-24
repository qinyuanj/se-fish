# 验收框架交接说明

> 给接手这个仓库的人。看完这一页，你应当知道三件事：矩阵满屏 `unverified` 是**正常状态**，下一步该从哪取活，以及证据怎么补。
>
> 规则以这四份文件为准，本文件只解释怎么用：[README.md](README.md)（入口与脚本生成的计数）、[TEMPLATE.md](TEMPLATE.md)（新增条款的唯一入口）、[证据分级](evidence-levels.md)（A/B/C 三档怎么判）、[遗留台账](legacy-ledger.md)（七张旧单的未完成项去向）；范围与延后理由见 [ADR-0027](../adr/0027-clause-matrix-as-sole-acceptance-surface.md)、[ADR-0028](../adr/0028-solo-clear-on-shared-world.md)、[ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 与 [ADR-0039](../adr/0039-acceptance-surface-as-feature-files.md)（验收面收敛为功能文件）。
>
> 本文件与它们冲突时以它们为准，并且把冲突摆到台面上——不要默默按其中一边做。

## 一、这套东西是什么

**规格说「是什么」，分片说「验到哪一步」，证据说「凭什么说验到了」，门禁说「这本账还可信吗」。**

从规格到重跑是一条直路：`docs/GameSpec.md` 按 19 个小节写规格 → `docs/acceptance/` 一节一份分片，把每一句能独立判真假的规格写成一条**条款**（本轮 525 条），每行只有两格：ID 与文案，证据等级写成文案末尾的 `（A）`、`（B）` 或 `（C）` → 状态不写：A/B 级看 `tests/native/spec/` 与 `tests/probes/` 的正文有没有这条条款号，C 级看 `evidence/*/session.md` 的 `✅` 行 → 整本账由 `lua tools/cli.lua acceptance --check` 机器核对，它随 fast 车道跑；红一格会让 `test fast` 变红，从而在 PR 的 required check 上拦住。

| 层 | 落在哪 | 它回答 | 谁能改 |
| --- | --- | --- | --- |
| 规格 | `docs/GameSpec.md` | 这条规矩是什么 | 人；改完要同步分片 |
| 分片 | `docs/acceptance/NN-*.md` | 每条规矩验到哪一步、从哪个入口走、怎么驱动 | 人按 [TEMPLATE.md](TEMPLATE.md) 增删条款行 |
| 证据 | `tests/native/spec/`、`tests/probes/`、`evidence/*/session.md` | 凭什么说验到了 | 写断言或试玩会话记录 |
| 索引 | `docs/acceptance/README.md` 的生成块 | 19 节的条数与反推状态 | **只由脚本写**，手改判红 |
| 门禁 | `tools/acceptance.lua`、`tests/native/guards/acceptance_matrix_test.lua` | 这本账还可信吗 | 代码；随 fast 跑 |
| 基线 | `docs/acceptance/baseline.lua` | 已取证棘轮的一端 | 只经 `--update-baseline`，单向 |

门禁一次核五项：19 个规格小节各恰好一份分片、条款 ID 从 01 起连续不跳号、证据等级后缀合法、条款文案里没有禁用措辞、索引生成块与分片一字不差、证据文件不引用矩阵里没有的条款号，以及已取证条款数不低于基线。禁用措辞清单与门禁判不了的两条见 [TEMPLATE.md](TEMPLATE.md) 第六节。

## 二、从一条条款走到证据（实例路径）

取 #46 的两条（都在 [legacy-ledger.md](legacy-ledger.md)）：一条落成 C 级，一条落成 B 级。两者走同一条路。

| 步 | 做什么 | C 级实例 | B 级实例 |
| --- | --- | --- | --- |
| 1 | 在台账找来源 | #46「收口 01 鱼塘通道与战斗空间缺口」 | #46「旧角色死亡时重复上述流程」 |
| 2 | 拿到条款 ID | [1-18](01-overview-and-scope.md) | [18-32](18-save-and-recovery.md) |
| 3 | 读等级后缀 | `（C）`，只能试玩观察 | `（B）`，时序探针 |
| 4 | 怎么取 | 编辑器试玩，一次会话覆盖第 1 节这一组 | 写可重跑的时序探针（现有 `tests/native/` 用例或专项探针） |
| 5 | 怎么重跑 | 同一会话复跑，并 `lua tools/cli.lua screenshot` 抓屏 | `lua tools/cli.lua test full` |
| 6 | 怎么回填 | 会话记录写进 `evidence/<日期>-<会话号>/session.md`，对照表该条标 `✅` | 断言正文写上条款号 |
| 7 | 收口 | `acceptance --check` 绿后 `acceptance --update-baseline` 抬基线 | 同左 |

回填不需要改分片：状态由 `tools/acceptance.lua` 的 `M.infer` 反推。会话记录必须是仓库里的文件，抓屏清单与观察结论都写进去；抓屏走 `lua tools/cli.lua screenshot`。

## 三、三种证据怎么取、怎么补

三档说的是**怎么取证**，不是取证什么。它与 [ADR-0028](../adr/0028-solo-clear-on-shared-world.md) 的四类证据（正常流程、失败流程、退出重进、存档恢复）是两条正交的轴：四类管覆盖范围，三档管取证方式。**门禁型用例（只读仓库、挡不变量）不属于这三档**：它们放 `tests/native/guards/`，随 fast 与 full 跑，用来挡住仓库不变量而不是取证条款。

### 3.1 A 级：走业务入口的黑盒断言

- 放 `tests/native/spec/`，跑 `lua tools/cli.lua test spec`；它随 `test full` 一并跑，不随 fast。
- 入口只有一个方向：从客户端请求进、从玩家能看见的地方出。经 `server/main.lua` 组合的宿主服务或 `ServerRuntime` 公开入口进入；断言落在回复载荷、服务端推送、世界里的对象、存档快照上。
- 引擎替身按被测系统自选，不是一律用 `tests/support/engine_double.lua`：那是现成的整份替身，适合要用到很多引擎服务的系统；像示范断言那样只碰少量成员的，内联几个假信号、假通道、假交互距离更直接。要的是「只经业务入口」，不是「必须用某个替身文件」。
- 不许断言「某个内部函数被调了几次」「某个私有字段恰好等于某个值」——那样钉住的是实现，重构就红，条款却没被判定。
- 补法：一条条款一个文件，文件名写条款 ID，文件头两行用中文写清「对应哪条条款」和「先列后写的失败方式」，再写一条能独立判真的断言。正文里必须出现条款号，否则反推不会把这条算成取证。

### 3.2 B 级：可重跑的时序探针

- 判的是单次快照看不出来的行为：重连、迟到回调、超时、并发争抢、幂等与 fencing、恢复路径。
- 必须可重跑：证据写清跑哪条命令、看哪个断言；「我连着点了两下，看着没问题」不算。
- 落点：现有 `tests/native/` 用例（在 slow 车道则随 full 跑）或 `tests/probes/` 的专项探针。`tests/probes/` 的手工探针不入任何车道，需要时单独跑。
- 重跑：`lua tools/cli.lua test full`。

### 3.3 C 级：编辑器试玩

- 判的是只有人在地图里才能判的性质：贴地、净空、遮挡、可读性、手感、操作距离、整体旅程。
- 组织方式：按**会话**，一次覆盖一节或一组强相关节；零散抓单条既费事又不可比。
- 本轮状态：C 级条款一律 `blocked`（反推结果，不手写）。取证后，会话记录落成仓库文件（`evidence/<日期>-<会话号>/session.md`，含抓屏清单与观察结论），在对照表里把该条标 `✅`。
- 反推只认 `✅`：`⏸`（未覆盖）、`⚠️`（部分观察）、`⛔`（观察到不符）都不算取证。

### 3.4 哪一种证据不能冒充哪一种

| 这个 | 不能当 | 为什么 |
| --- | --- | --- |
| 跑通 `tests/native/` 的旧测试 | 条款证据 | 九成是实现自检、没有条款 ID；它们通过只说明实现没坏，不说明规矩成立 |
| 单次快照（一张截图、一段日志、一次成功） | B 级 | 判不出重连、迟到回调、超时与争抢；不可重跑就不是 B |
| 编辑器内模拟平台回调成功 | 平台条款验收 | 真实平台结论只能在真实平台取；这类条款按适配层口径记 `unverified`，真实渠道结论单列进 ADR-0029 的生产开关台账 |
| 一处满足（一条分支、一个鱼种、一次成功） | 整条要求 | 条款写的是「谁在什么条件下做什么」，条件没覆盖完就不成立；该拆就拆，别拿一处充数 |
| 写完了、代码看过了、PR 合了 | 取证 | 那是「做完了」，不是「验证过了」 |
| 证据文件只在注释里提到条款号 | 取证 | 那是引用，不是断言；在 `M.INFER_EXCEPTIONS` 里显式登记，不靠文案绕过 |
| A 级断言 | C 级 | 自动化断言说不了「贴地、遮挡、手感」；只能 C 级的条款被标成 A 是评审要拦的事，机器拦不住 |

## 四、日常怎么用

```bash
lua tools/cli.lua acceptance --check           # 看红在哪（test fast 也会跑同一份判定）
lua tools/cli.lua acceptance --infer           # 列出反推出的状态、证据路径与孤儿条款号
lua tools/cli.lua acceptance --write           # 改了条款后刷新索引生成块（幂等）
lua tools/cli.lua test spec                    # 只跑条款断言
lua tools/cli.lua test fast                    # 日常车道（含矩阵门禁）
lua tools/cli.lua test full                    # 收尾车道 = fast + slow + spec
lua tools/cli.lua acceptance --update-baseline # 证据变多后抬基线（单向）
```

节奏四条：

1. **新增条款**：先改 `docs/GameSpec.md` 的小节（规格是本体），再按 [TEMPLATE.md](TEMPLATE.md) 在对应分片登记一行，写清等级后缀，新条款默认 `unverified`；登记完跑 `acceptance --write`，否则 `index_stale` 判红。
2. **补证据**：写断言或探针、让正文出现条款号，或在试玩会话记录里标 `✅`；跑 `test spec` 或 `test full`；`acceptance --check` 绿后 `acceptance --update-baseline`。基线只许 `evidenced` 抬，反向 `--update-baseline` 直接退 2 拒绝。
3. **四车道**：`fast`（日常，`tests/native` 顶层）、`full`（收尾，加 `slow` 与 `spec`）、`spec`（条款断言）、`art`（美术，optional，不进 full）。`default` 与 `full` 相同。车道定义只看根目录 `.busted`。
4. **入口只有一个**：分片。工单、聊天、临时文档里记一笔不算登记——没进分片的活等于没有。

## 五、延后范围

> 本节说的是**批次延后**，不是条款出界：规格内没有永久出界（[ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第一节）。9-19～9-23 随 E 批次（多人规则组）恢复排期，不是出界。

下列内容本轮不做，**不是放弃**。范围与恢复条件取自 [ADR-0027](../adr/0027-clause-matrix-as-sole-acceptance-surface.md) 的「后果」一节：

> **延后的批次与恢复条件**（与 #240 的批次表一致）：
>   - **D 通关取证**、**E 多人规则组**、**F A 级断言铺开**、**G B 级探针补齐**、**H 旧测试清账**。
>   - 恢复条件：D/E 等业务代码（第 12–16 节与多人接缝）合入集成分支、接口稳定之后启动；F 与 G 按分片逐节推进，每转一条 `evidenced` 都顺手抬一次基线；H 与新证据同步进行。

两条口径是否还一致，用一条命令自查：

```bash
grep -n 'D 通关取证\|恢复条件：D/E' docs/adr/0027-*.md docs/acceptance/handover.md
```

两侧都应命中同一串字。若有人改了 ADR 的批次表而没改这里（或反过来），先修这里，并把差异说明写进提交。

## 六、文档可达性

- `AGENTS.md` 的「按任务读取」有一条「验收与条款」，第一步就指向 [README.md](README.md)。
- 从 [docs/agents/domain.md](../agents/domain.md) 出发两步可达：domain.md → [开发工作流](../agents/workflow.md) → 本文矩阵入口；`workflow.md` 的「工具链」同时列了 `acceptance` 子命令与四条车道。
- 反向也通：条款 → 规格小节（分片文件名与小节号一一对应），已关旧单的未完成项 → 条款 ID（台账），条款 ID → 证据（`M.infer` 的反推结果，`acceptance --infer` 可直接看），证据 → 命令（A 级 `test spec`、B 级 `test full`、C 级试玩会话）。

## 七、这份说明怎么维护

- 改口径先改上游：范围改 ADR-0027 与 ADR-0039、写法改 TEMPLATE、分级改 evidence-levels，最后才回来改本文。
- 本文不含手写计数：矩阵数字摘自 `lua tools/cli.lua acceptance --check` 的输出（取样日期 2026-11-24）；再引用时注明新的取样日期。
