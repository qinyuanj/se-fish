-- 条款 5-01 / 5-03（docs/acceptance/05-zone-fish-data.md）：
--   5-01 鱼种表恰好 98 条记录，分属七个区（鱼塘、虾池、蟹湖、树林岛、沙滩岛、礁石岛、火山岛），每区 14 条；
--   5-03 品级只取普通、极品、精英、首领四种，每区恰好 6 条普通、6 条极品、1 条精英、1 条首领。
-- 视图从运行期 GameCfg 派生行、品级与总数，所以断言直接落在玩家可见的七区图鉴上，不引用内部函数。
local function count(map)
  local n = 0
  for _ in pairs(map) do n = n + 1 end
  return n
end

describe('条款 5-01：七区鱼种数量', function()
  local env

  before_each(function()
    env = { saved = {} }
    for _, name in ipairs({ 'common.REUtil', 'client.GameUI' }) do
      env.saved[name] = package.loaded[name]
    end
    for _, name in ipairs({ 'game', 'Vector2', 'Color', 'MgrGameUI' }) do
      env.saved[name] = rawget(_G, name)
    end
    package.loaded['common.REUtil'] = { GetRE = function() return { FireServer = function() end } end }
    package.loaded['client.GameUI'] = {
      GetEuiManager = function() return { GetDeviceResolution = function() return { x = 1920, y = 1080 } end } end,
    }
    _G.game = { GetService = function() return {} end }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.MgrGameUI = {}
    env.Screen = require('client.Views.CompendiumView')
  end)

  after_each(function()
    for name, value in pairs(env.saved) do
      if name:find('%.') then package.loaded[name] = value else rawset(_G, name, value) end
    end
  end)

  it('七页各 14 条，总数 98，区名不重复', function()
    local zones, total = {}, nil
    for page = 1, 7 do
      local view = env.Screen.page_spec(page)
      total = view.total
      assert.are.equal(14, #view.entries, '第 ' .. page .. ' 页不是 14 条')
      assert.is_truthy(view.zone, '第 ' .. page .. ' 页没有区名')
      assert.is_nil(zones[view.zone], '区名重复：' .. tostring(view.zone))
      zones[view.zone] = true
    end
    assert.are.equal(98, total, '图鉴总数不是 98')
    assert.are.equal(7, count(zones), '不是七个区')
  end)

  it('每区恰好 6 普通、6 极品、1 精英、1 首领', function()
    for page = 1, 7 do
      local view = env.Screen.page_spec(page)
      local grades = {}
      for _, entry in ipairs(view.entries) do
        grades[entry.grade] = (grades[entry.grade] or 0) + 1
      end
      assert.same({ ['普通'] = 6, ['极品'] = 6, ['精英'] = 1, ['首领'] = 1 }, grades, view.zone)
    end
  end)
end)
