-- EUI 交互测试夹具：只模拟当前节点，不推导屏幕几何或祖先命中。
-- #235 宿主实测：写 Disabled=true 会顺带关闭 TouchEnabled；写 false 不会恢复；
-- 之后显式打开 TouchEnabled，Disabled=true 本身不会阻止 OnClicked。
local M = {}

function M.Signal()
  local listeners = {}
  return {
    Connect = function(_, fn)
      listeners[#listeners + 1] = fn
      return { Disconnect = function()
        for i, callback in ipairs(listeners) do
          if callback == fn then table.remove(listeners, i) break end
        end
      end }
    end,
    Fire = function(_, ...)
      for _, callback in ipairs(listeners) do callback(...) end
    end,
  }
end

-- spec: { Name?, Kind?, Parent?, Children?, Visible?=true, Text?, TouchEnabled?, OnClicked? }。
-- Disabled 由调用方显式写入，避免构造参数掩盖属性写入顺序。
function M.Node(spec)
  spec = spec or {}
  local fields = {
    Name = spec.Name,
    Kind = spec.Kind,
    Visible = spec.Visible ~= false,
    Text = spec.Text or '',
    Children = spec.Children or {},
    TouchEnabled = spec.TouchEnabled,
    OnClicked = spec.OnClicked or M.Signal(),
  }
  local node = setmetatable({}, {
    __index = fields,
    __newindex = function(_, key, value)
      if key == 'Disabled' and value == true then fields.TouchEnabled = false end
      fields[key] = value
    end,
  })

  function fields:FindFirstChild(name, recursive)
    local hit = self.Children[name]
    if hit or not recursive then return hit end
    for _, child in pairs(self.Children) do
      hit = child:FindFirstChild(name, true)
      if hit then return hit end
    end
  end

  function fields:Destroy()
    self.Destroyed = true
    if self.Parent and self.Parent.Children[self.Name] == self then
      self.Parent.Children[self.Name] = nil
    end
    local children = self.Children
    self.Children = {}
    for _, child in pairs(children) do child:Destroy() end
  end

  if spec.Parent then
    assert(spec.Name, '挂到父节点的 EUI 节点必须有 Name')
    node.Parent = spec.Parent
    spec.Parent.Children[spec.Name] = node
  end
  return node
end

-- 返回是否命中；命中才转发 OnClicked。Disabled 不在这里重复门控。
function M.Click(node, ...)
  if node.Destroyed or not node.Visible or not node.TouchEnabled then return false end
  node.OnClicked:Fire(...)
  return true
end

return M
