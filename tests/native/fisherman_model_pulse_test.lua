local GameCfg = require("common.game_cfg")
local ZoneMarkers = require("common.zone_markers")
local ClientStore = require("client.store.client_store")
local RootView = require("client.views.root_view")
local FishermanView = require("client.views.fisherman_view")
local Eui = require("tests.support.eui_double")

local function model(scale) return { Scale = { x = scale, y = scale, z = scale } } end
local function base(scale) return { x = scale, y = scale, z = scale } end

describe("钓鱼佬模型按区脉冲", function()
  local old_vector, saved_ready, saved_positions
  before_each(function()
    old_vector = rawget(_G, "Vector3")
    saved_ready, saved_positions = ZoneMarkers.ready, ZoneMarkers.anchor_positions
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    ZoneMarkers.ready = true
    ZoneMarkers.anchor_positions = {}
    for index, npc in ipairs(GameCfg.Interact.Fishermen) do
      ZoneMarkers.anchor_positions[npc.AnchorNames[1]] = { x = index * 20, y = 0, z = 0 }
    end
  end)
  after_each(function()
    ZoneMarkers.ready, ZoneMarkers.anchor_positions = saved_ready, saved_positions
    _G.Vector3 = old_vector
  end)

  local function mount(models)
    local store, writer = ClientStore.new({ initial_now = 1000 })
    local shared, sent = {}, {}
    local anchors = {}
    for index, npc in ipairs(GameCfg.Interact.Fishermen) do
      anchors[#anchors + 1] = {
        npc = npc, name = npc.AnchorNames[1], index = index,
        position = { x = index * 20, y = 0, z = 0 },
      }
    end
    local root = Eui.node({ Name = "UIRoot" })
    RootView.mount(root, store, {
      hud = { FishermanView.presentation_spec({ shared = shared, models = models }) },
      docks = { fisherman = FishermanView.bubble_spec({ shared = shared, anchors = anchors }) },
      services = {
        send_interact = function(payload) sent[#sent + 1] = payload end,
        next_seq = function() return #sent + 1 end,
      },
      create_node = function(kind, props)
        return Eui.node({
          Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
          Text = props and (props.Text or props.ButtonText) or "",
          TouchEnabled = kind == "EUIButton",
        })
      end,
    })
    local function feed(index)
      writer:update_spatial({ x = index * 20, y = 0, z = 0 }, {})
      local name = GameCfg.Interact.Fishermen[index].AnchorNames[1]
      local button = root:FindFirstChild("BtnFishermanFeed" .. index .. "_" .. name, true)
      assert.is_true(Eui.click(button))
      writer:ingest_event("InteractResult", { ok = true, action = "Feed", coins = 1 })
    end
    return root, writer, sent, feed
  end

  local function frames(writer, count)
    for _ = 1, count or 20 + 2 do
      writer:advance_clock(1 / 60)
    end
  end

  it("每区一个模型名，01 沿用 FishermanModel，名字互不重复", function()
    local names = {}
    for index, npc in ipairs(GameCfg.Interact.Fishermen) do names[index] = npc.ModelName end
    assert.same({ "FishermanModel", "Z2_FishermanModel", "Z3_FishermanModel", "Z4_FishermanModel",
      "Z5_FishermanModel", "Z6_FishermanModel", "Z7_FishermanModel" }, names)
  end)

  it("喂 03 只脉冲 03 的模型，结束还原基准缩放", function()
    local first, third = model(1), model(2)
    local root, writer, sent, feed = mount({
      [1] = { unit = first, baseScale = base(1) },
      [3] = { unit = third, baseScale = base(2) },
    })
    feed(3)
    assert.same("Feed", sent[1].action)
    local peak = 0
    for _ = 1, 20 + 2 do
      writer:advance_clock(1 / 60)
      peak = math.max(peak, third.Scale.x)
    end
    assert.is_true(peak > 2)
    assert.same({ x = 2, y = 2, z = 2 }, third.Scale)
    assert.same({ x = 1, y = 1, z = 1 }, first.Scale)
    root:Destroy()
  end)

  it("喂食所在区缺模型时不播，别区照常", function()
    local first = model(1)
    local root, writer, _, feed = mount({ [1] = { unit = first, baseScale = base(1) } })
    feed(5)
    frames(writer)
    assert.same({ x = 1, y = 1, z = 1 }, first.Scale)
    feed(1)
    writer:advance_clock(1 / 60)
    assert.is_true(first.Scale.x > 1)
    frames(writer)
    root:Destroy()
  end)

  it("7 个钓鱼区模型均可独立脉冲并互不串扰 (#407)", function()
    local units, models = {}, {}
    for index = 1, 7 do
      units[index] = model(1 + index * 0.1)
      models[index] = { unit = units[index], baseScale = base(1 + index * 0.1) }
    end
    local root, writer, _, feed = mount(models)
    for target = 1, 7 do
      feed(target)
      local peak = 0
      for _ = 1, 20 + 2 do
        writer:advance_clock(1 / 60)
        peak = math.max(peak, units[target].Scale.x)
      end
      assert.is_true(peak > 1 + target * 0.1)
      for other = 1, 7 do
        local expected = 1 + other * 0.1
        assert.is_true(math.abs(units[other].Scale.x - expected) < 1e-6)
      end
    end
    root:Destroy()
  end)

  it("写 Scale 失败后丢弃该模型，不再重试", function()
    local writes = 0
    local broken = setmetatable({}, {
      __index = function(_, key)
        if key == "Scale" then return { x = 1, y = 1, z = 1 } end
      end,
      __newindex = function() writes = writes + 1 error("locked") end,
    })
    local root, writer, _, feed = mount({ [1] = { unit = broken, baseScale = base(1) } })
    feed(1)
    frames(writer)
    assert.same(1, writes)
    root:Destroy()
  end)
end)
