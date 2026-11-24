local Eui = require('tests.support.eui_double')

describe('EUI 交互测试夹具', function()
  it('Disabled 写入复刻单向触摸副作用', function()
    local node = Eui.node{ TouchEnabled = true }

    node.Disabled = true
    assert.is_false(node.TouchEnabled)
    node.Disabled = false
    assert.is_false(node.TouchEnabled)

    node.TouchEnabled = true
    assert.is_true(node.TouchEnabled)
  end)

  it('Click 按可见性和触摸状态门控，不额外拦截 Disabled', function()
    local node = Eui.node{ TouchEnabled = true }
    local calls = 0
    node.OnClicked:Connect(function() calls = calls + 1 end)

    node.Disabled = true
    node.TouchEnabled = true
    assert.is_true(Eui.click(node))
    assert.equal(1, calls)

    node.TouchEnabled = false
    assert.is_false(Eui.click(node))
    node.TouchEnabled = true
    node.Visible = false
    assert.is_false(Eui.click(node))
    node.Visible = true
    node:Destroy()
    assert.is_false(Eui.click(node))
    assert.equal(1, calls)
  end)

  it('保留层级查询、递归销毁和父节点脱离语义', function()
    local root = Eui.node{ Name = 'root' }
    local parent = Eui.node{ Name = 'parent', Parent = root }
    local child = Eui.node{ Name = 'child', Parent = parent }

    assert.equal(child, root:FindFirstChild('child', true))
    parent:Destroy()
    assert.is_nil(root.children.parent)
    assert.is_true(parent.Destroyed)
    assert.is_true(child.Destroyed)
  end)
end)
