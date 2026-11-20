# 验收框架交接说明

> 给接手这个仓库的人。看完这一页，你应当知道三件事：矩阵满屏 `unverified` 是**正常状态**，下一步该从哪取活，以及证据等业务代码完成后怎么补。
>
> 规则以这四份文件为准，本文件只解释怎么用：[README.md](README.md)（矩阵入口与脚本生成的计数）、[TEMPLATE.md](TEMPLATE.md)（新增条款的唯一入口）、[证据分级](evidence-levels.md)（A/B/C 三档怎么判）、[遗留台账](legacy-ledger.md)（七张旧单的未完成项去向）；范围与延后理由见 [ADR-0027](../adr/0027-clause-matrix-as-sole-acceptance-surface.md)、[ADR-0028](../adr/0028-solo-clear-on-shared-world.md) 与 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md)（范围口径、生产开关台账）。
>
> 本文件与它们冲突时以它们为准，并且把冲突摆到台面上——不要默默按其中一边做。

## 一、这套东西是什么

**规格说「是什么」，矩阵说「验到哪一步」，证据说「凭什么说验到了」，门禁说「这本账还可信吗」。**

从规格到重跑是一条直路：`docs/GameSpec.md` 按 19 个小节写规格 → `docs/acceptance/` 一节一份分片，把每一句能独立判真假的规格写成一条**条款**（本轮 525 条），每条七列：ID、条款、组、执行者、证据等级、状态、证据·理由 → 状态只有五个值（`unverified`、`evidenced`、`accepted`、`blocked`、`out-of-scope`，最后一个本规格不用，见 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第一节）→ 证据分三档（A 走业务入口的黑盒断言、B 可重跑的时序探针、C 编辑器试玩）→ 已取证的行必须在证据列写一个**真实存在**的仓库相对路径，让人照着那一行就能重跑 → 整本账由 `lua tools/cli.lua acceptance --check` 机器核对，它随 fast 车道跑；红一格会让 `test fast` 变红，从而在 PR 的 required check 上拦住（本仓**没有**提交时自动检查，pre-commit hook 已按 ADR-0018 删除）。

| 层 | 落在哪 | 它回答 | 谁能改 |
| --- | --- | --- | --- |
| 规格 | `docs/GameSpec.md` | 这条规矩是什么 | 人；改完要同步分片 |
| 矩阵 | `docs/acceptance/NN-*.md` | 每条规矩验到哪一步 | 人按 [TEMPLATE.md](TEMPLATE.md) 增删条款行 |
| 索引 | `docs/acceptance/README.md` 的生成块 | 19 节的条数、状态分布、缺口密度 | **只由脚本写**，手改判红 |
| 覆盖表 | `docs/acceptance/coverage.md` | 每条非试玩条款的代码落点、关联测试与四类证据 | 人；已贯通小节逐节补齐 |
| 门禁 | `tools/acceptance.lua`、`tests/native/guards/acceptance_matrix_test.lua` | 这本账还可信吗 | 代码；随 fast 跑 |
| 基线 | `docs/acceptance/baseline.lua` | 两道棘轮的两端 | 只经 `--update-baseline`，单向 |

门禁一次核这些事：19 个规格小节各恰好一份分片、四列取值在封闭词表内、条款 ID 从 01 起连续不跳号、`blocked` 写了卡在谁、`out-of-scope` 写了理由、已取证行的每个路径真实存在、已取证且执行者为 agent 的行至少有一个 spec/probes 证据文件、且该文件正文写着这条条款的 ID（路径对了还要内容对）、`accepted` 行带人签署、条款文案里没有禁用措辞、索引生成块与分片一字不差，以及「规格与分片里都不出现工单编号」，还有覆盖表这一层：已贯通小节的非试玩条款必须登记、代码落点必须是真实存在的文件、等级与矩阵一致；再加两道单向棘轮（已取证只增、遗留测试只减）。禁用措辞清单与门禁判不了的那两条见 [TEMPLATE.md](TEMPLATE.md) 第六节。

## 二、从一条旧单的未完成项走到证据（实例路径）

台账里的来源是七张已关的旧单，去向是条款 ID。取 #46 的两条（都在 [legacy-ledger.md](legacy-ledger.md)）：一条落成 C 级，一条落成 B 级。两者走同一条路。

| 步 | 做什么 | C 级实例 | B 级实例 |
| --- | --- | --- | --- |
| 1 | 在台账找来源 | #46「收口 01 鱼塘通道与战斗空间缺口」 | #46「旧角色死亡时重复上述流程」 |
| 2 | 拿到条款 ID | [1-18](01-overview-and-scope.md) | [18-32](18-save-and-recovery.md) |
| 3 | 读四列 | 组=规则，执行者=试玩，等级=C，状态=`blocked` | 组=契约，执行者=agent，等级=B，状态=`unverified` |
| 4 | 判定需要什么证据 | 只有人在地图里能判：走得通、不卡住 | 状态机在时间轴上的行为：重进后绑到新角色 |
| 5 | 怎么取 | 编辑器试玩，一次会话覆盖第 1 节这一组 | 写可重跑的时序探针（现有 `tests/native/` 用例或专项探针） |
| 6 | 怎么重跑 | 同一会话复跑，并 `lua tools/cli.lua screenshot` 抓屏 | `lua tools/cli.lua test full` |
| 7 | 回填 | 状态改 `evidenced`，证据列写会话标识**与它在仓库里的落点** | 同左，路径写探针文件 |
| 8 | 收口 | `acceptance --check` 绿后 `acceptance --update-baseline` 抬基线 | 同左 |

第 7 步注一句：`evidenced` 行的证据列会被门禁当成路径解析，只认「带目录分隔符且末段带扩展名」的串（`tools/acceptance.lua` 的 `M.evidence_paths`）。所以 C 级条款转 `evidenced` 时，试玩会话标识必须同时落进仓库里的一个文件（例如会话记录或探针记录），否则判红。本轮还没有 C 级样本，这处口径尚未被样本验证。

## 三、满屏 `unverified` 是正常状态

当前盘面（2026-11-20，#249 落地后 `lua tools/cli.lua acceptance --check` 实测）：525 条条款，`unverified` 322、`evidenced` 147、`accepted` 0、`blocked` 56、`out-of-scope` 0。

这是**业务代码已贯通、证据按条款逐条补**的结果：

- 框架的完成判据是第七节的八条，其中**没有任何一条**是「矩阵里没有 `unverified`」。
- 321 条 `unverified` 是这份账的价值本身——它把「未知」写成了可数的行，让下一个人不必读代码去猜哪里没做完。
- 56 条 `blocked` **只剩一个原因**：全部是 C 级条款，要编辑器试玩才能取证；含随小队系统一并观察的界面可读性 9-23。试玩恢复后整批取证（#267）。外部依赖不再是阻塞理由——它们改记成 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 的生产开关，相应条款按占位口径取证。
- `out-of-scope` 归零：规格内没有永久出界（ADR-0029 第一节）。词表里保留这个值，但《渔力全开》的条款一律不用它。
- 147 条 `evidenced` 由 `tests/native/spec/` 的 28 份断言文件（合计 170 条用例）与两份可重跑探针支撑；覆盖表 19 个小节逐节登记代码落点与关联测试，未登记落点数为 0。门禁现在要求「证据文件正文必须出现该条款号」，路径对而文件里没条款号同样判红。
- 双棘轮基线已抬到 `evidenced 147 / legacyTests 142`；再往上只增不减。

什么时候才该紧张：`evidenced` 少于基线（门禁会先红）、或某条 `accepted` 没有「签署：@某人 日期」。**`evidenced` 也不等于业务上线**：它只等于「有一条能重跑的断言在守这句话」，要人背书才升 `accepted`。

## 四、三种证据怎么取、怎么补

三档说的是**怎么取证**，不是取证什么。它与 [ADR-0028](../adr/0028-solo-clear-on-shared-world.md) 的四类证据（正常流程、失败流程、退出重进、存档恢复）是两条正交的轴：四类管覆盖范围，三档管取证方式；一栏里的每条条款再按三档之一取证。**门禁型用例（只读仓库、挡不变量）不属于这三档**：它们放 `tests/native/guards/`，随 fast 与 full 跑、不计入遗留测试，用来挡住仓库不变量而不是取证条款。

### 4.1 A 级：走业务入口的黑盒断言

- 放 `tests/native/spec/`，跑 `lua tools/cli.lua test spec`；它随 `test full` 一并跑，不随 fast。
- 入口只有一个方向：从客户端请求进、从玩家能看见的地方出。经 `server/main.lua` 的 `MgrMap` 注册的管理器进入；断言落在回复载荷、服务端推送、世界里的对象、存档快照上。
- 引擎替身按被测系统自选，不是一律用 `tests/support/engine_double.lua`：那是现成的整份替身，适合要用到很多引擎服务的系统；像示范断言那样只碰少量成员的，内联几个假信号、假通道、假交互距离更直接。要的是「只经业务入口」，不是「必须用某个替身文件」。
- `server/main.lua` 本身**不能**在原生测试里执行（它在 `common/ZoneMarkers.lua` 那一步就要完整引擎服务）。示范断言的做法是：照 `MgrMap` 的接线手工装配被测管理器，再读 `server/main.lua` 的源码核对那几条接线确实存在——接线一改，断言先红，逼人回来复核断言。
- 不许断言「某个内部函数被调了几次」「某个私有字段恰好等于某个值」——那样钉住的是实现，重构就红，条款却没被判定。
- 补法：一条条款一个文件，文件名写条款 ID，文件头两行用中文写清「对应哪条条款」和「先列后写的失败方式」，再写一条能独立判真的断言。
- 示范：[7-11](07-economy-and-shop.md) ↔ `tests/native/spec/07_shop_purchase_limit_test.lua`（两条断言：上限 1 的商品买第二次被拒且不再扣金币；上限 0 的商品不限购）。

### 4.2 B 级：可重跑的时序探针

- 判的是单次快照看不出来的行为：重连、迟到回调、超时、并发争抢、幂等与 fencing、恢复路径。
- 必须可重跑：证据列写清跑哪条命令、看哪个断言；「我连着点了两下，看着没问题」不算。
- 落点：现有 `tests/native/` 用例（在 slow 车道则随 full 跑）或专项探针；`tests/probes/` 的手工探针不入任何车道，不能单独充当证据。
- 重跑：`lua tools/cli.lua test full`。

### 4.3 C 级：编辑器试玩

- 判的是只有人在地图里才能判的性质：贴地、净空、遮挡、可读性、手感、操作距离、整体旅程。
- 组织方式：按**会话**，一次覆盖一节或一组强相关节；零散抓单条既费事又不可比。
- 本轮状态：C 级条款一律 `blocked`，理由写「卡在：需编辑器试玩取证（业务代码完成后整批进行）」；9-23（队伍界面可读性）随小队系统排期，同一理由里注明「队伍界面随小队系统排期后同一会话覆盖 9-20…9-23」。规格内没有 `out-of-scope` 的 C 级条款（ADR-0029 第一节）。
- 取证后：会话记录落成仓库文件（`evidence/<日期>-<会话号>/session.md`，含抓屏清单与观察结论），证据列写 `该文件路径（会话 <会话号>）`。门禁只认真实存在的仓库路径，纯会话标识会被判 `evidence_missing`——这不是放宽门禁，是让 C 级证据也能被核。抓屏走 `lua tools/cli.lua screenshot`，取帧前先 `--info` 判显示路径、连拍比 md5 判帧新旧。

### 4.4 覆盖表管落点，不管证据

- [实现覆盖表](coverage.md)回答的是「这条条款由哪段代码负责、有没有测试守着」，八列：条款、代码落点、关联测试、四类证据、等级。
- 它**不是证据**：`关联测试` 是实现自检，条款转 `evidenced` 仍然只认矩阵证据列里那条走业务入口的断言。
- 空落点、落点或测试路径不存在、条款 ID 不在矩阵里、等级与矩阵不一致，都让 `acceptance --check` 与 `test fast` 判红。已贯通小节由 `tools/acceptance.lua` 的 `M.COVERAGE_SECTIONS` 声明，逐节扩大；扩一节就要补齐该节落点。
- 真实渠道事项不在这张表里，也不在矩阵里：它们进 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第四节的生产开关台账，缺位时用占位参数或本地夹具走通流程，**占位不发放真实付费权益**。

### 4.5 哪一种证据不能冒充哪一种

| 这个 | 不能当 | 为什么 |
| --- | --- | --- |
| 跑通 `tests/native/` 的旧测试 | 条款证据 | 九成是实现自检、没有条款 ID；它们通过只说明实现没坏，不说明规矩成立 |
| 单次快照（一张截图、一段日志、一次成功） | B 级 | 判不出重连、迟到回调、超时与争抢；不可重跑就不是 B |
| 编辑器内模拟平台回调成功 | 平台条款验收 | 真实平台结论只能在真实平台取；这类条款按适配层口径记 `unverified`，真实渠道结论单列进 ADR-0029 的生产开关台账 |
| 一处满足（一条分支、一个鱼种、一次成功） | 整条要求 | 条款写的是「谁在什么条件下做什么」，条件没覆盖完就不成立；该拆就拆，别拿一处充数 |
| 写完了、代码看过了、PR 合了 | 取证 | 那是「做完了」，不是「验证过了」 |
| 证据指向临时文件、仓库外路径或已删文件 | 真实证据 | 门禁判红：`evidenced` 的每个路径都必须在仓库里存在 |
| A 级断言 | C 级 | 自动化断言说不了「贴地、遮挡、手感」；只能 C 级的条款被标成 A 是评审要拦的事，机器拦不住 |

## 五、日常怎么用

```bash
lua tools/cli.lua acceptance --check           # 看红在哪（test fast 也会跑同一份判定）
lua tools/cli.lua acceptance --write           # 改了条款后刷新索引生成块（幂等）
lua tools/cli.lua test spec                    # 只跑条款断言
lua tools/cli.lua test fast                    # 日常车道（含矩阵门禁）
lua tools/cli.lua test full                    # 收尾车道 = fast + slow + spec
lua tools/cli.lua acceptance --update-baseline # 证据变多后抬基线（单向）
```

节奏四条：

1. **新增条款**：先改 `docs/GameSpec.md` 的小节（规格是本体），再按 [TEMPLATE.md](TEMPLATE.md) 在对应分片登记一行，新条款一律 `unverified`；登记完跑 `acceptance --write`，否则 `index_stale` 判红。若该节已贯通（在 `M.COVERAGE_SECTIONS` 里），同时在 [实现覆盖表](coverage.md) 补一行代码落点，否则 `coverage_clause_missing` 判红。
2. **补证据**：写断言或探针 → 跑 `test spec` 或 `test full` → 状态改 `evidenced`、证据列填真实路径 → `acceptance --check` 绿 → `acceptance --update-baseline`。基线只许 `evidenced` 抬、`legacyTests` 降，反方向 `--update-baseline` 直接退 2 拒绝。
3. **四车道**：`fast`（日常，`tests/native` 顶层）、`full`（收尾，加 `slow` 与 `spec`）、`spec`（条款断言）、`art`（美术，optional，不进 full）。`default` 与 `full` 相同。车道定义只看根目录 `.busted`。
4. **入口只有一个**：矩阵。工单、聊天、临时文档里记一笔不算登记——没进矩阵的活等于没有。

## 六、延后范围（与 ADR-0027 逐字一致）

> 本节说的是**批次延后**，不是条款出界：规格内没有永久出界（[ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md) 第一节）。9-19～9-23 随 E 批次（多人规则组）恢复排期，条款状态已是 `unverified`（9-23 为 `blocked`），不是 `out-of-scope`。

下列内容本轮不做，**不是放弃**。范围与恢复条件逐字取自 [ADR-0027](../adr/0027-clause-matrix-as-sole-acceptance-surface.md) 的「后果」一节，本文件不增不减：

> **延后的批次与恢复条件**（与 #240 的批次表一致）：
>   - **D 通关取证**、**E 多人规则组**、**F A 级断言铺开**、**G B 级探针补齐**、**H 旧测试清账**。
>   - 恢复条件：D/E 等业务代码（第 12–16 节与多人接缝）合入集成分支、接口稳定之后启动；F 与 G 按分片逐节推进，每转一条 `evidenced` 都顺手抬一次基线；H 与新证据同步进行——只有删掉一条遗留测试才能把 `legacyTests` 降一格。

同一份 ADR 的「本轮只建框架」口径也照抄：框架阶段只把**真实条款**转成 `evidenced`（先是 `7-11` 商店限购，本轮又有 `1-12` 适配层失败路径），作为「框架能拦人、断言能落地」的样板；其余条款保持 `unverified` / `blocked`。

两处口径是否还一致，用一条命令自查：

```bash
rg -n 'D 通关取证|恢复条件：D/E' docs/adr/0027-*.md docs/acceptance/handover.md
```

两侧都应命中同一串字。若有人改了 ADR 的批次表而没改这里（或反过来），先修这里，并把差异说明写进提交。

## 七、八条完成判据核对表

判据原文照抄 #240「完成判据」一节，未作改写。证据列是可重跑命令或真实文件；结果列以 2026-11-20 在 `fix/249-review-spec` worktree（Windows，Lua 5.4.6）的实测为准，与第三节「满屏 `unverified` 是正常状态」的当前盘面取自同一次 `acceptance --check` 输出；标「历史取样」的是一次性判红实验，数字不代表现状。

| 判据（#240 原文） | 证据（可重跑） | 结果 |
| --- | --- | --- |
| 1. 19 个规格小节各有一份条款分片，条款 ID 稳定可引用。 | `ls docs/acceptance/[0-9][0-9]-*.md \| wc -l`；`lua tools/cli.lua acceptance --check`；`tests/native/guards/acceptance_matrix_test.lua` 的「真实矩阵恰好覆盖规格的 19 个小节，节号连续」 | 19；`--check` 输出「19 份分片 / 525 条条款」并以「验收矩阵校验通过」退 0；ID 从 01 连续由 `id_sequence` 规则守着 |
| 2. 索引页的计数与缺口密度由脚本生成且与分片一致；手改索引会被门禁判红。 | `lua tools/cli.lua acceptance --write` 连跑两次并比对 README；手改 README 合计行的数字 | 两次都输出「README 生成块已是最新，无需改动」且零差异（幂等）；手改后判红 `[index_stale]`（历史取样：`test fast` 1581 successes / 1 failure，数字不代表现状） |
| 3. 规格全篇无工单编号，且这条由门禁守着，不靠人记。 | `rg -n '#[0-9]+' docs/GameSpec.md`（无输出即通过）；往 GameSpec 正文塞一个 `#123` | 无输出（rg 退 1）；塞入后判红 `[spec_issue_ref] docs/GameSpec.md:8 规格不得出现工单编号 #123`，`test fast` 1581/1；分片里塞 `工单46` 同样判红（`docs/acceptance/09-multiplayer-rules.md:3`）（历史取样：当时的 `test fast` 1581 successes / 1 failure） |
| 4. 五状态词汇生效；blocked 必须写明卡在谁、out-of-scope 必须写明理由，缺了就判红。 | 删掉 1-15 的「卡在：」；在夹具里删掉 out-of-scope 行的「理由：」；把 5-01 的状态改成 `done`；三者各跑一次 `--check` | 分别判红 `[blocked_reason]`（9-04）、`[out_of_scope_reason]`（夹具）、`[vocabulary]`（5-01 取值 "done"）；`test fast` 各 1 failure |
| 5. evidenced 指向的证据路径必须真实存在。 | 把 7-11 的证据路径改成 `tests/native/spec/07_shop_purchase_limit_gone_test.lua` | 判红 `[evidence_missing] docs/acceptance/07-economy-and-shop.md:17 7-11 的证据路径不存在`（历史取样：当时 `test fast` 1581/1）；还原后恢复绿 |
| 6. 双棘轮有基线文件：已取证计数下降、或遗留测试计数上升，都让日常车道变红。 | `docs/acceptance/baseline.lua`（现状 `evidenced = 147`、`legacyTests = 138`）；`lua tools/cli.lua acceptance --check`；反向 `acceptance --update-baseline` | 现状基线 `evidenced = 147 / legacyTests = 138`，，与第三节当前盘面同一次 `--check` 输出；反向 `--update-baseline` 退 2：「已取证 147 条 < 基线 148 条：棘轮只许增，拒绝下调」。（历史取样：把 evidenced 抬高一条或把 legacyTests 压低一个，`--check` 各判红一次 `[ratchet_evidenced]` / `[ratchet_legacy]`。） |
| 7. spec 车道随 full 运行，且至少有一条真实条款通过它转成 evidenced。 | `lua tools/cli.lua test spec`（现状：28 个文件 / 170 条用例）；`lua tools/cli.lua test full`；7-11、1-12 与 19-13 的条款行 | spec 车道 170 successes / 0 failures / 0 errors（28 个 `tests/native/spec/` 文件）；矩阵里 7-11 为 `evidenced`、证据 `tests/native/spec/07_shop_purchase_limit_test.lua`，1-12 为 `evidenced`、证据 `tests/native/spec/01_platform_adapter_failure_test.lua`，19-13 为 `evidenced`、证据 `tests/native/spec/17_platform_boundary_placeholder_test.lua`。（历史取样：`test full -- --filter='条款 7%-11'` 命中 7-11 的 2 条，证明 full 收录 spec。） |
| 8. ADR、五个术语、证据分级口径、新增条款的受控入口均有明确真源。 | [ADR-0027](../adr/0027-clause-matrix-as-sole-acceptance-surface.md)「决定」、[ADR-0028](../adr/0028-solo-clear-on-shared-world.md) 与 [ADR-0029](../adr/0029-scope-completeness-and-placeholder-first.md)；范围口径与生产开关台账见 ADR-0029，实现覆盖表见 [coverage.md](coverage.md)；条款 / 验收矩阵见 [README.md](README.md) 开头和 [TEMPLATE.md](TEMPLATE.md) 第一、三节；棘轮见 ADR-0027「决定」第 4 条及 [workflow.md](../agents/workflow.md)「工具链」的 `acceptance` 条；取证 / 证据分级见 [evidence-levels.md](evidence-levels.md) 第一、五节；新增条款入口见 TEMPLATE 第一节 | 上述文件与小节均在；2026-11-20 实跑 `lua tools/cli.lua acceptance --check` 退 0，输出「19 份分片 / 525 条条款」「验收矩阵校验通过」；该命令核矩阵，不检查上述文档存在性 |

八条全绿。附带事实：`gh issue list -R qinyuanj/se-fish --state open` 只剩 #240（总单）与 #245（本单）；七张旧单（#239、#172、#171、#46、#44、#42、#14）均已关闭，未完成项在 [legacy-ledger.md](legacy-ledger.md) 里逐条有去向。

## 八、文档可达性

- `AGENTS.md` 的「按任务读取」有一条「验收与条款」，第一步就指向 [README.md](README.md)。
- 从 [docs/agents/domain.md](../agents/domain.md) 出发两步可达：domain.md → [开发工作流](../agents/workflow.md) → 本文矩阵入口；`workflow.md` 的「工具链」同时列了 `acceptance` 子命令与四条车道。
- 反向也通：条款 → 规格小节（分片文件名与小节号一一对应），已关旧单的未完成项 → 条款 ID（台账），条款 ID → 证据（证据列），证据 → 命令（A 级 `test spec`、B 级 `test full`、C 级试玩会话）。

## 九、这份说明怎么维护

- 改口径先改上游：范围改 ADR-0027、写法改 TEMPLATE、分级改 evidence-levels，最后才回来改本文。
- 本文不含手写计数：文中数字均摘自 `lua tools/cli.lua acceptance --check` 的输出（取样日期 2026-11-20）；再引用时注明新的取样日期。
- 第八节的判据表是框架的验收凭据，改它之前先跑表里的命令——对不上就是有人在绕过门禁。
