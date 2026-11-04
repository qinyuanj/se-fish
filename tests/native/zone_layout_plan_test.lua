local Fixtures = require('tests.support.zone_fixtures')
local Engine = require('tests.support.engine_double')
local GameCfg = require('common.GameCfg')
local ZoneMarkers = require('common.ZoneMarkers')

local function findChild(parent, name)
  return parent:FindFirstChild(name)
end

local function freshConfig()
  return Fixtures.Load()
end

describe('#164 场景标记读取合同', function()
  it('七区几何、17 个鱼饵点和六条航线来自同一快照', function()
    local cfg = freshConfig()
    assert.is_true(ZoneMarkers.Ready)
    assert.are.equal(17, #cfg.BaitSpots.Spots)
    assert.are.equal(7, #cfg.Zones)
    assert.are.equal(6, #cfg.Ferry.Routes)
    for index, zone in ipairs(cfg.Zones) do
      assert.are.equal('resolved', zone.Scene.State)
      assert.are.equal(index == 1 and 5 or 2, #zone.Scene.BaitSpots.Positions)
      assert.is_true(#zone.Scene.Waters > 0)
      assert.is_nil(zone.Scene.Land)
      for _, water in ipairs(zone.Scene.Waters) do
        assert.are.equal(zone.Id, water.ZoneId)
        assert.are.equal(cfg.Casting.Zones[zone.WaterId], cfg.Casting.Zones[water.Id])
      end
    end
    for index, route in ipairs(cfg.Ferry.Routes) do
      assert.are.equal(cfg.Zones[index + 1].Scene.SafePoint, route.Outbound.Destination)
      assert.are.equal(cfg.Zones[index].Scene.SafePoint, route.Return.Destination)
    end
  end)

  it('缺失标记明确失败且不发布半成品', function()
    local cfg = freshConfig()
    local previous = cfg.Zones[1].Scene
    local world = Fixtures.World()
    local zone = findChild(world, '01 鱼塘')
    local ferry = Engine.Children(findChild(zone, '摆渡'))
    for index, unit in ipairs(ferry) do
      if unit.Name == 'Z1_Safe' then table.remove(ferry, index) break end
    end
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, 'Z1_Safe', nil, true)
    assert.is_false(ZoneMarkers.Ready)
    assert.are.equal(previous, cfg.Zones[1].Scene)
  end)

  it('末条航线缺标记时航线与快照都不发布', function()
    local cfg = freshConfig()
    local destination = cfg.Ferry.Routes[1].Outbound.Destination
    local world = Fixtures.World()
    local ferry = Engine.Children(findChild(findChild(world, '07 火山岛'), '摆渡'))
    for index, unit in ipairs(ferry) do
      if unit.Name == 'Z7_FerryReturn' then table.remove(ferry, index) break end
    end
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, 'Z7_FerryReturn', nil, true)
    assert.are.equal(destination, cfg.Ferry.Routes[1].Outbound.Destination)
    assert.is_false(ZoneMarkers.Ready)
    assert.are.same({}, ZoneMarkers.Zones)
  end)

  it('标记摆在别的区或越出本区边界明确失败', function()
    local cfg = freshConfig()
    local world = Fixtures.World()
    local grill = findChild(findChild(findChild(world, '03 蟹湖'), '设施'), 'Z3_Grill')
    local facilities = Engine.Children(findChild(findChild(world, '03 蟹湖'), '设施'))
    for index, unit in ipairs(facilities) do
      if unit == grill then table.remove(facilities, index) break end
    end
    local other = Engine.Children(findChild(findChild(world, '04 树林岛'), '设施'))
    other[#other + 1] = grill
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '不在所属区', nil, true)

    world = Fixtures.World()
    local lottery = findChild(findChild(findChild(world, '02 虾池'), '设施'), 'Z2_Lottery')
    lottery.Position = { x = -10000, y = 0, z = 0 }
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '越出本区边界', nil, true)
  end)

  it('其他区出现同名单位也算重名', function()
    local cfg = freshConfig()
    local world = Fixtures.World()
    local decor = Engine.Children(findChild(findChild(world, '05 沙滩岛'), '设施'))
    decor[#decor + 1] = Engine.Unit({ Name = 'Z3_Grill', Position = { x = 0, y = 0, z = 0 } })
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '重名', nil, true)
  end)

  it('重名标记明确失败', function()
    local cfg = freshConfig()
    local world = Fixtures.World()
    local zone = findChild(world, '01 鱼塘')
    local ferry = findChild(zone, '摆渡')
    local safe = findChild(ferry, 'Z1_Safe')
    local children = Engine.Children(ferry)
    children[#children + 1] = safe
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '重名', nil, true)
    assert.is_false(ZoneMarkers.Ready)
  end)

  for _, bad in ipairs({ 0, -1, math.huge, 0 / 0 }) do
    it('非法水域尺寸明确失败: ' .. tostring(bad), function()
      local cfg = freshConfig()
      local world = Fixtures.World()
      local zone = findChild(world, '01 鱼塘')
      local waters = findChild(zone, '水域')
      local water = findChild(waters, 'Z1_Water1')
      local size = water.Size
      Engine.SetSize(water, { x = bad, y = size.y, z = size.z })
      assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '尺寸非法', nil, true)
      assert.is_false(ZoneMarkers.Ready)
    end)
  end

  it('水域重叠明确失败，主鱼表绑定不随附加标记排序漂移', function()
    local cfg = freshConfig()
    local world = Fixtures.World()
    local zone = findChild(world, '01 鱼塘')
    local waters = findChild(zone, '水域')
    local primary = findChild(waters, 'Z1_Water1')
    local extra = findChild(waters, 'Z1_Water2')
    extra.Position = { x = primary.Position.x, y = primary.Position.y, z = primary.Position.z }
    assert.error_matches(function() ZoneMarkers.Resolve(world, cfg) end, '水域重叠', nil, true)
    assert.is_false(ZoneMarkers.Ready)
  end)

  it('静态配置没有区域坐标，解析后飞行兜底边界取首区', function()
    package.loaded['common.GameCfg'] = nil
    local bare = require('common.GameCfg')
    assert.is_nil(bare.Zones[1].Scene)
    assert.are.equal(0, #bare.Water.Zones)
    assert.are.equal(0, #bare.BaitSpots.Spots)
    assert.is_nil(bare.Ability.Flight.FallbackBounds)
    local cfg = Fixtures.Apply(bare)
    assert.same(cfg.Zones[1].Scene.Boundary.MinX, cfg.Ability.Flight.FallbackBounds.MinX)
    assert.same(cfg.Zones[1].Scene.Boundary.MaxZ, cfg.Ability.Flight.FallbackBounds.MaxZ)
  end)
end)
