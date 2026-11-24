local ClientStore = require("client.Store.ClientStore")
local RootView = require("client.Views.RootView")
local LotteryView = require("client.Views.LotteryView")
local BlindboxView = require("client.Views.BlindboxView")
local PlatformShopView = require("client.Views.PlatformShopView")
local LotteryInteraction = require("client.Views.LotteryInteraction")
local Eui = require("tests.support.eui_double")

local M = {}
function M.new(options)
  options = options or {}
  local env = { sent = { lottery = {}, blindbox = {}, platform = {} }, notices = {}, sceneNodes = {} }
  env.oldVector, env.oldColor, env.oldVector3 = rawget(_G, "Vector2"), rawget(_G, "Color"), rawget(_G, "Vector3")
  _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
  _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
  _G.Color = { New = function(...) return { ... } end }
  env.store, env.writer = ClientStore.new()
  env.root = Eui.Node({ Name = "UIRoot" })
  env.view = RootView.mount(env.root, env.store, {
    services = {
      open_modal = function(id, payload) env.writer:open_modal(id, payload) end,
      close_modal = function(id) env.writer:close_modal(id) end,
      send_lottery = function(payload) table.insert(env.sent.lottery, payload) end,
      send_blindbox = function(payload) table.insert(env.sent.blindbox, payload) end,
      send_platform = function(payload) table.insert(env.sent.platform, payload) end,
      request_blindbox_state = function() env.sent.blindbox_state = (env.sent.blindbox_state or 0) + 1 end,
      notify = function(text) table.insert(env.notices, text) end,
      local_character = function() return options.character end,
      find_lottery_anchor = function(name) return options.anchors and options.anchors[name] or nil end,
      create_lottery_scene_node = function(_, anchor)
        local node = Eui.Node({ Name = "LotteryBubble" .. tostring(#env.sceneNodes + 1), Visible = false })
        node.Anchor = anchor
        env.sceneNodes[#env.sceneNodes + 1] = node
        return node
      end,
    },
    hud = { BlindboxView.entry_spec(), PlatformShopView.entry_spec() },
    overlays = options.interaction and { LotteryInteraction.spec() } or {},
    modals = {
      lottery = LotteryView.modal_spec(),
      blindbox = BlindboxView.modal_spec(),
      platform = PlatformShopView.modal_spec(),
    },
    create_node = function(kind, props)
      return Eui.Node({
        Kind = kind, Name = props and props.Name, Parent = props and props.Parent,
        Visible = props and props.Visible ~= false,
        Text = props and (props.Text or props.ButtonText) or "",
        Position = props and props.Position, Size = props and props.Size,
        TouchEnabled = kind == "EUIButton",
      })
    end,
  })
  function env:child(name)
    local found = self.root:FindFirstChild(name, true)
    if found then return found end
    for _, scene in ipairs(self.sceneNodes) do
      found = scene:FindFirstChild(name, true)
      if found then return found end
    end
    return nil
  end
  function env:click(name)
    local node = self:child(name)
    if not node then return false end
    return Eui.Click(node)
  end
  local function sync_spatial()
    if options.character ~= nil then
      env.writer:update_camera_target(options.character, nil)
      if options.character.Position ~= nil then
        env.writer:update_spatial(options.character.Position, {})
      end
    end
  end
  sync_spatial()
  function env:open(id) self.writer:open_modal(id) end
  function env:ingest(name, payload) self.writer:ingest_event(name, payload) end
  function env:step(dt)
    sync_spatial()
    self.writer:step_clock(dt)
  end
  function env:bar(snapshot) self:ingest("ItemBarState", snapshot) end
  function env:cleanup()
    if self.view then self.view:dispose(); self.view = nil end
    _G.Vector2, _G.Color, _G.Vector3 = self.oldVector, self.oldColor, self.oldVector3
  end
  return env
end
return M
