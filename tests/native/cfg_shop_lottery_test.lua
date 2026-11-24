-- 失败方式：内容表被运行期写入污染（#203：重载 game_cfg 后键集合变化、锚点入口指向未解析的场景区域表）；
--   盲盒保底两件与大奖表顺序脱钩；抽奖判奖口径与代码注释不再一致；升级组漏级/重级、背包描述与容量错位。
-- 源行的编号/价/等级/限购/名称/权重/倍率等口径由 common/content_validation.lua 与 content_validation_test 覆盖，这里不再重列。
-- 迁移自 tests/gameplay/cfg_shop_lottery_test.lua（#83）；案例顺序沿用旧入口的方法名字典序。
describe("TestContentCfg", function()
  it("test_blindbox_content_table_holds_no_runtime_keys_across_gamecfg_loads", function()
    local cfgModule, contentModule = 'common.game_cfg', 'common.cfg.blindbox'
    local savedCfg, savedContent = package.loaded[cfgModule], package.loaded[contentModule]
    -- 测试基线已预加载 game_cfg。单独加载这两个模块，断言失败时也恢复原缓存。
    package.loaded[cfgModule], package.loaded[contentModule] = nil, nil
    local ok, err = pcall(function()
      local content = require(contentModule)
      local function contentKeys()
        local keys = {}
        for key, value in pairs(content) do
          assert.are_not.equal('function', type(value), '内容表不能承载运行期函数：' .. key)
          keys[#keys + 1] = key
        end
        table.sort(keys)
        return keys
      end

      local before = contentKeys()
      local cfg = require(cfgModule)
      assert.same(before, contentKeys())
      assert.is_true(cfg.Content.Blindbox == content)
      assert.is_false(cfg.Blindbox == content)
      assert.is_true(cfg.Blindbox.Entries == content.Entries)
      assert.is_true(cfg.Blindbox.Pity == content.Pity)
      assert(loadfile('common/game_cfg.lua'))()
      assert.same(before, contentKeys())
      -- 保底两件按大奖表顺序取前两名（迁移自 cfg_item_refs_test 的唯一增量）：抽奖机在 prizeItemKeys 中等概率
      -- 取一件，顺序一旦与 Entries 前两名脱钩，保底就抽到非大奖物品。
      assert.same({ content.Entries[1].itemKey, content.Entries[2].itemKey }, content.Pity.prizeItemKeys)
    end)
    package.loaded[cfgModule], package.loaded[contentModule] = savedCfg, savedContent
    if not ok then error(err, 0) end
  end)

  -- #203：内容表只承载内容。运行期写入一旦落在 require('common.cfg.lottery') 返回的共享表上，
  -- 任何一次 loadfile('common/game_cfg.lua')()（测试重载不换 package.loaded）都会改写它的键，
  -- 而分片跑时没有别的文件把锚点入口装回来，抽奖结算全部被范围校验拒绝。
  it("test_lottery_content_table_holds_no_runtime_keys_across_gamecfg_reload", function()
    local zone_fixtures = require('tests.support.zone_fixtures')
    zone_fixtures.Load()
    local content = require('common.cfg.lottery')
    local before = {}
    for key in pairs(content) do before[#before + 1] = key end
    table.sort(before)
    for key, value in pairs(content) do
      assert.are_not.equal('function', type(value), '内容表不能承载运行期函数：' .. tostring(key))
    end
    local anchors = require('common.game_cfg').Lottery.MachineAnchors
    assert(loadfile('common/game_cfg.lua'))()
    local after = {}
    for key in pairs(content) do after[#after + 1] = key end
    table.sort(after)
    assert.same(before, after)
    -- 重载换不掉已加载模块表上的可调用入口：函数指针原样，锚点仍取同一份场景解析结果
    assert.is_true(anchors == require('common.game_cfg').Lottery.MachineAnchors)
    assert.same({ 'Z1_Lottery', 'Z2_Lottery', 'Z3_Lottery', 'Z4_Lottery', 'Z5_Lottery', 'Z6_Lottery', 'Z7_Lottery' },
      anchors())
    -- 判奖口径只留两个字符串（common/lottery_draw.lua 的判奖注释按它们写死）；权重、倍率、五件武器组、
    -- 七图案数量等数值维度由 ContentValidation 覆盖，不再逐条重列。
    assert.are.equal('exactlyTwo', content.PairRule)
    assert.are.equal('tripleFirst', content.TripleRule)
  end)

  it("test_upgrades_are_once_per_level", function()
    local goods = require('common.cfg.shop').Goods
    local groups = { backpack = 6, melee = 7, ranged = 5, explosive = 3, magazine = 3 }
    local seen = {}
    for _, row in ipairs(goods) do
      if row.upgrade then
        local upgrade = row.upgrade
        assert.are.equal(1, row.purchaseLimit)
        assert.is_true(upgrade.level >= 1 and upgrade.level <= groups[upgrade.kind])
        local key = upgrade.kind .. upgrade.level
        assert.is_nil(seen[key], key)
        seen[key] = true
      end
    end
    for kind, maximum in pairs(groups) do
      for level = 1, maximum do assert.is_true(seen[kind .. level]) end
    end
    for _, row in ipairs(goods) do
      if row.upgrade and row.upgrade.kind == 'backpack' and row.upgrade.level == 6 then
        assert.are.equal('购买后，道具栏+1，背包格+5', row.description)
        assert.are.equal(40, row.upgrade.backpackSlots)
      end
    end
  end)
end)
