# 12. 精英与首领行为

> 本文件是《渔力全开》规格第 12 节的条款清单。格式与必填项见 [TEMPLATE.md](TEMPLATE.md)，小节索引见 [README.md](README.md)。
> 逐招表（每招的伤害来源映射、冷却调度、预警与单人躲避窗口）在 [`common/cfg/boss_moves.lua`](../../common/cfg/boss_moves.lua)，一招一行；首只贯通「配置 → 服务端调度 → 客户端预警 → 断言」的首领是火山岛的哥斯拉。

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 12-01 | 同一招式在正文与表中给出不同数值时，以表内数值为准 | 规则 | agent | A | unverified | — |
| 12-02 | 表中基础攻击列只约束该鱼的基础攻击，不作为覆盖同鱼其他独立招式伤害的依据 | 规则 | agent | A | unverified | — |
| 12-03 | 表中未给出参数的独立招式沿用正文数值，不因表缺列而删除该招式 | 规则 | agent | A | unverified | — |
| 12-04 | 表中未明确的命中次数、轨迹、预警与效果持续时间属实现期配置细化，须先形成可复验样例 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-05 | 实现期细化不得暗中增加新招式，本节列出的招式集合之外不新增攻击 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-06 | 精英与首领只在被召出并放下后进入战斗态，本节不新设召唤入口（出场沿用首领饵与信物兑换，见 §4、§8） | 规则 | agent | A | unverified | — |
| 12-07 | 电鳗移速 6，5 米内每秒放电一次、每次 10，持续 5 秒，之后睡眠 10 秒且睡眠中可受击 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-08 | 鳄雀鳝追咬伤害 30、间隔 1.5 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-09 | 鳄雀鳝只在头部区判定命中，玩家绕到后身即咬空 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-10 | 虾霸每 2 秒左右攻击一次，连续两下后接尾刺击飞，基础攻击 20 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-11 | 虾霸每活动 15 秒眩晕 5 秒，取代正文旧的 20 秒活动时长 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-12 | 小白龙啄击 50、间隔 1.5 秒 | 规则 | agent | A | unverified | — |
| 12-13 | 小白龙每 30 秒召雨云，10 米范围、每秒 50、持续 6 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-14 | 小白龙每 30 秒飞起俯冲，落地后自身眩晕 5 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-15 | 帝王蟹每 5 秒对前方乱刺，左右各 3 下、每下间隔 0.2 秒、每下 15 伤害 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-16 | 帝王蟹每活动 30 秒眩晕 5 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-17 | 蟹老板正面蟹钳双击、基础攻击 20、冷却 4 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-18 | 蟹老板每 30 秒冲撞一次 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-19 | 蟹老板每 25 秒旋转一次，每秒 360 度、持续 5 秒、碰触伤害 30 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_melee_aoe_test.lua |
| 12-20 | 剑鱼左右挥头，基础攻击 20 | 规则 | agent | A | unverified | — |
| 12-21 | 剑鱼跳跃周期 50 秒，落点为随机 10 米外、落地 5 米范围 100 伤害 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-22 | 三头鲨扫头基础攻击 25、冷却 3 秒 | 规则 | agent | A | unverified | — |
| 12-23 | 三头鲨翻滚移动带接触伤害 | 规则 | agent | A | unverified | — |
| 12-24 | 三头鲨每 20 秒跳跃，随机 15 米外落点、10 米范围 200 伤害 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-25 | 海象甩头基础攻击 25 | 规则 | agent | A | unverified | — |
| 12-26 | 海象突击周期 40 秒，直线冲锋 20 米、命中 120 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-27 | 虎鲸爪击 30、间隔 2 秒 | 规则 | agent | A | unverified | — |
| 12-28 | 虎鲸每 10 秒虎啸远程攻击一次 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-29 | 虎鲸每 10 秒甩尾一次，对后方 160 伤害 | 规则 | agent | A | unverified | — |
| 12-30 | 虎鲸跳跃周期 25 秒，随机 15 米外落点、10 米范围 240 伤害 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-31 | 白头鹰飞行移速 20、每 20 秒俯冲一次、基础攻击 30 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-32 | 风神翼龙飞行移速 20、每 4 秒投掷一次、落地范围 5 米 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-33 | 风神翼龙每 20 秒追踪俯冲一次 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-34 | 风神翼龙投掷与俯冲的独立伤害（正文 100 与 260）须经能力样例核对映射，不得因表只给通用攻击 35 而静默丢弃 | 规则 | agent | B | evidenced | tests/native/spec/12_boss_moves_ranged_dive_test.lua |
| 12-35 | 沧龙移速 13 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_phase_test.lua |
| 12-36 | 沧龙每 15 秒跃起砸击，落地后甩头 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_phase_test.lua |
| 12-37 | 沧龙绕岛巡航，咬最近的岛中心玩家，并可将玩家叼走入海 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_phase_test.lua |
| 12-38 | 沧龙咬中伤害 300 与过程接触伤害 150 分属两个判定段，不合并成一段 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_phase_test.lua |
| 12-39 | 哥斯拉血量 25000 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-40 | 哥斯拉每 2 秒爪击（基础攻击 50）、每 6 秒甩尾、每 30 秒原子吐息 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-41 | 哥斯拉保留正文跺脚招式及其对应范围 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-42 | 哥斯拉原子吐息命中正前方 10 米内的目标即秒杀，该数值优先于正文重叠招式的旧数值 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-43 | 哥斯拉血量低于 60% 入水，切换沧龙式攻击，咬中伤害 1000 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-44 | 哥斯拉血量低于 20% 重新上岸，伤害 +50%、吐息改为每 10 秒 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-45 | 哥斯拉的阶段切换优先于普通招式循环，阈值达成时立即进入对应阶段 | 契约 | agent | B | evidenced | tests/native/spec/12_boss_moves_test.lua、tests/native/spec/12_boss_moves_phase_test.lua |
| 12-46 | 正文末尾孤立的「追踪攻击 260」缺招式归属，不据此新增攻击 | 规则 | agent | A | evidenced | tests/native/spec/12_boss_moves_test.lua |
| 12-47 | 若秒杀、招式并集或逃跑时限导致正常金币路线无法通关，必须提交数值调整及复验结果 | 规则 | agent | A | unverified | — |
| 12-48 | 通关难度不得通过改成付费或稀有大奖前置来调节 | 规则 | agent | A | unverified | — |

## C 级（试玩取证）

| ID | 条款 | 组 | 执行者 | 证据等级 | 状态 | 证据 / 理由 |
| --- | --- | --- | --- | --- | --- | --- |
| 12-49 | 电鳗放电与睡眠有可见预警，作用范围在试玩中可读 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-50 | 鳄雀鳝头部攻击的预警朝向与后身弱点的边界在试玩中可读 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-51 | 帝王蟹乱刺、蟹老板旋转与冲撞的预警在试玩中可读 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-52 | 哥斯拉原子吐息有可观察预警，玩家能据此躲避 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-53 | 各首领跳跃、冲锋、俯冲的弹道时长与高度在试玩中校准 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-54 | 每个招式都留出可完成的单人躲避窗口，不存在必中招式 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
| 12-55 | 沧龙绕岛与叼走入海连续可观察，不出现瞬移 | 规则 | 试玩 | C | blocked | 卡在：需编辑器试玩取证（业务代码完成后整批进行） |
