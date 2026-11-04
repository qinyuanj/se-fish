-- 严格引擎替身（单一来源）：只暴露真引擎已实测的成员，未声明的访问直接报错，避免夹具掩盖生产缺陷。
-- 依据 docs/技术难点识别.md「绕过合同」：World 根没有 GetChildren，递归 FindFirstChild 只在 World 上，
-- Unit:FindFirstChild 只匹配直接子级。测试侧改写场景走 M.Children / M.SetSize，不给替身加字段。
local M = {}

local states = setmetatable({}, { __mode = 'k' })

local VectorMeta = {
  __index = function(_, key) error('Vector3 没有成员 ' .. tostring(key), 2) end,
  __newindex = function(_, key) error('Vector3 不可写成员 ' .. tostring(key), 2) end,
}

function M.Vector(x, y, z)
  return setmetatable({ x = x, y = y, z = z }, VectorMeta)
end

local function toVector(value)
  if value == nil then return nil end
  return M.Vector(value.x, value.y, value.z)
end

local function descendants(node, out)
  for _, child in ipairs(states[node].children) do
    out[#out + 1] = child
    descendants(child, out)
  end
  return out
end

local function directChild(node, name)
  for _, child in ipairs(states[node].children) do
    if child.Name == name then return child end
  end
end

local function recursiveChild(node, name)
  for _, child in ipairs(descendants(node, {})) do
    if child.Name == name then return child end
  end
end

local function strict(kind, state, members, writable)
  local proxy = setmetatable({}, {
    __index = function(self, key)
      local member = members[key]
      if member == nil then error(kind .. ' 没有成员 ' .. tostring(key), 2) end
      return member(self, state)
    end,
    __newindex = function(_, key, value)
      local write = writable[key]
      if write == nil then error(kind .. ' 不可写成员 ' .. tostring(key), 2) end
      write(state, value)
    end,
  })
  states[proxy] = state
  return proxy
end

local function method(fn)
  return function() return fn end
end

local unitMembers = {
  Name = function(_, state) return state.name end,
  Position = function(_, state) return state.position end,
  GetChildren = method(function(self)
    return { table.unpack(states[self].children) }
  end),
  GetDescendants = method(function(self) return descendants(self, {}) end),
  FindFirstChild = method(directChild),
  GetProperty = method(function(self, key)
    if key ~= 'Size' then error('Unit 没有属性 ' .. tostring(key), 2) end
    return toVector(states[self].size)
  end),
}

local unitWritable = {
  Name = function(state, value) state.name = value end,
  Position = function(state, value) state.position = toVector(value) end,
}

-- spec: { Name, Position?, Size?, Children? }；坐标可传任意带 x/y/z 的表，入口统一转成严格坐标。
function M.Unit(spec)
  return strict('Unit', {
    name = spec.Name, position = toVector(spec.Position), size = toVector(spec.Size),
    children = spec.Children or {},
  }, unitMembers, unitWritable)
end

local worldMembers = {
  GetDescendants = method(function(self) return descendants(self, {}) end),
  FindFirstChild = method(recursiveChild),
}

function M.World(children)
  return strict('World', { children = children or {} }, worldMembers, {})
end

-- 测试侧句柄：返回节点的活子级列表，增删即改场景；生产代码只能经 GetChildren 拿到副本。
function M.Children(node)
  return states[node].children
end

function M.SetSize(unit, size)
  states[unit].size = toVector(size)
end

return M
