# 13. 图鉴与成就

> 本文件是《渔力全开》规格第 13 节的条款清单。格式与必填项见 [TEMPLATE.md](TEMPLATE.md)，小节索引见 [README.md](README.md)。

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 13-01 | 图鉴共 98 条独立记录，其中普通 42、极品 42、精英 7、首领 7 | 规则 | agent | A | unverified | — |
| 13-02 | 图鉴按七个钓鱼区分页 | 规则 | agent | A | unverified | — |
| 13-03 | 普通与极品分类展示，精英与首领另有明确的品级入口 | 规则 | agent | A | unverified | — |
| 13-04 | 成功收线上岸即解锁该鱼种图鉴记录，不等待击杀 | 规则 | agent | A | unverified | — |
| 13-05 | 同一条鱼的多份掉落不在图鉴重复记为钓取，一次上岸只入账一次 | 契约 | agent | B | unverified | — |
| 13-06 | 每次上岸更新该鱼种的个人最大钓取重量，仅在超过旧值时刷新 | 规则 | agent | A | unverified | — |
| 13-07 | 图鉴每条记录含鱼名、品级、钓鱼区、个人最大重量与全服纪录保持者五项 | 规则 | agent | A | evidenced | tests/native/spec/client_progress_315_test.lua |
| 13-08 | 缺少平台纪录时该记录显示未取得数据，不显示虚构纪录 | 规则 | agent | A | evidenced | tests/native/spec/client_progress_315_test.lua |
| 13-09 | 盲盒与信物兑换只解锁对应收集，不参与钓取重量纪录 | 契约 | agent | B | unverified | — |
| 13-10 | 交付哥斯拉头完成通关成就 | 规则 | agent | A | unverified | — |
| 13-11 | 全图鉴是额外收集目标，不是通关条件 | 规则 | agent | A | unverified | — |
| 13-12 | 平台成就后台 ID 交付前，本地先保存通关完成标记，重进后继续补交 | 契约 | agent | B | evidenced | tests/native/spec/server_progress_315_test.lua |
| 13-13 | 重复交付同一成就不得重复授予，已送达标记落账后不再提交 | 契约 | agent | B | evidenced | tests/native/spec/server_progress_315_test.lua |
| 13-14 | 平台查询与提交失败时保留补交，不把失败当成已授予 | 契约 | agent | B | evidenced | tests/native/spec/server_progress_315_test.lua |
| 13-17 | 全服纪录服务未接入时，该列只按未取得数据展示，不展示虚构纪录；真实纪录服务接入作为生产开关单列 | 契约 | agent | B | evidenced | tests/native/spec/client_progress_315_test.lua |
| 13-18 | 平台成就 ID 未交付时保留本地完成标记并支持重复补交；真实平台授予作为生产开关单列 | 契约 | agent | B | evidenced | tests/native/spec/server_progress_315_test.lua |

## C 级（试玩取证）

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 13-15 | 未收集条目显示剪影，不显示彩色图标或空白框 | 规则 | 试玩 | C | evidenced | evidence/2026-11-21-c13e15d/session.md（会话 c13e15d） |
| 13-16 | 七区分页与品级入口在试玩中可切换，普通与极品分类可辨 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
