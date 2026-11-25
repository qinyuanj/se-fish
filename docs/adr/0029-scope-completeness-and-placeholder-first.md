# 0029 范围口径：规格内无永久出界，占位优先，完整性先于真实渠道取证

**Status**: accepted

为避免外部交付（正式美术、商品 ID、广告位、真实多人环境）长期阻塞玩法研发或把未完成项划为「永久出界」，本 ADR 确立统一的范围、占位与发布门禁口径。

## 决定

### 1. 规格内无永久出界
- 唯一范围由[验收矩阵](../acceptance/README.md)定义，不靠记忆或工单划定。`out-of-scope` 虽在词表内，但《渔力全开》规格条款一律不使用。
- 唯一允许的 `blocked` 是只能在地图中观察的 C 级试玩条款（由 `tools/acceptance.lua` 反推，试玩会话在 `evidence/*/session.md` 标 `✅` 后自动转 `evidenced`）。
- 「玩法实现」与「业务范围」概念区分以 [GLOSSARY.md](../../GLOSSARY.md) 为唯一定义，不得互换。

### 2. 占位优先，完整性先于真实渠道取证
外部依赖不再作为条款阻塞理由，缺参数时按五条走通完整代码路径：

1. **占位参数集中配置**：商品 ID、广告位、成就 ID、汇率、占位资产 ID 一律进 `common/game_cfg.lua` 与 `common/cfg/`，真实参数到位后只换配置不改玩法判定。
2. **平台能力经可替换适配层**：业务不直调平台服务，统一经 `server/platform_host.lua` 等适配层，成功与失败两路都可走通。
3. **本地连接夹具证明代码路径**：容量、加入/离开、共享世界状态用本地夹具证明路径完整，**不宣称真实容量或真实多人已验收**。
4. **占位不发放真实付费权益**：真实平台结论只在真实平台上取。
5. **占位通道默认不进发布构建**：占位支付 / 广告 / 分享共用闸门——默认仅调试构建（`GameCfg.Debug.Enabled`）可用，发布构建须显式设 `GameCfg.Platform.Placeholder.AllowInPublish = true`。闸门关闭时一律拒绝并回执 `reason = 'not_open'`，由 `tests/native/spec/17_platform_boundary_placeholder_test.lua` 与 `11_ad_revive_placeholder_test.lua`（条款 19-13）守卫。

### 3. 生产开关台账
所有真实渠道、外部交付与发布前签署事项单列为独立活文档：[生产开关台账](../acceptance/production-switches.md)。条款与文档只引用该表，不另抄一份。

## 理由

- **出界会把「没做」永久化**：规格内无永久出界，才能把未完成工作收敛成可度量的单一缺口。
- **占位与真实渠道分开记账**：占位证明代码路径完整，真实渠道证明线上可用；既不让玩法被排期拖死，也不让模拟成功冒充真实渠道验收。

## 后果

- 矩阵中不允许新增 `out-of-scope`（评审直接拒绝）。
- 门禁全绿代表代码路径与断言闭环，**不等于可发布**；发布前仍须逐项核对[生产开关台账](../acceptance/production-switches.md)。
- 静态门禁与状态反推规则以 [ADR-0039](0039-acceptance-surface-as-feature-files.md) 为准。
