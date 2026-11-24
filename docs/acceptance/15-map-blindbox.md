# 15. 地图盲盒

> 本文件是《渔力全开》规格第 15 节的条款清单。格式与必填项见 [TEMPLATE.md](TEMPLATE.md)，小节索引见 [README.md](README.md)。

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 15-01 | 单抽 10 金豆、十连 90 金豆，取代历史的 10 金币与 90 金币结论（价目来自共享配置，占位支付通道按同一价目收费） | 规则 | agent | a | evidenced | tests/native/spec/15_blindbox_placeholder_settlement_test.lua |
| 15-02 | 奖池为 42 种极品鱼获，抽中即直接生成物品，不需要击杀对应鱼 | 规则 | agent | a | unverified | — |
| 15-03 | 奖池物品使用固定基础重量与固定价格，个体倍率恒为 1 | 规则 | agent | a | unverified | — |
| 15-04 | 生成物品优先入道具栏，其次入背包 | 规则 | agent | a | unverified | — |
| 15-05 | 道具栏与背包都满时，物品掉落在玩家面前，不被丢弃也不被吞掉 | 规则 | agent | a | unverified | — |
| 15-06 | 满格落地物品计入全区 200 件掉落预算 | 规则 | agent | a | unverified | — |
| 15-07 | 购买前明确告知满格会落地且其他玩家可拾取 | 规则 | agent | a | unverified | — |
| 15-08 | 不得以背包无限容量规避满格落地边界 | 契约 | agent | b | unverified | — |
| 15-09 | 连续 49 抽未出大奖时，第 50 抽强制保底（占位支付通道下同样生效，判定不因通道而变） | 规则 | agent | a | evidenced | tests/native/spec/15_blindbox_placeholder_settlement_test.lua |
| 15-10 | 保底在极品美人鱼与极品蛇颈龙之间等概率抽取 | 规则 | agent | a | evidenced | tests/native/spec/15_blindbox_placeholder_settlement_test.lua |
| 15-11 | 任意一抽出大奖立即把连续未中计数清零 | 规则 | agent | a | evidenced | tests/native/spec/15_blindbox_placeholder_settlement_test.lua |
| 15-12 | 十连按逐抽结算并逐抽存档，中途出大奖立即重置计数 | 契约 | agent | b | unverified | — |
| 15-13 | 奖池总权重为 1000，各条目的权重与基础售价按表逐行一致 | 规则 | agent | a | unverified | — |
| 15-14 | 不计保底时基础价格的期望为 166.075 金币，且不是随机倍率后的期望 | 规则 | agent | a | unverified | — |
| 15-15 | 已扣费的盲盒在恢复时按持久意图结算，不重复扣费、不重复发奖 | 契约 | agent | b | unverified | — |
| 15-16 | 落不下的奖品保留持久待交付记录，交付成功后才删除该记录 | 契约 | agent | b | unverified | — |
| 15-17 | 奖池每条奖品都对应物品表中的已有物品，不出现表外物品 | 规则 | agent | a | unverified | — |
| 15-21 | 金豆扣费在占位支付通道下走通扣费与发奖的对称结算，占位路径不发放真实付费权益；真实平台支付通道作为生产开关单列 | 契约 | agent | a | evidenced | tests/native/spec/15_blindbox_placeholder_settlement_test.lua |

## C 级（试玩取证）

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 15-18 | 满格落地物品出现在玩家面前的位置与拾取提示在试玩中可观察 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 15-19 | 购买前的满格提示在试玩中清晰可读 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 15-20 | 十连结果展示与会话中断后的补推在试玩中可见 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
