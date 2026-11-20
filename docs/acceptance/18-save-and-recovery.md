# 18. 存档与恢复契约

> 本文件是《渔力全开》规格第 18 节的条款清单。格式与必填项见 [TEMPLATE.md](TEMPLATE.md)，小节索引见 [README.md](README.md)。

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 18-01 | 存档保存金币与全部库存条目 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/save_test.lua |
| 18-02 | 存档保存每件物品的实例倍率与烤制状态 | 契约 | agent | B | evidenced | tests/native/save_test.lua、tests/native/grill_test.lua |
| 18-03 | 存档保存装备选择与武器弹匣状态 | 契约 | agent | B | unverified | — |
| 18-04 | 存档保存升级次数、购买次数与药水使用次数 | 契约 | agent | B | evidenced | tests/native/economy_persistence_test.lua |
| 18-05 | 存档保存血量、饥饿值与虚弱剩余时间 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/survival_test.lua |
| 18-06 | 存档保存濒死标记与死亡标记 | 契约 | agent | B | evidenced | tests/native/survival_test.lua |
| 18-07 | 存档保存图鉴中的个人重量记录 | 契约 | agent | B | evidenced | tests/native/compendium_test.lua、tests/native/records_test.lua |
| 18-08 | 存档保存任务进度与剧情已读记录 | 契约 | agent | B | evidenced | tests/native/player_leave_rejoin_test.lua |
| 18-09 | 存档保存到达集合（已实际到达过的航线记录集合） | 契约 | agent | B | evidenced | tests/native/ferry_test.lua |
| 18-10 | 存档保存当前钓鱼区与安全落点 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-11 | 存档保存盲盒保底计数 | 契约 | agent | B | evidenced | tests/native/blindbox_settle_test.lua |
| 18-12 | 存档保存成就及其进度 | 契约 | agent | B | evidenced | tests/native/achievement_delivery_test.lua、tests/native/compendium_test.lua |
| 18-13 | 存档保存尚未结算的操作，重进后据此恢复结算 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua、tests/native/ferry_test.lua |
| 18-14 | 换弹、施法等临时动作在重进后不续播 | 契约 | agent | B | unverified | — |
| 18-15 | 重新连接后弹药消耗与冷却限制继续生效，不能靠重连绕过 | 契约 | agent | B | evidenced | tests/native/weapon_system_test.lua |
| 18-16 | v1 旧档加载后升级为新版结构，且保留已有财产 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-17 | v1 档升级时，新增字段按明确默认值填充 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-18 | 存档版本非法、版本未知或读取失败时保留原档，不写入空档 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-19 | 进入游戏后的可变操作必须等到存档就绪才执行 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-20 | 离线或重连后，旧会话的异步回调不覆盖新会话的存档 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-21 | 写档成功不得仅以 UpdateAsync 返回快照为准，必须额外校验会话与版本 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-22 | 每次写档都校验会话标识与版本号，不一致时拒绝写入 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-23 | 扣费操作具备可重试的操作身份，重试不重复扣费 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-24 | 发奖操作具备可重试的操作身份，重试不重复发奖 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-25 | 船票与兑换操作具备可重试的操作身份，重试不重复扣费或重复发奖 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-26 | 平台回调缺少唯一凭证时不得声明跨会话幂等已成立，须以平台侧验证结论为准 | 契约 | 人 | B | unverified | — |
| 18-27 | 共享的活鱼与地面物品不进入个人存档 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-28 | 已扣费的抽奖在重进后恢复结算，且不重复发奖 | 契约 | agent | B | evidenced | tests/native/lottery_settle_test.lua |
| 18-29 | 已扣费的兑换在重进后恢复结算，且不重复发奖 | 契约 | agent | B | evidenced | tests/native/economy_persistence_test.lua |
| 18-30 | 烧烤等占用物品的会话必须有明确的退出结算，会话结束时物品归属确定 | 契约 | agent | B | evidenced | tests/native/grill_test.lua |
| 18-31 | 重进时记录落点不合法，则恢复到同一区的安全点 | 契约 | agent | B | evidenced | tests/native/spec/18_session_settlement_contract_test.lua |
| 18-32 | 旧角色对象死亡后再次进入世界，玩家状态绑定到新角色，不继承旧角色的残留状态 | 契约 | agent | B | evidenced | tests/native/player_leave_rejoin_test.lua |
