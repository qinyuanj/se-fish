-- #89 迁移（原 tests/gameplay/attr_growth_test.lua，#139 T18 大奖成长切片 2）：
-- 属性成长纯逻辑（common/attr_growth.lua）。
-- 失败方式（先列后写）：
--   1. 加速因子算错或超限不钳制：第 21 个加速药水算出超过 3 倍（统一规格 §2 封顶基础 3 倍/20 个）；
--   2. 移速没有单一计算处：虚弱（×0.5）、霜冻（×0.7）、麻痹（×0）在不同管理器各乘一遍，
--      恢复顺序依赖导致成长丢失（#131 已知边界的根因）；
--   3. 非法输入（负数/小数/NaN/非数）把属性带偏；
--   4. 血量上限与 BodyScale 钉表漂移（两处各算一遍）。
-- 被测入口：common.attr_growth 纯函数，不碰引擎；数值全部来自 GameCfg 钉表（SpeedPotion/Survival/StatusEffects/BodyScale）。
-- describe/it 名沿用旧类名与方法名，案例顺序沿用旧 LuaUnit 的字典序执行序。
local GameCfg = require('common.game_cfg')
local AttrGrowth = require('common.attr_growth')

describe('TestAttrGrowth', function()
    -- 有效移速单一计算：基础 × 加速成长 × 虚弱 × 霜冻；麻痹为 0
    it('test_effective_speed_single_formula', function()
        local base = GameCfg.Ability.MoveSpeed.Base -- 7
        -- 无修饰：基础 × 成长
        assert.near(7, AttrGrowth.effective_speed(base, 0, {}), 1e-9)
        assert.near(21, AttrGrowth.effective_speed(base, 20, {}), 1e-9)
        -- 虚弱在成长后的移速上乘 0.5（统一规格 §2）
        assert.near(10.5, AttrGrowth.effective_speed(base, 20, { weak = true }), 1e-9)
        -- 霜冻 -30%（统一规格 §6.3 霜之新星）
        assert.near(21 * 0.7, AttrGrowth.effective_speed(base, 20, { frost = true }), 1e-9)
        -- 虚弱 + 霜冻同帧：同一处连乘，7×3×0.5×0.7 = 7.35
        assert.near(21 * 0.5 * 0.7, AttrGrowth.effective_speed(base, 20, { weak = true, frost = true }), 1e-9)
        -- 麻痹：无论其他修饰都为 0
        assert.same(0, AttrGrowth.effective_speed(base, 20, { paralyzed = true }))
        assert.same(0, AttrGrowth.effective_speed(base, 0, { paralyzed = true, weak = true, frost = true }))
        -- 非法基准回落配置基准，绝不产出 NaN/负速
        for _, bad in ipairs({ 0 / 0, math.huge, -1, 'x', nil }) do
            assert.message(tostring(bad)).near(base * 2, AttrGrowth.effective_speed(bad, 10, {}), 1e-9)
        end
    end)

    -- 血量上限委托 BodyScale 钉表，不另起公式（0 个 300、10 个 900、超限钳制）
    it('test_max_health_delegates_to_body_scale_plan', function()
        assert.same(300, AttrGrowth.max_health(0))
        assert.same(360, AttrGrowth.max_health(1))
        assert.same(900, AttrGrowth.max_health(10))
        assert.same(900, AttrGrowth.max_health(11))
        assert.same(300, AttrGrowth.max_health('x'))
        local BodyScale = require('common.body_scale')
        for n = 0, 12 do
            assert.same(BodyScale.plan(n).Health, AttrGrowth.max_health(n))
        end
    end)

    -- 加速因子：0 个 1 倍、1 个 1.1 倍、20 个 3 倍封顶；超限/非法输入钳制
    it('test_speed_factor_steps_and_caps', function()
        assert.near(1.0, AttrGrowth.speed_factor(0), 1e-9)
        assert.near(1.1, AttrGrowth.speed_factor(1), 1e-9)
        assert.near(2.0, AttrGrowth.speed_factor(10), 1e-9)
        assert.near(3.0, AttrGrowth.speed_factor(20), 1e-9)
        assert.message('第 21 个不得超过 3 倍').near(3.0, AttrGrowth.speed_factor(21), 1e-9)
        assert.near(3.0, AttrGrowth.speed_factor(999), 1e-9)
        for _, bad in ipairs({ -1, 0 / 0, math.huge, 'x', nil }) do
            assert.message(tostring(bad)).near(1.0, AttrGrowth.speed_factor(bad), 1e-9)
        end
        -- 小数按 BodyScale 同口径取整：1.5 个按 1 个算
        assert.near(1.1, AttrGrowth.speed_factor(1.5), 1e-9)
    end)

    -- 属性投影（common/attr_model.lua 的 35 行实现）只组合既有成长与商店真源，不另算一份：
    -- 体型与血量上限走 BodyScale.plan，移速走 AttrGrowth 口径，武器升级走 Shop.damage_scale，
    -- 饥饿上限钳到 Vitals.MaxHunger。并入自 tests/native/attr_model_test.lua（原 2 例）。
    it('test_attr_model_projection_reuses_growth_and_shop_sources', function()
        local AttrModel = require('common.attr_model')
        local BodyScale = require('common.body_scale')
        local plan = AttrModel.plan({ bodyPotions = 2, speedPotions = 3, baseSpeed = 7, moveMultiplier = 0.35, hunger = 500 })
        assert.same(BodyScale.plan(2).Scale, plan.body.Scale)
        assert.same(plan.body.Health - GameCfg.Ability.BodyScale.HealthBase, plan.attributes.PlayerMaxHealth.BaseExtra)
        assert.near(AttrGrowth.speed_factor(3) * 0.35 - 1, plan.attributes.PlayerWalkSpeed.Ratio, 1e-9)
        assert.same(GameCfg.Vitals.MaxHunger, plan.attributes.PlayerHunger.Base)
        local component = AttrModel.weapon_components('melee', 7)
        assert.same(1, component.Base)
        assert.near(GameCfg.Shop.damage_scale('melee', 7) - 1, component.Ratio, 1e-9)
        assert.same({ Base = 1, BaseExtra = 0, Ratio = 0, Bonus = 0 }, AttrModel.weapon_components('unknown', 99))
    end)
end)
