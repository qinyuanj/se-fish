-- 严格引擎替身的保真合同：只认绕过合同里实测过的成员，越界访问当场报错。
local Engine = require('tests.support.engine_double')
local Fixtures = require('tests.support.zone_fixtures')

local function world()
  local marker = Engine.Unit({ Name = 'Z1_Safe', Position = { x = 1, y = 2, z = 3 }, Size = { x = 4, y = 5, z = 6 } })
  local folder = Engine.Unit({ Name = '摆渡', Children = { marker } })
  local zone = Engine.Unit({ Name = '01 鱼塘', Children = { folder } })
  return Engine.World({ zone }), zone, folder, marker
end

describe('严格引擎替身', function()
  it('World 根不支持 GetChildren', function()
    local root = world()
    assert.error_matches(function() root:GetChildren() end, 'World 没有成员 GetChildren', nil, true)
    assert.error_matches(function() Fixtures.World():GetChildren() end, 'World 没有成员 GetChildren', nil, true)
  end)

  it('递归查找只在 World 上，Unit 只找直接子级', function()
    local root, zone, folder, marker = world()
    assert.equals(marker, root:FindFirstChild('Z1_Safe'))
    assert.is_nil(zone:FindFirstChild('Z1_Safe'))
    assert.equals(marker, zone:FindFirstChild('摆渡'):FindFirstChild('Z1_Safe'))
    assert.same({ zone, folder, marker }, root:GetDescendants())
    assert.same({ folder, marker }, zone:GetDescendants())
  end)

  it('未声明的成员与属性直接报错', function()
    local root, zone, _, marker = world()
    assert.error_matches(function() return root.Name end, 'World 没有成员 Name', nil, true)
    assert.error_matches(function() return zone.children end, 'Unit 没有成员 children', nil, true)
    assert.error_matches(function() return marker.size end, 'Unit 没有成员 size', nil, true)
    assert.error_matches(function() return marker.GetProperty end, 'Unit 没有成员 GetProperty', nil, true)
    assert.error_matches(function() marker.Parent = zone end, 'Unit 不可写成员 Parent', nil, true)
  end)

  it('坐标是只认 x/y/z 的对象，整体改写也会转成坐标对象', function()
    local _, _, _, marker = world()
    assert.equals(3, marker.Position.z)
    assert.equals(5, marker.Size.y)
    assert.error_matches(function() return marker.Position.X end, 'Vector3 没有成员 X', nil, true)
    assert.error_matches(function() return marker.Position[1] end, 'Vector3 没有成员 1', nil, true)
    marker.Position = { x = 7, y = 8, z = 9 }
    assert.equals(8, marker.Position.y)
    assert.error_matches(function() return marker.Position.w end, 'Vector3 没有成员 w', nil, true)
  end)

  it('区域夹具的标记坐标同样是严格坐标对象', function()
    local safe = Fixtures.World():FindFirstChild('Z1_Safe')
    assert.equals(5.01, safe.Position.y)
    assert.error_matches(function() return safe.Position.w end, 'Vector3 没有成员 w', nil, true)
  end)
end)
