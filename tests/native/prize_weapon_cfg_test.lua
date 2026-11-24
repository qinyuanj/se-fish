-- #139 T18 大奖成长切片 1：配置钉表（只留跨表对账）。
-- 失败方式（先列后写）：
--   1. 大奖武器与抽奖组（common/cfg/lottery.lua）、物品表（common/cfg/items.lua）对不上号，
--      或某件大奖武器在 game_cfg 的 MeleeWeapons / Guns 里没有数值（ContentValidation 不查武器数值）；
--   2. 药水累计上限在 Ability 与物品表各写一处，两处漂移时吃药逻辑与商店描述对不上。
-- 接缝：common/game_cfg.lua 的 Ability 段是纯数据，loadfile 取全新实例断言。
-- 逐项数值（伤害/间隔/弹匣/溅射/叠层/特效开关）等于把配置再写一遍；真行为由 weapon_system_test、
-- prize_weapon_effect_test、status_effect_test 在攻击与结算路径上验。
-- 迁移自 tests/gameplay/prize_weapon_cfg_test.lua（#83）；旧 setUp 逐例执行，映射为 before_each。
describe("TestPrizeWeaponCfg", function()
  local cfg, Items, Lottery

  before_each(function()
    cfg = assert(loadfile('common/game_cfg.lua'))()
    Items = require('common.cfg.items')
    Lottery = require('common.cfg.lottery')
  end)

  -- 对账：15 件大奖武器 = 抽奖三个武器组的并集，物品表全部存在且为武器分类
  it("test_prize_weapons_reconcile_with_lottery_groups_and_items", function()
    local groups = {}
    for _, entry in ipairs(Lottery.Patterns) do
      if entry.tripleReward and entry.tripleReward.kind == 'weaponChoice' then
        for _, itemKey in ipairs(entry.tripleReward.itemKeys) do
          groups[#groups + 1] = itemKey
        end
      end
    end
    assert.are.equal(15, #groups)
    for _, itemId in ipairs(groups) do
      local def = Items.Definitions[itemId]
      assert.is_not_nil(def, itemId .. ' 物品表缺定义')
      local inMelee = cfg.Ability.MeleeWeapons[itemId] ~= nil
      local inGuns = cfg.Ability.Guns[itemId] ~= nil
      assert.is_true(inMelee or inGuns, itemId .. ' 缺武器数值配置')
    end
  end)

  -- 加速药水（item167）与变大药水（item168）的累计上限在两段各写一份，只对账不抄数：
  -- 药水条目改指别处、或任一侧改了上限，这里先红。
  it("test_potion_limits_match_item_table", function()
    local potion = cfg.Ability.SpeedPotion
    assert.is_not_nil(potion, '缺加速药水配置')
    assert.are.equal(potion.MaxPotions, cfg.Items.PotionLimits[potion.Item], '加速药水累计上限与物品表不一致')
    local body = cfg.Ability.body_scale
    assert.is_not_nil(body, '缺变大体型配置')
    assert.are.equal(body.MaxPotions, cfg.Items.PotionLimits[body.PotionItem], '变大药水累计上限与物品表不一致')
  end)
end)
