-- #122 被测入口：鱼获与特殊道具配置的公开返回值。
-- 失败方式（先列后写）：
--   1. 录入漏行或普通/极品复用编号覆盖，品级分布与分区行数先走形；
--   2. 旧 v1 ID 丢失或被改指向另一物品，旧存档财产无法恢复。
-- 逐字段抄表（名称/重量/售价/源行/掉落引用/食用百分比/source 行号）与逐行「哪些未实装」白名单
-- 都等于把 data/ 再写一遍，由 common/content_validation.lua（编号/映射/引用/数量）与
-- lua tools/validate_content.lua 接手。
-- 迁移自 tests/gameplay/cfg_fish_items_test.lua（#83）；案例顺序沿用旧入口的方法名字典序。
local function count(rows)
  local total = 0
  for _ in pairs(rows) do total = total + 1 end
  return total
end

describe("TestCfgFishItems", function()
  -- 配置形状：七区各 14 行、四级品分布 42/42/7/7。漏一行或多行同号覆盖会让某一级少一行。
  it("testFishCatalogKeepsAllGradesWithoutOverwritingRepeatedNumbers", function()
    local fish = require('common.cfg.fish')
    local zones, grades = {}, { normal = 0, rare = 0, elite = 0, boss = 0 }
    for _, row in pairs(fish.Definitions) do
      grades[row.Grade] = grades[row.Grade] + 1
      zones[row.ZoneId] = (zones[row.ZoneId] or 0) + 1
    end
    assert.same({ normal = 42, rare = 42, elite = 7, boss = 7 }, grades)
    assert.are.equal(7, count(zones))
    for _, zoneCount in pairs(zones) do assert.are.equal(14, zoneCount) end
  end)

  it("testLegacyV1InventoryAndFishIdsStillResolve", function()
    local items = require('common.cfg.items')
    local fish = require('common.cfg.fish')
    -- 固定的 v1 存档样本；旧 ID 不能从新配置反推——按新配置算出来再查映射，漏映射也会通过。
    local oldItemIds = {
      'tilapia', 'carp', 'knifeFish', 'bass', 'catfish', 'goldfish',
      'worm', 'sausage', 'starterRod', 'shrimp', 'riverShrimp', 'crayfish',
      'bostonLobster', 'aussieLobster', 'milkLobster', 'rareShrimp', 'rareRiverShrimp',
      'rareCrayfish', 'rareBostonLobster', 'rareAussieLobster', 'rareMilkLobster',
      'eelMeat', 'eelHead', 'garMeat', 'garHead', 'duck', 'shrimpTicket',
      'shrimpRod', 'crabRod', 'normalRod', 'proRod', 'airforceRod', 'unscientificRod',
    }
    for _, oldId in ipairs(oldItemIds) do
      assert.are.equal(oldId, items.LegacyIdMap[oldId], oldId)
      assert.is_not_nil(items.Definitions[items.LegacyIdMap[oldId]], oldId)
    end
    local oldFishIds = {
      'tilapia', 'carp', 'knifeFish', 'bass', 'catfish', 'goldfish', 'eel', 'alligatorGar',
      'shrimp', 'riverShrimp', 'crayfish', 'bostonLobster', 'aussieLobster', 'milkLobster',
      'rareShrimp', 'rareRiverShrimp', 'rareCrayfish', 'rareBostonLobster', 'rareAussieLobster', 'rareMilkLobster',
    }
    for _, oldId in ipairs(oldFishIds) do
      assert.are.equal(oldId, fish.LegacyIdMap[oldId], oldId)
      assert.is_not_nil(fish.Definitions[fish.LegacyIdMap[oldId]], oldId)
    end
  end)
end)
