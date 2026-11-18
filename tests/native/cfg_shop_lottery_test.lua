-- 失败方式：漏录/重复源行、作废售卖、金额和限购错位、抽奖返奖混淆、保底或货币错误、引用失效；
--   内容表被运行期写入污染（#203：重载 GameCfg 后键集合变化、锚点入口指向未解析的场景区域表）。
-- 迁移自 tests/gameplay/cfg_shop_lottery_test.lua（#83）；案例顺序沿用旧入口的方法名字典序。
describe("TestContentCfg", function()
  it("test_blindbox_content_table_holds_no_runtime_keys_across_gamecfg_loads", function()
    local cfgModule, contentModule = 'common.GameCfg', 'common.cfg.Blindbox'
    local savedCfg, savedContent = package.loaded[cfgModule], package.loaded[contentModule]
    -- 测试基线已预加载 GameCfg。单独加载这两个模块，断言失败时也恢复原缓存。
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
      assert(loadfile('common/GameCfg.lua'))()
      assert.same(before, contentKeys())
    end)
    package.loaded[cfgModule], package.loaded[contentModule] = savedCfg, savedContent
    if not ok then error(err, 0) end
  end)

  it("test_blindbox_weight_pricing_and_pity", function()
    local box = require('common.cfg.Blindbox')
    assert.are.equal(42, #box.Entries)
    local weight, priceExpectation = 0, 0
    for _, entry in ipairs(box.Entries) do
      assert.is_not_nil(entry.source:match('^地图盲盒表!R%d+$'))
      assert.is_not_nil(entry.itemKey)
      assert.is_true(entry.weight > 0 and entry.weight % 1 == 0)
      assert.is_true(entry.basePrice > 0 and entry.basePrice % 1 == 0)
      assert.are.equal(1, entry.multiplier)
      assert.are.equal(false, entry.implemented)
      weight = weight + entry.weight
      priceExpectation = priceExpectation + entry.weight * entry.basePrice / 1000
    end
    assert.are.equal(1000, weight)
    assert.near(166.075, priceExpectation, 0.00001)
    assert.are.equal('金豆', box.Currency)
    assert.are.equal(10, box.SinglePrice)
    assert.are.equal(90, box.TenPrice)
    assert.are.equal(49, box.Pity.afterMisses)
    assert.are.equal(50, box.Pity.guaranteedDraw)
    assert.are.equal(2, #box.Pity.prizeItemKeys)
    assert.are.equal('极品美人鱼', box.Entries[1].itemName)
    assert.are.equal('极品蛇颈龙', box.Entries[2].itemName)
    assert.is_true(box.Entries[1].jackpot and box.Entries[2].jackpot)
  end)

  -- #203：内容表只承载内容。运行期写入一旦落在 require('common.cfg.Lottery') 返回的共享表上，
  -- 任何一次 loadfile('common/GameCfg.lua')()（测试重载不换 package.loaded）都会改写它的键，
  -- 而分片跑时没有别的文件把锚点入口装回来，抽奖结算全部被范围校验拒绝。
  it("test_lottery_content_table_holds_no_runtime_keys_across_gamecfg_reload", function()
    local ZoneFixtures = require('tests.support.zone_fixtures')
    ZoneFixtures.Load()
    local content = require('common.cfg.Lottery')
    local before = {}
    for key in pairs(content) do before[#before + 1] = key end
    table.sort(before)
    for key, value in pairs(content) do
      assert.are_not.equal('function', type(value), '内容表不能承载运行期函数：' .. tostring(key))
    end
    local anchors = require('common.GameCfg').Lottery.MachineAnchors
    assert(loadfile('common/GameCfg.lua'))()
    local after = {}
    for key in pairs(content) do after[#after + 1] = key end
    table.sort(after)
    assert.same(before, after)
    -- 重载换不掉已加载模块表上的可调用入口：函数指针原样，锚点仍取同一份场景解析结果
    assert.is_true(anchors == require('common.GameCfg').Lottery.MachineAnchors)
    assert.same({ 'Z1_Lottery', 'Z2_Lottery', 'Z3_Lottery', 'Z4_Lottery', 'Z5_Lottery', 'Z6_Lottery', 'Z7_Lottery' },
      anchors())
  end)

  it("test_lottery_has_seven_patterns_and_independent_prizes", function()
    local lottery = require('common.cfg.Lottery')
    assert.are.equal(7, #lottery.Patterns)
    local weight = 0
    for _, pattern in ipairs(lottery.Patterns) do
      weight = weight + pattern.weight
      assert.is_not_nil(pattern.source:match('^抽奖表!R%d+$'))
      assert.is_true(pattern.pairMultiplier > 0)
      assert.are.equal(true, pattern.implemented, pattern.source .. ' #138 起接入抽奖机')
    end
    assert.are.equal(100, weight)
    assert.are.equal(2, lottery.Patterns[1].pairMultiplier)
    assert.are.equal(20, lottery.Patterns[7].pairMultiplier)
    assert.are.equal(5, #lottery.Patterns[1].tripleReward.itemKeys)
    assert.are.equal(5, #lottery.Patterns[2].tripleReward.itemKeys)
    assert.are.equal(5, #lottery.Patterns[3].tripleReward.itemKeys)
    assert.are.equal('加速药水', lottery.Patterns[4].tripleReward.itemName)
    assert.are.equal('exactlyTwo', lottery.PairRule)
    assert.are.equal('tripleFirst', lottery.TripleRule)
  end)

  it("test_shop_rows_and_source_prices", function()
    local shop = require('common.cfg.Shop')
    assert.are.equal(50, #shop.Goods)
    assert.are.equal(1, #shop.Excluded)
    assert.are.equal(27, shop.Excluded[1].number)
    local seen = {}
    for _, goods in ipairs(shop.Goods) do
      assert.is_not_nil(goods.source:match('^商店表!R%d+$'))
      assert.is_nil(seen[goods.number], '重复编号 ' .. goods.number)
      seen[goods.number] = true
      assert.is_true(goods.price > 0 and goods.price % 1 == 0)
      assert.is_true(goods.purchaseLimit >= 0 and goods.purchaseLimit % 1 == 0)
      assert.is_true(goods.minShopLevel >= 1 and goods.minShopLevel <= 7)
      assert.are_not.equal('夜明珠', goods.itemName)
      assert.are_not.equal('背包升级7', goods.itemName)
      assert.are.equal(true, goods.implemented, goods.source .. ' #130 起全量接入商店')
    end
    assert.is_nil(seen[27])
    assert.are.equal('新手鱼竿', shop.Goods[14].itemName)
    assert.are.equal(5, shop.Goods[14].price)
    assert.are.equal('商店表!R15', shop.Goods[14].source)
  end)

  it("test_upgrades_are_once_per_level", function()
    local goods = require('common.cfg.Shop').Goods
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
