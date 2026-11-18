-- #122 失败方式：把兑换链或鱼种掉落改成悬空引用后，Check 必须报出原始表行
-- （物品表!R8 / 钓鱼表!R14），不能静默放行，也不能只报「有错」而不给定位。
-- 全量配置零错误与各表计数由 lua tools/validate_content.lua 接手（它就是同一 Check 的入口）。
-- 迁移自 tests/gameplay/content_validation_test.lua（#83）；案例顺序沿用旧入口的方法名字典序。
local Validate = require('common.ContentValidation')
local cfg = require('common.GameCfg')

describe("TestContentValidation", function()
  it("test_broken_exchange_reports_row", function()
    local original = cfg.Content.Exchanges and cfg.Content.Exchanges[1] and cfg.Content.Exchanges[1].BossBait
    if not original then return end
    cfg.Content.Exchanges[1].BossBait = 'missing-bait'
    local result = Validate.Check(cfg)
    cfg.Content.Exchanges[1].BossBait = original
    assert.matches('missing-bait', table.concat(result.errors, '\n'), nil, true)
  end)

  it("test_missing_drop_reports_original_row", function()
    local fish = cfg.Fish.eel
    local original = fish.Drops[1].ItemId
    fish.Drops[1].ItemId = 'missing-item'
    local result = Validate.Check(cfg)
    fish.Drops[1].ItemId = original
    assert.matches('钓鱼表!R14', table.concat(result.errors, '\n'), nil, true)
    assert.matches('missing-item', table.concat(result.errors, '\n'), nil, true)
  end)
end)
