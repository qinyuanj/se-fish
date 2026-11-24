local eui = require("tests.support.eui_double")
local client_store = require("client.store.client_store")
local root_view = require("client.views.root_view")
local cast_source_view = require("client.views.cast_source_view")
local spoke_clock = require("common.spoke_clock")

describe("礁石来源可视化宿主接缝（#302）", function()
  local saved_v3, saved_color
  before_each(function()
    saved_v3, saved_color = rawget(_G, "Vector3"), rawget(_G, "Color")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
  end)
  after_each(function()
    _G.Vector3, _G.Color = saved_v3, saved_color
  end)

  it("同一上钩快照复用来源，脱钩销毁来源与钓线", function()
    local clock = spoke_clock.new(0)
    local store, writer = client_store.new({ clock = clock })
    local root = eui.Node({ Name = "UIRoot" })
    local units = {}
    local view = root_view.mount(root, store, {
      services = {
        create_unit = function(kind, props)
          local unit = eui.Node({ Name = props.Name, Kind = kind, Position = props.Position })
          unit.Destroyed = false
          units[#units + 1] = unit
          return unit
        end,
        reel = { active = function() return true end, progress = function() return 75 end },
      },
      hud = { cast_source_view.spec() },
      create_node = function(kind, props) return eui.Node({ Kind = kind, Name = props.Name, Parent = props.Parent }) end,
    })
    writer:ingest_event("CastState", { phase = "hooked", castId = 37, fishId = "item81", reelSession = "s37",
      hookPosition = { x = 880, y = 15, z = 144 } })
    assert.are.equal(2, #units)
    local body = units[1]
    assert.are.equal("CastSource_37", body.Name)
    assert.are.equal(15, body.Position.y)
    writer:ingest_event("CastState", { phase = "hooked", castId = 37, fishId = "item81", reelSession = "s37",
      hookPosition = { x = 880, y = 15, z = 144 } })
    assert.are.equal(2, #units)
    writer:ingest_event("CastState", { phase = "unhooked", castId = 37 })
    assert.is_true(body.Destroyed)
    assert.is_true(units[2].Destroyed)
    view:dispose()
  end)
end)
