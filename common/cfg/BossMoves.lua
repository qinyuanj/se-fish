-- 第 12 节「精英与首领行为」逐招表（#256）。
--
-- 一招一行，四列固定：伤害来源映射（Damage）、冷却调度（Schedule）、预警（Warning）、
-- 单人躲避窗口（Dodge）。表只描述「招式怎么落地」，不含判定与表现代码：
-- 服务端 common/BossPhase.lua 按 AttackTable 取间隔与伤害区间，server/Mgr/MgrFishUnit.lua
-- 在起手时按行取预警形状广播；客户端 client/LocalGarBite.lua 只消费广播载荷。
--
-- 口径（docs/acceptance/12-elite-boss-behavior.md）：
--   * 12-01 / 12-02 表内数值优先于正文；基础攻击列只约束该鱼的基础攻击，不覆盖独立招式。
--   * 12-03 表未给出的独立招式沿用正文数值（行里写正文值，不删行）。
--   * 12-04 命中次数、轨迹、预警与效果持续时间属实现期细化，行是它的可复验样例；
--     凡规格未给的数都标 Unverified = true 并登记 docs/to-questionnaire-策划案内部矛盾.md。
--   * 12-05 本表不新增招式：行集合 = GameSpec §12 列出的招式并集。
--
-- 字段：
--   Fish      逐招表键 = 鱼种的 Combat 标签（没有标签的鱼用鱼种 Id），
--             与 GameCfg.FishCombat / GameCfg.Ability.BossPhase 的键一致；服务端用 KeyOf 反查
--   Name      鱼名（给文档与报错用，不参与判定）
--   Move      招式键；MoveName 中文名
--   Clause    该行主要覆盖的条款 ID
--   Range     作用 / 命中范围（米）；接触类写接触半径
--   Damage    伤害来源映射：
--               Kind = 'flat'      固定数值，Value 必填
--               Kind = 'lethal'    秒杀（按目标当前血量结算），无 Value
--               Kind = 'phaseBite' 取阶段条目的 BiteDamage（哥斯拉入水咬击）
--               Kind = 'contact'   接触伤害，Value 必填
--               Kind = 'none'      无伤害（位移 / 控制类）
--             From 是该数值在规格或共享配置里的出处，供人核对，不参与判定
--   Schedule  冷却调度：
--               Kind = 'interval'  固定间隔，Sec
--               Kind = 'cooldown'  冷却，Sec
--               Kind = 'period'    周期触发，Sec；可选 DurationSec（持续）、Distance（位移距离）
--               Kind = 'combo'     连段，Count + StepSec
--               Kind = 'contact'   持续接触，Sec 是同一目标的最小结算间隔
--               附加：ActivitySec / StunSec（活动多少秒后眩晕多少秒）、RestSec（放电后睡眠）
--   Warning   预警：
--               Kind = 'none'      无起手，靠走位与距离躲
--               Kind = 'cone' / 'circle' / 'line'  起手形状；Shape 是广播给客户端的形状
--               WindupSec 起手时长；Width 线形走廊宽度；Notice 客户端标签
--   Dodge     单人躲避窗口：
--               Kind = 'telegraph' 预警期内离开形状（Sec = WindupSec）
--               Kind = 'distance'  保持在 Range 之外
--               Kind = 'outrun'    在弹道 / 冲锋到达前离开落点
--               Kind = 'none'      不可躲（秒杀招的必中段，本表不允许出现）
local M = {}

M.Rows = {
    -- 鱼塘
    { Fish = 'eel', Name = '电鳗', Move = 'discharge', MoveName = '放电', Clause = '12-07', Range = 5,
      Damage = { Kind = 'flat', Value = 10, From = '§12 表：5 米内每秒 10' },
      Schedule = { Kind = 'interval', Sec = 1, DurationSec = 5, RestSec = 10 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 0.5, Notice = 'bossDischarge', Unverified = true }, -- 起手 0.5 秒 [未查证]
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 5 } },
    { Fish = 'gar', Name = '鳄雀鳝', Move = 'bite', MoveName = '头部追咬', Clause = '12-08', Range = 2.5,
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：追咬 30' },
      Schedule = { Kind = 'cooldown', Sec = 1.5 },
      Warning = { Kind = 'cone', Shape = 'cone', WindupSec = 1.5, Unverified = true }, -- 间隔即预警窗，表未单列起手
      Dodge = { Kind = 'telegraph', Sec = 1.5, Range = 2.5 } },

    -- 虾池
    { Fish = 'shrimp', Name = '虾霸', Move = 'claw', MoveName = '蟹钳双击', Clause = '12-10', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'interval', Sec = 2, ActivitySec = 15, StunSec = 5 },
      Warning = { Kind = 'cone', Shape = 'cone', WindupSec = 2, Unverified = true }, -- 2 秒攻击节拍即预警窗
      Dodge = { Kind = 'telegraph', Sec = 2, Range = 2.5 } },
    { Fish = 'shrimp', Name = '虾霸', Move = 'tail', MoveName = '尾刺击飞', Clause = '12-10', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = 'GameCfg.FishCombat.shrimp.TailDamage（正文尾刺，表未给独立数值）' },
      Schedule = { Kind = 'combo', Count = 2, StepSec = 2 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 2, Unverified = true }, -- 尾刺沿用 2 秒节拍
      Dodge = { Kind = 'telegraph', Sec = 2, Range = 2.5 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'peck', MoveName = '啄击', Clause = '12-12', Range = 2.5,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：啄击 50' },
      Schedule = { Kind = 'interval', Sec = 1.5 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'rain', MoveName = '雨云', Clause = '12-13', Range = 10,
      Damage = { Kind = 'flat', Value = 50, From = '§12 正文：每秒 50' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 6 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 10 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'dive', MoveName = '飞起俯冲', Clause = '12-14', Range = 2.5,
      Damage = { Kind = 'flat', Value = 50, From = 'GameCfg.FishCombat.dragon.DiveDamage' },
      Schedule = { Kind = 'period', Sec = 30, StunSec = 5 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 2.5 } },

    -- 蟹湖
    { Fish = 'kingCrab', Name = '帝王蟹', Move = 'jab', MoveName = '前方乱刺', Clause = '12-15', Range = 2.5,
      Damage = { Kind = 'flat', Value = 15, From = '§12 正文：每下 15' },
      Schedule = { Kind = 'interval', Sec = 5, Count = 6, StepSec = 0.2, ActivitySec = 30, StunSec = 5 },
      Warning = { Kind = 'cone', Shape = 'cone', WindupSec = 0.5, Unverified = true }, -- 前方乱刺用扇形；起手 0.5 秒 [未查证]
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'pinch', MoveName = '正面双击', Clause = '12-17', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'cooldown', Sec = 4, Count = 2, StepSec = 0.2 },
      Warning = { Kind = 'cone', Shape = 'cone', WindupSec = 0.5, Unverified = true }, -- 起手 0.5 秒 [未查证]
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'charge', MoveName = '冲撞', Clause = '12-18', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = 'GameCfg.FishCombat.crabBoss.ChargeDamage（表未给独立数值）' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 1.2 },
      Warning = { Kind = 'line', Shape = 'line', WindupSec = 0.5, Width = 2.5, Unverified = true }, -- 起手 0.5 秒 / 走廊宽 2.5 [未查证]
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'spin', MoveName = '旋转', Clause = '12-19', Range = 3,
      Damage = { Kind = 'flat', Value = 30, From = '§12 正文：碰触伤害 30' },
      Schedule = { Kind = 'period', Sec = 25, DurationSec = 5 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 3 } },

    -- 树林岛
    { Fish = 'swordfish', Name = '剑鱼', Move = 'swing', MoveName = '左右挥头', Clause = '12-20', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'cooldown', Sec = 2 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'swordfish', Name = '剑鱼', Move = 'jump', MoveName = '高跃', Clause = '12-21', Range = 5,
      Damage = { Kind = 'flat', Value = 100, From = '§12 正文：落地 5 米范围 100' },
      Schedule = { Kind = 'period', Sec = 50, Distance = 10 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'sweep', MoveName = '扫头', Clause = '12-22', Range = 2.5,
      Damage = { Kind = 'flat', Value = 25, From = '§12 表：基础攻击 25' },
      Schedule = { Kind = 'cooldown', Sec = 3 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'roll', MoveName = '翻滚接触', Clause = '12-23', Range = 2.5,
      Damage = { Kind = 'contact', Value = 25, From = 'GameCfg.FishCombat.shark.RollDamage（表只给基础攻击）' },
      Schedule = { Kind = 'contact', Sec = 1 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'jump', MoveName = '高跃', Clause = '12-24', Range = 10,
      Damage = { Kind = 'flat', Value = 200, From = '§12 正文：10 米范围 200' },
      Schedule = { Kind = 'period', Sec = 20, Distance = 15 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 10 } },

    -- 沙滩岛
    { Fish = 'walrus', Name = '海象', Move = 'swing', MoveName = '甩头', Clause = '12-25', Range = 2.5,
      Damage = { Kind = 'flat', Value = 25, From = '§12 表：基础攻击 25' },
      Schedule = { Kind = 'cooldown', Sec = 2 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'walrus', Name = '海象', Move = 'charge', MoveName = '突击', Clause = '12-26', Range = 2.5,
      Damage = { Kind = 'flat', Value = 120, From = '§12 正文：命中 120' },
      Schedule = { Kind = 'period', Sec = 40, Distance = 20 },
      Warning = { Kind = 'line', Shape = 'line', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 20 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'claw', MoveName = '爪击', Clause = '12-27', Range = 2.5,
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：爪击 30' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'cone', Shape = 'cone', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 2.5 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'roar', MoveName = '虎啸', Clause = '12-28', Range = 15,
      Damage = { Kind = 'flat', Value = 30, From = 'GameCfg.FishCombat.orca.RoarDamage（表未给虎啸独立数值，#142 披露）' },
      Schedule = { Kind = 'period', Sec = 10 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 15 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'tail', MoveName = '甩尾', Clause = '12-29', Range = 4,
      Damage = { Kind = 'flat', Value = 160, From = '§12 正文：后方 160' },
      Schedule = { Kind = 'period', Sec = 10 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 0.8, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.8, Range = 4 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'jump', MoveName = '鲸跃', Clause = '12-30', Range = 10,
      Damage = { Kind = 'flat', Value = 240, From = '§12 正文：10 米范围 240' },
      Schedule = { Kind = 'period', Sec = 25, Distance = 15 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 10 } },

    -- 礁石岛
    { Fish = 'fish47Elite', Name = '白头鹰', Move = 'dive', MoveName = '俯冲', Clause = '12-31', Range = 5,
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：基础攻击 30' },
      Schedule = { Kind = 'period', Sec = 20 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 5 } },
    { Fish = 'fish48Boss', Name = '风神翼龙', Move = 'throw', MoveName = '投掷', Clause = '12-32', Range = 5,
      Damage = { Kind = 'flat', Value = 100, From = '§12 正文：投掷 100（12-34 要求核对映射，不静默丢弃）' },
      Schedule = { Kind = 'period', Sec = 4 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1.2, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1.2, Range = 5 } },
    { Fish = 'fish48Boss', Name = '风神翼龙', Move = 'dive', MoveName = '追踪俯冲', Clause = '12-33', Range = 5,
      Damage = { Kind = 'flat', Value = 260, From = '§12 正文：俯冲 260（12-34 要求核对映射，不静默丢弃）' },
      Schedule = { Kind = 'period', Sec = 20 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 5 } },

    -- 火山岛
    { Fish = 'mosasaur', Name = '沧龙', Move = 'leap', MoveName = '跃起砸击', Clause = '12-36', Range = 10,
      Damage = { Kind = 'flat', Value = 100, From = 'GameCfg.Ability.Flight.Species.fish55Elite.DiveDamage（正文未给砸击数值）' },
      Schedule = { Kind = 'period', Sec = 15 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 10 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'bite', MoveName = '咬中叼走', Clause = '12-37', Range = 2.5,
      Damage = { Kind = 'flat', Value = 300, From = '§12 正文：咬中 300' },
      Schedule = { Kind = 'period', Sec = 15 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 2.5 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'contact', MoveName = '过程接触', Clause = '12-38', Range = 2.5,
      Damage = { Kind = 'contact', Value = 150, From = '§12 正文：过程接触 150（与咬中 300 分属两段）' },
      Schedule = { Kind = 'contact', Sec = 1 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'claw', MoveName = '爪击', Clause = '12-40', Range = 4,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：2 秒爪击，基础攻击 50' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 4 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'tail', MoveName = '甩尾', Clause = '12-40', Range = 5,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：每 6 秒甩尾（表未给独立数值，取基础攻击）' },
      Schedule = { Kind = 'interval', Sec = 6 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 5 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'stomp', MoveName = '跺脚', Clause = '12-41', Range = 10,
      Damage = { Kind = 'flat', Value = 150, From = 'GameCfg.Ability.BossPhase.Attacks.stomp（正文独立跺脚）' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'circle', Shape = 'circle', WindupSec = 0.8, Notice = 'bossStomp' },
      Dodge = { Kind = 'telegraph', Sec = 0.8, Range = 10 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'breath', MoveName = '原子吐息', Clause = '12-42', Range = 10,
      Damage = { Kind = 'lethal', From = '§12 表：正前 10 米命中秒杀' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 5 },
      Warning = { Kind = 'line', Shape = 'line', WindupSec = 1.5, Width = 2, Notice = 'bossBreath' },
      Dodge = { Kind = 'telegraph', Sec = 1.5, Range = 10 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'bite', MoveName = '入水咬击', Clause = '12-43', Range = 2.5,
      Damage = { Kind = 'phaseBite', From = 'GameCfg.Ability.BossPhase.Thresholds[1].BiteDamage = 1000' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'none', Shape = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
}

-- 索引：按鱼键、招式键取值；同一 (Fish, Move) 只能出现一次。
M.Index, M.FishKeys = {}, {}
for _, row in ipairs(M.Rows) do
    local fish = M.Index[row.Fish]
    if not fish then
        fish = {}
        M.Index[row.Fish] = fish
        M.FishKeys[#M.FishKeys + 1] = row.Fish
    end
    assert(fish[row.Move] == nil, 'common/cfg/BossMoves.lua: 重复的一招一行 ' .. row.Fish .. '.' .. row.Move)
    fish[row.Move] = row
end

---取一行；鱼键或招式不存在时返回 nil（调用方负责退化）。
function M.Get(fishKey, move)
    local fish = M.Index[fishKey]
    return fish and fish[move] or nil
end

---鱼种 → 逐招表键：优先用 Combat 标签（与 GameCfg.FishCombat 同一套键），
---没有标签的鱼（如白头鹰、风神翼龙走飞行档案）退回鱼种 Id。
function M.KeyOf(species, fishId)
    return (species and species.Combat) or fishId
end

---某只鱼的全部招式行，按书写顺序（= AttackSets 的确定性顺序）。
function M.ForFish(fishKey)
    local rows = {}
    for _, row in ipairs(M.Rows) do
        if row.Fish == fishKey then rows[#rows + 1] = row end
    end
    return rows
end

-- AttackTable：把逐招表折成 common/BossPhase.lua 消费的招式表（间隔 / 伤害 / 起手 / 宽度）。
-- GameCfg.Ability.BossPhase.Attacks 直接指向它，保证「表 → 调度」只有一份数值。
function M.AttackTable(fishKey)
    local attacks = {}
    for _, row in ipairs(M.ForFish(fishKey)) do
        local attack = { Range = row.Range }
        if type(row.Schedule.Sec) == 'number' then attack.IntervalSec = row.Schedule.Sec end
        if row.Damage.Kind == 'flat' or row.Damage.Kind == 'contact' then
            attack.Damage = row.Damage.Value
        elseif row.Damage.Kind == 'lethal' then
            attack.OneShot = true
        end
        if row.Warning.Kind ~= 'none' then
            if row.Warning.WindupSec and row.Warning.WindupSec > 0 then attack.WindupSec = row.Warning.WindupSec end
            if row.Warning.Width then attack.Width = row.Warning.Width end
        end
        attacks[row.Move] = attack
    end
    return attacks
end

---预警映射：服务端广播只从这里取形状 / 起手 / 范围，命中判定不读这张表。
function M.WarningOf(fishKey, move)
    local row = M.Get(fishKey, move)
    if not row then return nil end
    return { Kind = row.Warning.Kind, Shape = row.Warning.Shape,
        WindupSec = row.Warning.WindupSec, Width = row.Warning.Width,
        Notice = row.Warning.Notice, Range = row.Range }
end

return M
