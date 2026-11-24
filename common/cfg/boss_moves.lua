local M = {}

M.Rows = {
    { Fish = 'eel', Name = '电鳗', Move = 'discharge', MoveName = '放电', Clause = '12-07', Range = 5,
      Damage = { Kind = 'flat', Value = 10, From = '§12 表：5 米内每秒 10' },
      Schedule = { Kind = 'interval', Sec = 1, DurationSec = 5, RestSec = 10 },
      Warning = { Kind = 'circle', WindupSec = 0.5, Notice = 'bossDischarge', Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 5 } },
    { Fish = 'gar', Name = '鳄雀鳝', Move = 'bite', MoveName = '头部追咬', Clause = '12-08', Range = 2.5,
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：追咬 30' },
      Schedule = { Kind = 'cooldown', Sec = 1.5 },
      Warning = { Kind = 'cone', WindupSec = 1.5, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1.5, Range = 2.5 } },

    { Fish = 'shrimp', Name = '虾霸', Move = 'claw', MoveName = '蟹钳双击', Clause = '12-10', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'interval', Sec = 2, ActivitySec = 15, StunSec = 5 },
      Warning = { Kind = 'cone', WindupSec = 2, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 2, Range = 2.5 } },
    { Fish = 'shrimp', Name = '虾霸', Move = 'tail', MoveName = '尾刺击飞', Clause = '12-10', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = 'GameCfg.FishCombat.shrimp.TailDamage（正文尾刺，表未给独立数值）' },
      Schedule = { Kind = 'combo', Count = 2, StepSec = 2 },
      Warning = { Kind = 'circle', WindupSec = 2, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 2, Range = 2.5 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'peck', MoveName = '啄击', Clause = '12-12', Range = 2.5,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：啄击 50' },
      Schedule = { Kind = 'interval', Sec = 1.5 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'rain', MoveName = '雨云', Clause = '12-13', Range = 10,
      Delivery = 'projectile', Landing = 'self',
      Damage = { Kind = 'flat', Value = 50, From = '§12 正文：每秒 50' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 6 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 10 } },
    { Fish = 'dragon', Name = '小白龙', Move = 'dive', MoveName = '飞起俯冲', Clause = '12-14', Range = 2.5,
      Delivery = 'diveLine', Landing = 'target',
      Damage = { Kind = 'flat', Value = 50, From = 'GameCfg.FishCombat.dragon.DiveDamage' },
      Schedule = { Kind = 'period', Sec = 30, StunSec = 5 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 2.5 } },

    { Fish = 'kingCrab', Name = '帝王蟹', Move = 'jab', MoveName = '前方乱刺', Clause = '12-15', Range = 2.5,
      Damage = { Kind = 'flat', Value = 15, From = '§12 正文：每下 15' },
      Schedule = { Kind = 'interval', Sec = 5, Count = 6, StepSec = 0.2, ActivitySec = 30, StunSec = 5 },
      Warning = { Kind = 'cone', WindupSec = 0.5, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'pinch', MoveName = '正面双击', Clause = '12-17', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'cooldown', Sec = 4, Count = 2, StepSec = 0.2 },
      Warning = { Kind = 'cone', WindupSec = 0.5, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'charge', MoveName = '冲撞', Clause = '12-18', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = 'GameCfg.FishCombat.crabBoss.ChargeDamage（表未给独立数值）' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 1.2 },
      Warning = { Kind = 'line', WindupSec = 0.5, Width = 2.5, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.5, Range = 2.5 } },
    { Fish = 'crabBoss', Name = '蟹老板', Move = 'spin', MoveName = '旋转', Clause = '12-19', Range = 3,
      Damage = { Kind = 'flat', Value = 30, From = '§12 正文：碰触伤害 30' },
      Schedule = { Kind = 'period', Sec = 25, DurationSec = 5 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 3 } },

    { Fish = 'swordfish', Name = '剑鱼', Move = 'swing', MoveName = '左右挥头', Clause = '12-20', Range = 2.5,
      Damage = { Kind = 'flat', Value = 20, From = '§12 表：基础攻击 20' },
      Schedule = { Kind = 'cooldown', Sec = 2 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'swordfish', Name = '剑鱼', Move = 'jump', MoveName = '高跃', Clause = '12-21', Range = 5,
      Delivery = 'diveArea', Landing = 'random',
      Damage = { Kind = 'flat', Value = 100, From = '§12 正文：落地 5 米范围 100' },
      Schedule = { Kind = 'period', Sec = 50, Distance = 10 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'sweep', MoveName = '扫头', Clause = '12-22', Range = 2.5,
      Damage = { Kind = 'flat', Value = 25, From = '§12 表：基础攻击 25' },
      Schedule = { Kind = 'cooldown', Sec = 3 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'roll', MoveName = '翻滚接触', Clause = '12-23', Range = 2.5,
      Damage = { Kind = 'contact', Value = 25, From = 'GameCfg.FishCombat.shark.RollDamage（表只给基础攻击）' },
      Schedule = { Kind = 'contact', Sec = 1 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'shark', Name = '三头鲨', Move = 'jump', MoveName = '高跃', Clause = '12-24', Range = 10,
      Delivery = 'diveArea', Landing = 'random',
      Damage = { Kind = 'flat', Value = 200, From = '§12 正文：10 米范围 200' },
      Schedule = { Kind = 'period', Sec = 20, Distance = 15 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 10 } },

    { Fish = 'walrus', Name = '海象', Move = 'swing', MoveName = '甩头', Clause = '12-25', Range = 2.5,
      Damage = { Kind = 'flat', Value = 25, From = '§12 表：基础攻击 25' },
      Schedule = { Kind = 'cooldown', Sec = 2 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'walrus', Name = '海象', Move = 'charge', MoveName = '突击', Clause = '12-26', Range = 2.5,
      Delivery = 'sweep', Landing = 'target', Corridor = 20,
      Damage = { Kind = 'flat', Value = 120, From = '§12 正文：命中 120' },
      Schedule = { Kind = 'period', Sec = 40, Distance = 20 },
      Warning = { Kind = 'line', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 20 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'claw', MoveName = '爪击', Clause = '12-27', Range = 2.5,
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：爪击 30' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'cone', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 2.5 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'roar', MoveName = '虎啸', Clause = '12-28', Range = 15,
      Delivery = 'projectile', Landing = 'target',
      Damage = { Kind = 'flat', Value = 30, From = 'GameCfg.FishCombat.orca.RoarDamage（表未给虎啸独立数值，#142 披露）' },
      Schedule = { Kind = 'period', Sec = 10 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 15 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'tail', MoveName = '甩尾', Clause = '12-29', Range = 4,
      Damage = { Kind = 'flat', Value = 160, From = '§12 正文：后方 160' },
      Schedule = { Kind = 'period', Sec = 10 },
      Warning = { Kind = 'circle', WindupSec = 0.8, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.8, Range = 4 } },
    { Fish = 'orca', Name = '虎鲸', Move = 'jump', MoveName = '鲸跃', Clause = '12-30', Range = 10,
      Delivery = 'diveArea', Landing = 'random',
      Damage = { Kind = 'flat', Value = 240, From = '§12 正文：10 米范围 240' },
      Schedule = { Kind = 'period', Sec = 25, Distance = 15 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 10 } },

    { Fish = 'fish47Elite', Name = '白头鹰', Move = 'dive', MoveName = '俯冲', Clause = '12-31', Range = 5,
      Delivery = 'diveLine', Landing = 'target',
      Damage = { Kind = 'flat', Value = 30, From = '§12 表：基础攻击 30' },
      Schedule = { Kind = 'period', Sec = 20 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 5 } },
    { Fish = 'fish48Boss', Name = '风神翼龙', Move = 'throw', MoveName = '投掷', Clause = '12-32', Range = 5,
      Delivery = 'projectile', Landing = 'target',
      Damage = { Kind = 'flat', Value = 100, From = '§12 正文：投掷 100（12-34 要求核对映射，不静默丢弃）' },
      Schedule = { Kind = 'period', Sec = 4 },
      Warning = { Kind = 'circle', WindupSec = 1.2, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1.2, Range = 5 } },
    { Fish = 'fish48Boss', Name = '风神翼龙', Move = 'dive', MoveName = '追踪俯冲', Clause = '12-33', Range = 5,
      Delivery = 'diveLine', Landing = 'target',
      Damage = { Kind = 'flat', Value = 260, From = '§12 正文：俯冲 260（12-34 要求核对映射，不静默丢弃）' },
      Schedule = { Kind = 'period', Sec = 20 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 1, Range = 5 } },

    { Fish = 'mosasaur', Name = '沧龙', Move = 'patrol', MoveName = '绕岛巡航', Clause = '12-37', Segment = 'none', Range = 2.5,
      Damage = { Kind = 'none', From = '§12 正文：绕岛巡航本身无伤；命中 300 与叼走过程接触 150 分两段结算' },
      Schedule = { Kind = 'cruise', Sec = 1, Speed = 13 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'leap', MoveName = '跃起砸击', Clause = '12-36', Segment = 'hit', Range = 5,
      Damage = { Kind = 'flat', Value = 35, From = '§12 表：基础攻击 35（正文未给砸击数值，[未查证] 灰盒取基础攻击）' },
      Schedule = { Kind = 'period', Sec = 15 },
      Warning = { Kind = 'circle', WindupSec = 1, Unverified = true },
      Dodge = { Kind = 'outrun', Sec = 1, Range = 5 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'head', MoveName = '落地甩头', Clause = '12-36', Segment = 'hit', Range = 2.5,
      Damage = { Kind = 'flat', Value = 35, From = '§12 表：基础攻击 35（正文只写落地后甩头，未给独立伤害，[未查证]）' },
      Schedule = { Kind = 'landing', Sec = 15 },
      Warning = { Kind = 'circle', WindupSec = 0.8, Unverified = true },
      Dodge = { Kind = 'telegraph', Sec = 0.8, Range = 2.5 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'bite', MoveName = '咬中叼走入海', Clause = '12-37', Segment = 'hit', Range = 2.5,
      Damage = { Kind = 'flat', Value = 300, From = '§12 正文：咬中 300（命中段；叼走位移不额外扣血）' },
      Schedule = { Kind = 'landing', Sec = 15, MaxCarrySec = 20 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'mosasaur', Name = '沧龙', Move = 'contact', MoveName = '叼走过程接触', Clause = '12-38', Segment = 'carry', Range = 2.5,
      Damage = { Kind = 'contact', Value = 150, From = '§12 正文：叼走过程接触 150（携带段，与命中 300 分开结算）' },
      Schedule = { Kind = 'contact', Sec = 1 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'claw', MoveName = '爪击', Clause = '12-40', Range = 4,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：2 秒爪击，基础攻击 50' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 4 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'tail', MoveName = '甩尾', Clause = '12-40', Range = 5,
      Damage = { Kind = 'flat', Value = 50, From = '§12 表：每 6 秒甩尾（表未给独立数值，取基础攻击）' },
      Schedule = { Kind = 'interval', Sec = 6 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 5 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'stomp', MoveName = '跺脚', Clause = '12-41', Range = 10,
      Damage = { Kind = 'flat', Value = 150, From = 'GameCfg.Ability.BossPhase.Attacks.stomp（正文独立跺脚）' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'circle', WindupSec = 0.8, Notice = 'bossStomp' },
      Dodge = { Kind = 'telegraph', Sec = 0.8, Range = 10 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'breath', MoveName = '原子吐息', Clause = '12-42', Range = 10,
      Damage = { Kind = 'lethal', From = '§12 表：正前 10 米命中秒杀' },
      Schedule = { Kind = 'period', Sec = 30, DurationSec = 5 },
      Warning = { Kind = 'line', WindupSec = 1.5, Width = 2, Notice = 'bossBreath' },
      Dodge = { Kind = 'telegraph', Sec = 1.5, Range = 10 } },
    { Fish = 'godzilla', Name = '哥斯拉', Move = 'bite', MoveName = '入水咬击', Clause = '12-43', Range = 2.5,
      Damage = { Kind = 'phaseBite', From = 'GameCfg.Ability.BossPhase.Thresholds[1].BiteDamage = 1000' },
      Schedule = { Kind = 'interval', Sec = 2 },
      Warning = { Kind = 'none', WindupSec = 0 },
      Dodge = { Kind = 'distance', Sec = 0, Range = 2.5 } },
}

M.Phases = {
    godzilla = {
        Name = '哥斯拉',
        NormalName = '常态（陆上）',
        Thresholds = {
            { Percent = 60, Phase = 'water', PhaseName = '入水（切换沧龙式咬击）',
              Move = 'bite', BiteDamage = 1000 },
            { Percent = 20, Phase = 'enraged', PhaseName = '狂暴（重新上岸，伤害 +50%，吐息每 10 秒）',
              DamageBonusPercent = 50, BreathIntervalSec = 10 },
        },
        AttackSets = {
            normal = { 'claw', 'tail', 'breath', 'stomp' },
            water = { 'bite' },
            enraged = { 'claw', 'tail', 'breath', 'stomp' },
        },
    },
}

M.Index = {}
for _, row in ipairs(M.Rows) do
    local fish = M.Index[row.Fish]
    if not fish then
        fish = {}
        M.Index[row.Fish] = fish
    end
    assert(fish[row.Move] == nil, 'common/cfg/boss_moves.lua: 重复的一招一行 ' .. row.Fish .. '.' .. row.Move)
    fish[row.Move] = row
end

for fishKey, boss in pairs(M.Phases) do
    for _, set in pairs(boss.AttackSets) do
        for _, move in ipairs(set) do
            assert(M.Index[fishKey] and M.Index[fishKey][move] ~= nil,
                'common/cfg/boss_moves.lua: 阶段表引用了表外招式 ' .. fishKey .. '.' .. move)
        end
    end
    for _, threshold in ipairs(boss.Thresholds) do
        if threshold.Move then
            assert(M.Index[fishKey] and M.Index[fishKey][threshold.Move] ~= nil,
                'common/cfg/boss_moves.lua: 阶段阈值引用了表外招式 ' .. fishKey .. '.' .. threshold.Move)
        end
    end
end

---取一行；鱼键或招式不存在时返回 nil（调用方负责退化）。
function M.get(fishKey, move)
    local fish = M.Index[fishKey]
    return fish and fish[move] or nil
end

function M.key_of(species, fishId)
    local combat = species and species.Combat
    if combat and M.Index[combat] then return combat end
    return fishId
end

---某只鱼的全部招式行，按书写顺序（= AttackSets 的确定性顺序）。
function M.for_fish(fishKey)
    local rows = {}
    for _, row in ipairs(M.Rows) do
        if row.Fish == fishKey then rows[#rows + 1] = row end
    end
    return rows
end

function M.attack_table(fishKey)
    local attacks = {}
    for _, row in ipairs(M.for_fish(fishKey)) do
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

function M.warning_of(fishKey, move)
    local row = M.get(fishKey, move)
    if not row then return nil end
    return { Kind = row.Warning.Kind, Shape = row.Warning.Kind,
        WindupSec = row.Warning.WindupSec, Width = row.Warning.Width,
        Notice = row.Warning.Notice, Range = row.Range }
end

local COMBAT_FIELDS = {
    ['dragon.rain'] = { RainRadius = 'Range', RainDamage = 'Damage', RainSec = 'DurationSec' },
    ['dragon.dive'] = { DiveRadius = 'Range', DiveDamage = 'Damage', StunSec = 'StunSec' },
    ['swordfish.jump'] = { JumpRadius = 'Range', JumpDamage = 'Damage', JumpIntervalSec = 'Sec', JumpDistance = 'Distance' },
    ['shark.jump'] = { JumpRadius = 'Range', JumpDamage = 'Damage', JumpIntervalSec = 'Sec', JumpDistance = 'Distance' },
    ['walrus.charge'] = { ChargeDamage = 'Damage', ChargeSec = 'Sec', ChargeDistance = 'Distance' },
    ['orca.roar'] = { RoarDamage = 'Damage', RoarSec = 'Sec', RoarRange = 'Range' },
    ['orca.jump'] = { JumpRadius = 'Range', JumpDamage = 'Damage', JumpIntervalSec = 'Sec', JumpDistance = 'Distance' },
    ['fish47Elite.dive'] = { DiveRadius = 'Range', DiveDamage = 'Damage', DiveIntervalSec = 'Sec' },
    ['fish48Boss.throw'] = { ThrowRadius = 'Range', ThrowDamage = 'Damage', ThrowIntervalSec = 'Sec' },
    ['fish48Boss.dive'] = { DiveRadius = 'Range', DiveDamage = 'Damage', DiveIntervalSec = 'Sec' },
}

local function column(row, name)
    if name == 'Range' then return row.Range end
    if name == 'Damage' then return row.Damage.Value end
    if name == 'Sec' then return row.Schedule.Sec end
    if name == 'DurationSec' then return row.Schedule.DurationSec end
    if name == 'Distance' then return row.Schedule.Distance end
    if name == 'StunSec' then return row.Schedule.StunSec end
    return nil
end

function M.combat_params(params, fishKey)
    local out = {}
    for key, value in pairs(params or {}) do out[key] = value end
    for _, row in ipairs(M.Rows) do
        local fields = row.Fish == fishKey and COMBAT_FIELDS[row.Fish .. '.' .. row.Move] or nil
        if fields then
            for target, source in pairs(fields) do
                local value = column(row, source)
                if value ~= nil then out[target] = value end
            end
        end
    end
    return out
end

return M
