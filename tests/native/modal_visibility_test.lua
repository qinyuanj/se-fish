-- 弹窗可见性：#276 实机取证时发现弹窗被放在 (0,0)（EUI 的 Position 是中心点），
-- 面板四分之三落在屏幕外，且面板与按钮都不带配色，实机是白底白字。
-- 这里守住两件事：面板落在界面中心、面板与按钮带不透明底色。
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local CompendiumView = require("client.views.compendium_view")
local Eui = require("tests.support.eui_double")

local function child(root, name)
  return root:FindFirstChild(name, true)
end

describe("弹窗定位与配色", function()
  local root, store, writer, view, oldVector, oldColor

  before_each(function()
    oldVector, oldColor = rawget(_G, "Vector2"), rawget(_G, "Color")
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    store, writer = ClientStore.new()
    root = Eui.node({ Name = "UIRoot", Size = { x = 2280, y = 1080 } })
    view = RootView.mount(root, store, {
      services = {
        open_modal = function(id, payload) writer:open_modal(id, payload) end,
        close_modal = function(id) writer:close_modal(id) end,
        request_compendium = function() end,
        request_records = function() end,
        get_device_resolution = function() return { x = 2280, y = 1080 } end,
      },
      hud = { CompendiumView.entry_spec() },
      modals = { compendium = CompendiumView.modal_spec() },
      create_node = function(kind, props)
        local node = Eui.node({
          Kind = kind,
          Name = props and props.Name,
          Parent = props and props.Parent,
          Visible = props and props.Visible,
          Text = props and props.Text,
          Position = props and props.Position,
          Size = props and props.Size,
          TouchEnabled = kind == "EUIButton",
        })
        if props and props.ButtonText ~= nil then
          node.ButtonText = props.ButtonText
        end
        return node
      end,
    })
  end)

  after_each(function()
    if view then view:dispose() end
    _G.Vector2, _G.Color = oldVector, oldColor
  end)

  it("面板落在界面中心，不再钉在左下角", function()
    Eui.click(child(root, "BtnCompendiumEntry"))
    local panel = child(root, "ScreenCompendium")
    assert.is_not_nil(panel)
    assert.are.equal(1140, panel.Position.x)
    assert.are.equal(540, panel.Position.y)
  end)

  it("面板与入口按钮都带不透明底色", function()
    local entry = child(root, "BtnCompendiumEntry")
    assert.is_not_nil(entry)
    assert.is_not_nil(entry.ButtonNormalColor)
    assert.is_true(entry.ButtonNormalColor.a > 200)

    Eui.click(entry)
    local panel = child(root, "ScreenCompendium")
    assert.is_not_nil(panel)
    assert.is_not_nil(panel.Color)
    assert.is_true(panel.Color.a > 200)
  end)
end)
