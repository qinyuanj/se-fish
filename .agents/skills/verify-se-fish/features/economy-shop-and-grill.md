# 经济、钓场商店与烧烤（Economy, Shop & Grill）

玩家通过钓鱼佬出售鱼获换取金币，在钓场商店四个分页浏览新品、购买装备与鱼饵并受限购约束，并在 Z3（蟹湖）及之后的烧烤点 2 米内放入未烤制鱼获，按倍率曲线（1.00→1.50→0.00）精准取出增值或触发 4.5 秒烤糊扣血 30 点。

## Sub-features

- `economy-sell-fisherman` — 与钓鱼佬交互出售鱼获，金币按「基础价 × 个体倍率」向下取整到账且扣减对应物品。
- `shop-tabs-and-purchase` — 钓场商店四分页流畅切换，支持购买与限购拒绝、失败不扣费（原子结算），当地新解锁商品高亮可见。
- `grill-optimal-take` — Z3+ 烤炉投入未烤制鱼获，2.0～2.5 秒达到 1.50 倍率峰值；取出后售价与恢复量同步乘倍率且保留选中。
- `grill-burn-failure` — 4.5 秒未取出即烤糊损毁、提示「烤糊」，并对 3 米内玩家造成 30 点伤害。
- `grill-restrictions` — 已烤鱼不可再烤、不可抽奖；已烤信物不可兑换；库存满时取出被拒且不丢不复制。

## How to get to it (user POV)

- 在 Z1 鱼塘走向钓鱼佬 NPC 或钓场商店交互点，点击弹出的交互气泡打开对应面板（`FishermanView` / `ShopView`）。
- 在商店面板切换四个分页，点击商品购买并观察金币与背包变化。
- 摆渡或进入 Z3（蟹湖）及以上钓鱼区，走到烧烤点 2 米内，点击交互打开烧烤界面（`GrillView`），选中未烤制鱼获投入，在 2.0～2.5 秒取出或等待 4.5 秒验证烤糊。

## Driving it with tools/cli.lua & editor-cli

Preconditions:

- `lua .agents/skills/verify-se-fish/scripts/doctor.lua` 退出码为 `0`，已用独立 QA 存档槽并完成 `deploy`。
- 试玩已就绪，玩家背包内有至少一条未烤制鱼获及初始金币（测烧烤需到达 Z3 或更高钓鱼区）。

1. **离线 A/B 级规则验证（商店原子结算/限购、烤制倍率曲线、客户端面板）**：
   ```bash
   busted tests/native/spec/07_shop_purchase_limit_test.lua tests/native/spec/07_shop_settlement_atomic_test.lua tests/native/spec/07_coin_page_placeholder_test.lua tests/native/spec/10_grill_curve_test.lua tests/native/spec/server_shop_feed_311_test.lua tests/native/spec/client_shop_interaction_311_test.lua tests/native/spec/server_economy_312_test.lua tests/native/spec/client_economy_312_test.lua tests/native/spec/server_grill_310_test.lua tests/native/spec/client_grill_310_test.lua
   ```
   期望退出码 `0`。

2. **试玩打开钓场商店并截屏验证布局与购买副作用**：
   - 用 `"$CLI" input move-to` 走到 Z1 商店交互点并点击交互按钮打开商店；
   - 连拍两张截图保存到 `tmp/verify-se-fish/<run-id>/shop-tabs-a.png` 与 `shop-tabs-b.png`，用 `read_image` 复核四分页、新品高亮与价格/限购无遮挡（条款 `7-26`、`7-27`）；
   - 购买一件可买商品，记录操作前后的 `probe_online_players.lua` 金币差值与背包变化；测试金币不足或达限购上限时提示拒绝且金币不变。

3. **试玩烧烤正常取出与烤糊失败路径**：
   - 在 Z3+ 烧烤点 2 米内打开烧烤界面，抓拍 `grill-active.png` 核对倍率两位小数读数在外清晰无遮挡（条款 `10-26`、`10-27`）；
   - 正常路径：投入未烤制鱼获并在 2.0～2.5 秒取出，验证售价/恢复量按峰值倍率结算且不可再次放入；
   - 失败路径：投入另一份鱼获等待超过 4.5 秒，验证提示「烤糊」、鱼获损毁消失、玩家掉血 30 点；
   - 可辅以既有烧烤真机探针核验时序：
     ```bash
     CLI="$USERPROFILE/.eggitor/cli/editor-cli.exe"
     "$CLI" exec --platform server --file D:/dev/github/se-fish/tests/probes/grill_runtime.lua --json
     "$CLI" log grep "GRILL" --play-session <session> --max-matches 200
     ```

## Gotchas

- **Z1/Z2 无烧烤点（10-01）**：烧烤点从 Z3（蟹湖）起设置，在 Z1 找不到烤炉是预期行为，不要误判为场景缺失。
- **浮点比较陷阱（4-22、10-10）**：烤制结算先乘烤制倍率再向下取整，断言金币时用整数比较而非浮点相等。
- **信物烤制警告（10-04、10-17）**：未烤制信物允许放入烤炉，但放入前必须提示「烤后失去兑换与抽奖资格」，烤后不可再兑换。
- **平台商品占位边界**：商城金币页/平台商品依赖占位 `goodsId`（[production-switches.md](../../../../docs/acceptance/production-switches.md)），编辑器内验证占位成功/失败双路径即可，不宣称真实平台扣费。
