# 0036 平台商城与广告在编辑器内不可验收，幂等与超时兜底由自研承担

**Status**: accepted（2026-09-22 取证，2026-11-24 收口成本条 ADR）

付费与广告是唯一「代码写完了也不能证明它对」的一块：能力本身存在，但验证只能发生在真实平台上。这条 ADR 只记**能力事实与适配后果**，不重述决策链——订单身份怎么定在 [ADR-0031](0031-persistent-operation-identity.md)，参数缺位怎么占位在 [ADR-0029](0029-scope-completeness-and-placeholder-first.md)，真实渠道单列在[生产开关台账](../acceptance/production-switches.md)。

## 能力事实

- `CommodityService`（17 个函数 / 5 个事件，`EggyAPI.lua`）；`AdvertisementService:ShowRewardedVideoAd(player, goodsId, successEvent, failEvent, adTag)`；邮件系统可发「游玩奖励」类商品。
- **无公开订单 ID**：`GoodsPurchaseCompleted(goodsId, goodsNum, player)` 不携带订单标识，官方教程明说不能用 `UserId..goodsId` 做发货防重键（站点 `lua/20-platform-services.html`）。
- **购买无取消 / 失败回调**：5 个事件里都没有；`ShowGoodsPurchasePanel(player, rawGoodsId, showTime)` 返回 void，`showTime` 的语义官方未说明。
- **广告在编辑器内不可验收**：须服务端调用；编辑器与本地调试「可能无回调、无 UI 表现或直接静默失败」（站点 `game_api/service/AdvertisementService.html`）。`failEvent` 也不保证触发。
- `goodsId` 来自商业化后台，后台文档不在公开站点；API 没有价格 / 货币 / 盲盒 / 抽奖接口，随机与发奖只能写 Lua，支付环节才可能走商品。
- 需要一张**已发布**的测试图：MemoryStore 在未发布图明文不可用（`Enums.MemoryStoreErrorCode.UnpublishedPlace = 102`，`EggyAPI.lua`）；DataStore 的错误码里没有「未发布」项，教程默认测试地图可真实读写（推断）；商品完全没有相关信息。

## 决定

1. **订单身份自研**：发货不依赖平台给的单号，按 [ADR-0031](0031-persistent-operation-identity.md) 的持久操作生成并落账，平台事件只是触发器。
2. **超时兜底是唯一收口**：取消、失败、成功三种收尾都不许只靠回调——没有取消 / 失败事件，`failEvent` 也不保证触发，所以每个在飞流程必须有自己的超时终点，超时即按失败结算并释放 busy。
3. **广告与商品只在真实平台取结论**：编辑器内的任何「跑通了」只证明适配层代码路径完整，一律记为占位结论，进[生产开关台账](../acceptance/production-switches.md)，不改条款状态。
4. **真实参数集中在配置**：商品 ID、广告位进 `common/game_cfg.lua` 的 `Platform` 段；真实参数到位后只替换配置，不改玩法判定。

## 后果

- 跨会话防重、补发与对账没有平台真源可对，只能靠自己的落账记录；对账口径归 [ADR-0031](0031-persistent-operation-identity.md)，本 ADR 不复制。
- 「支付期间暂停复活倒计时，取消后恢复」这类需求没有事件可挂，实现形态必然是「进入时记下剩余时间 + 超时恢复」，不是「等取消回调再恢复」。
- 本地平台适配测试（`tests/native/platform_seam_test.lua`）只断言 pending flow 关联与超时兜底，**不断言**订单身份、补发或对账能力存在——替身撑不起这三件事。

## 备选方案（拒绝）

- **等官方开放订单 ID 再做付费**：付费路径会永久悬空，且玩法判定与渠道进度被绑在一起（[ADR-0029](0029-scope-completeness-and-placeholder-first.md) 拒绝这种绑定）。
- **用 `UserId..goodsId` 当幂等键**：官方明说不可用，重复购买会被当成同一单吞掉。
- **在编辑器里造假回调来「验收」付费**：把模拟成功写进验收结论，等价于宣称渠道可用；真实渠道的事必须单列。