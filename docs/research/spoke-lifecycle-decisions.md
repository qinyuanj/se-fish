# spoke 生命周期五项定案与实施合同

- 日期：2026-11-22（Asia/Shanghai）
- 决策：Q1～Q27 由用户按推荐确认；Q28～Q31 和其余细节由用户授权 lead 按推荐定案。
- 证据边界：native fake 只证明业务回调与适配器可观察结果，不冒充真实 Disconnect、Unit 销毁、关局、换场景或试玩证据。

## 共同门禁

五项分别修复，本轮均不引入 SpokeTree／Dock／spoke_eggy；不修改上游包，不新增通用生命周期框架、全局单位容器或测试专用生产 seam。每项按公共 seam 做一个可观察反例的 red → green。ScreenMain 的 RootNode.Destroying、LocalLoot 的关局／换场景停止点仍缺直接宿主证据，未取得证据前不新增猜测的销毁调用者。

## ScreenParty

- Start 可重入且幂等：成功后只有一代 HUD 节点，PartyState／PartyResult／Heartbeat 各一个有效监听。重入失败保留最后可用一代并回滚新建部分；首次启动失败回到完全停止状态。
- Clear 完整且幂等：断开连接、销毁节点，清空 PartyState／PartyId／Teammates／InviteFrom／InviteUntil，旧事件不再通知、渲染或改写 View；清缓存不代表退出服务端队伍。
- 每次服务端投递只要映射为非空玩家文案就恰好通知一次；成功回执、空文案和未映射 notice 不通知，不按 notice code 跨事件去重。
- 保持客户端入口启动与 Start／Clear 自管，不接入 MgrGameUI.OpenScreen／CloseScreen。Dock 与只搬三次 Connect 的 spoke 包装均不通过 deletion test。
- 测试 seam：Start／Clear、PartyState／PartyResult／Heartbeat、LocalMsgNotice 与 fake 有效监听数。

## LocalLoot

- 活动状态重复 Start 为 no-op：不新增三个连接、不重复 RequestLoot，通知与 Blink 不倍增；启动中途失败反向回滚后可重试。
- 若未来取得真实生产停止点，Stop 必须是完整 quiescence；本轮不新增只有测试调用的公开 Stop，启动失败回滚复用内部清理所有权。
- LootState 是完整快照：同 id 保留根身份与首次 Position，只更新 Warning；消失 id 销毁一次，再出现创建新根；点击继续上行原数值 id。
- 视觉根 Destroy 失败采用 best-effort 诊断：记录 loot id 与错误、继续其他节点、不自动重试，不静默吞错。
- 不采用 Dock：alive 差集、表现状态、三个宿主连接与整体停止仍需业务所有者，不能为迁移再造双重资源所有权。
- 测试 seam：Start、LootState／LootResult／Heartbeat、RequestLoot、CreateUnit 返回根的可观察身份与 Destroy 次数。

## ScreenMain／MgrGameUI

- RootNode 引用变化切根代次，A→B 完整回收 A；Close 不销毁根、不断根监听、不取消收线。每次 Open 开新 Open 代次，保留重复 Open 的立即请求，只使旧 0.6 秒补取失效。
- 部分 Init 反向回收后重抛原始初始化错误；回滚二次错误逐项记录且不覆盖原错误。Cleanup 各阶段记录警告并继续，不聚合返回、不向 A→B 调用方抛二次清理错误，保持既有业务清理顺序。
- 修正 Close 的 TweenOpacity 参数错位；旧 Open／Close 动画回调不得写新根或新 Open 代次。真实宿主回调时点仍待试玩核对。
- OpSeq 属会话寿命，Close 与换根均连续递增；Snapshot 换根清空并等待权威刷新，首个空蚯蚓快照不补发“从有到无”提示；SpecialEffect／BreathCooldownUntil 跨根保留并由权威状态纠偏。
- 不做全量 State／Effect 重写，不把根监听放进 Open Phase；只换 Connections 的 spoke 试点不通过 deletion test。
- 测试 seam：MgrGameUI.GetScreen／OpenScreen／CloseScreen、ScreenMain.Init／OpenScreen／CloseScreen／Destroy、两类 Delay、Tween fake、远端事件与收线状态。

## 摆渡航班

- MgrFerry 使用私有单表 keyed route record，集中 pending／active、payer、operation、DepartAt、恢复／重连查询和显式终局；不采用 Dock／SpokeTree。
- 共享 FerryState 的 countdown／departed／cancelled 均带 routeId 与 operation；countdown 带 seconds，cancelled 带 reason。新 operation 的 countdown 替换当前班次，旧终局不得清新班次或弹旧提示。
- 正常到期为 countdown→departed 且无 cancelled；缺锚点为 countdown→cancelled 且取消一次。pending 退出静默；active 交票人退出只取消自己的 route 并广播一次 cancelled。cleanup 不推导业务终局或退款。
- 交票人到期在船外：不传送、不改目的区、不记到达，船票幂等退回一次；无其他乘客时共享取消原因为 empty，个人退款原因为 not_aboard。其他乘客已送达时共享可 departed，未上船交票人仍只收个人退款结果。
- cancelled 立即发布且不代表退款已持久化；recovery 负责最终退款，重试不重复广播。重连只补推仍 active 的航班，用原 DepartAt 计算 seconds 并 FireClient；不补 pending、不复活 cancelled、不重置时钟。
- 个人结果复用 FerryResult 的 ok／action／routeId／seconds／price／operation／reason，不新增 phase／outcome／refunded。Board 接受包带 seconds；实际到达包为成功 Board 且不带 seconds；所有实际送达者（含搭便船者）收定向到达提示，未送达者不收。
- 退款提示只在持久化成功后发送：not_aboard／anchor／interrupted／teleport 分别映射明确文案；Board 与 Return 的 teleport 不得都写“金币已退”。结果重放可再次提示，不得再次改财产、传送或记到达。
- 测试 seam：Board／Return／Update／OnPlayerRemoving／Recover／OnPlayerAdded、Save 重放、FerryState／FerryResult、传送与持久化结果。

## 投掷飞行物

- 投掷者退出后，在飞爆炸物继续到原落点结算，不取消、不提前引爆，不影响其他玩家记录；本轮不新增碰撞命中或主动取消。
- CreateUnit 抛错或返回空视觉不影响逻辑飞行、物品消耗与到期水中鱼／伤害结算；视觉是纯表现，外部提前销毁不改变逻辑终局。
- 正常到期前先摘记录，再 best-effort 销毁视觉，最后 Detonate；重复 Update 不得再次 Destroy／Detonate／生成水中鱼／结算伤害。视觉销毁失败记录必要上下文。
- “到期进入一次”不等于“所有副作用成功一次”；Detonate 异常的部分副作用不伪称事务保证，另以最小反例核对。
- 暂缓 spoke；外部时钟、Update 与显式玩法终局仍属 MgrWeapon。
- 测试 seam：Launch／Update／OnPlayerRemoving、CreateUnit／Destroy、Detonate 的可观察伤害与水中鱼结果。
