-- #122 失败方式：把兑换链或鱼种掉落改成悬空引用后，check 必须报出原始表行
-- （物品表!R8 / 钓鱼表!R14），不能静默放行，也不能只报「有错」而不给定位。
-- 全量配置零错误与各表计数由 lua tools/validate_content.lua 接手（它就是同一 check 的入口）。
-- 迁移自 tests/gameplay/content_validation_test.lua（#83）；案例顺序沿用旧入口的方法名字典序。
local Validate = require('common.content_validation')
local cfg = require('common.game_cfg')

describe("TestContentValidation", function()
  it("test_broken_exchange_reports_row", function()
    local original = cfg.Content.Exchanges and cfg.Content.Exchanges[1] and cfg.Content.Exchanges[1].BossBait
    if not original then return end
    cfg.Content.Exchanges[1].BossBait = 'missing-bait'
    local result = Validate.check(cfg)
    cfg.Content.Exchanges[1].BossBait = original
    assert.matches('missing-bait', table.concat(result.errors, '\n'), nil, true)
  end)

  it("test_missing_drop_reports_original_row", function()
    local fish = cfg.Fish.eel
    local original = fish.Drops[1].ItemId
    fish.Drops[1].ItemId = 'missing-item'
    local result = Validate.check(cfg)
    fish.Drops[1].ItemId = original
    assert.matches('钓鱼表!R14', table.concat(result.errors, '\n'), nil, true)
    assert.matches('missing-item', table.concat(result.errors, '\n'), nil, true)
  end)
end)

-- #251 实现标记纯台账的静态门禁自检（与内容校验同源，不新增遗留测试文件）
local Ledger = require('common.cfg.content_ledger')

local GROUPS = { Fish = cfg.Fish, Items = cfg.Items.Definitions, Shop = cfg.Content.Shop.Goods,
    Lottery = cfg.Content.Lottery.Patterns, Blindbox = cfg.Content.Blindbox.Entries }

local function frozen(fn)
    return function()
        local ok, err = pcall(fn)
        return ok, err
    end
end

describe('内容标记纯台账', function()
  it('内容表不再自带实现标记，台账逐行覆盖五张表', function()
    for name, rows in pairs(GROUPS) do
      local ledger = assert(Ledger[name], '台账缺少 ' .. name)
      local seen = {}
      for key, row in pairs(rows) do
        assert.is_nil(row.implemented, name .. ' 的内容表仍有 implemented 字段：' .. tostring(key))
        local id = name == 'Shop' and row.number or (name == 'Lottery' or name == 'Blindbox') and row.number or key
        local entry = ledger[id]
        assert.is_truthy(entry, name .. ' 的台账漏登记 ' .. tostring(id))
        assert.are.equal(row.source, entry.source, name .. ' 的台账来源与内容表不一致：' .. tostring(id))
        seen[id] = true
      end
      for id in pairs(ledger) do
        assert.is_truthy(seen[id], name .. ' 的台账多登记了 ' .. tostring(id))
      end
    end
  end)

  it('标记未实现但已有实现路径判红', function()
    local entry = Ledger.Blindbox[1]
    local oldImplemented, oldPath = entry.implemented, entry.path
    entry.implemented, entry.path = false, 'server/world_host/player_blindbox.lua'
    local ok, err = frozen(function()
      local result = Validate.check(cfg)
      assert.matches('标记为未实现但已有实现路径', table.concat(result.errors, '\n'), nil, true)
      assert.matches(entry.source, table.concat(result.errors, '\n'), nil, true)
    end)()
    entry.implemented, entry.path = oldImplemented, oldPath
    assert.is_true(ok, err)
  end)

  it('标记已实现但没有代码落点判红', function()
    local entry = Ledger.Fish.tilapia
    local oldImplemented, oldPath = entry.implemented, entry.path
    entry.implemented, entry.path = true, nil
    local ok, err = frozen(function()
      local result = Validate.check(cfg)
      assert.matches('标记为已实现但没有代码落点', table.concat(result.errors, '\n'), nil, true)
      assert.matches(entry.source, table.concat(result.errors, '\n'), nil, true)
    end)()
    entry.implemented, entry.path = oldImplemented, oldPath
    assert.is_true(ok, err)
  end)

  it('全部已实现标记的代码落点都是真实业务文件', function()
    for name, ledger in pairs(Ledger) do
      for id, entry in pairs(ledger) do
        if entry.implemented then
          local prefix = tostring(entry.path):sub(1, 7)
          assert.is_truthy(prefix == 'server/' or prefix == 'client/' or tostring(entry.path):sub(1, 8) == 'common/',
            name .. ' ' .. tostring(id) .. ' 的落点不在业务树')
          local handle = io.open(entry.path, 'rb')
          assert.is_truthy(handle, name .. ' ' .. tostring(id) .. ' 的落点不存在：' .. tostring(entry.path))
          if handle then handle:close() end
        else
          assert.is_nil(entry.path, name .. ' ' .. tostring(id) .. ' 未实现却登记了落点')
        end
      end
    end
  end)

  it('火山岛鱼与盲盒的实现状态进入台账，占位模型不回归', function()
    local volcano = cfg.Fish.fish49Elite or cfg.Fish.volcano1
    local found
    for id, fish in pairs(cfg.Fish) do
      if fish.ZoneId == 'volcanoIsland' then found = fish break end
    end
    assert.is_truthy(found, '火山岛鱼不存在')
    assert.are.equal('7000546', found.Model)
    assert.is_true(Ledger.Fish[found.Id].implemented, found.Id)
    for _, row in ipairs(cfg.Content.Blindbox.Entries) do
      assert.is_true(Ledger.Blindbox[row.number].implemented, row.source)
      assert.are.equal('server/world_host/player_blindbox.lua', Ledger.Blindbox[row.number].path)
    end
  end)
end)