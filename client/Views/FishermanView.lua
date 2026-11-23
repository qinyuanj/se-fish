-- 钓鱼佬与确认弹窗统一视图（#311）。
-- 气泡按本地位置增量建拆；对话、确认与商店共用 RootView 的互斥模态相位。
local GameCfg = require("common.GameCfg")
local BodyScale = require("common.BodyScale")
local Dialogue = require("common.NpcDialogue")
local spoke = require("common.packages.spoke.api")
local State = spoke.State

local FishermanView = {}
local PULSE_FRAMES = 20
local PULSE_AMPLITUDE = 0.2

local function near(position, center, character)
  if type(position) ~= "table" or type(center) ~= "table" then return false end
  local dx, dz = position.x - center.x, position.z - center.z
  local radius = BodyScale.InteractionRadius(character, GameCfg.Interact.Fisherman.Radius)
  return dx * dx + dz * dz <= radius * radius
end

local function open_modal(ctx, id, payload)
  local fn = ctx.services and ctx.services.open_modal
  if type(fn) == "function" then fn(id, payload) end
end

local function close_modal(ctx, id)
  local fn = ctx.services and ctx.services.close_modal
  if type(fn) == "function" then fn(id) end
end

function FishermanView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  return {
    items = function(es, store)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local list = {}
      for _, entry in ipairs(options.anchors or {}) do
        if entry.npc and near(position, entry.position, character) then list[#list + 1] = entry end
      end
      return list
    end,
    key_of = function(entry)
      return "fisherman:" .. tostring(entry.index) .. ":" .. tostring(entry.name)
    end,
    mount = function(scope, ctx, item_signal)
      local entry = item_signal:now()
      local suffix = tostring(entry.index) .. "_" .. tostring(entry.name)
      local key = "fisherman:" .. tostring(entry.index) .. ":" .. tostring(entry.name)
      local create_scene = ctx.services and ctx.services.create_scene_node
      local node
      if type(create_scene) == "function" then
        node = ctx.own_node(scope, create_scene(entry, GameCfg.Interact.Fisherman.BubbleHeight, "fisherman"))
      else
        node = ctx.create_node(scope, "EUIImage", { Name = "SceneNodeFisherman_" .. suffix })
      end
      if node.Name == nil then node.Name = "SceneNodeFisherman_" .. suffix end
      local talk = ctx.create_node(scope, "EUIButton", {
        Name = "BtnFishermanTalk" .. suffix,
        Parent = node,
        ButtonText = "对话",
        TouchEnabled = true,
      })
      local feed = ctx.create_node(scope, "EUIButton", {
        Name = "BtnFishermanFeed" .. suffix,
        Parent = node,
        ButtonText = "喂食",
        TouchEnabled = true,
      })
      ctx.connect(scope, talk.OnClicked, function()
        open_modal(ctx, "fisherman", { zoneId = entry.npc.ZoneId, bubbleKey = key })
      end)
      ctx.connect(scope, feed.OnClicked, function()
        if options.shared then options.shared.last_feed_index = entry.index end
        local next_seq = ctx.services and ctx.services.next_seq
        local send = ctx.services and ctx.services.send_interact
        if type(send) == "function" then
          send({
            target = "fisherman",
            action = "Feed",
            seq = type(next_seq) == "function" and next_seq() or 1,
          })
        end
      end)
      scope:on_cleanup(function()
        local payload = ctx.store.modal_payload:now()
        if ctx.store.active_modal:now() == "fisherman" and type(payload) == "table"
            and payload.bubbleKey == key then
          close_modal(ctx, "fisherman")
        end
      end)
    end,
  }
end

function FishermanView.modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local panel = ctx.create_node(scope, "EUIImage", { Name = "FishermanDialog" })
    ctx.create_node(scope, "EUITextLabel", {
      Name = "LabelFishermanTitle", Parent = panel, Text = "钓鱼佬",
    })
    local lines = Dialogue.Lines(payload.zoneId) or { GameCfg.Interact.Fisherman.DialogText }
    for index, line in ipairs(lines) do
      ctx.create_node(scope, "EUITextLabel", {
        Name = "LabelFishermanLine" .. index,
        Parent = panel,
        Text = tostring(line),
      })
    end
    local close = ctx.create_node(scope, "EUIButton", {
      Name = "BtnFishermanClose", Parent = panel, ButtonText = "关闭", TouchEnabled = true,
    })
    ctx.connect(scope, close.OnClicked, function() close_modal(ctx, "fisherman") end)
  end
end

function FishermanView.confirm_modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local panel = ctx.create_node(scope, "EUIImage", { Name = "DialogNoticeConfirm" })
    ctx.create_node(scope, "EUITextLabel", {
      Name = "LabelText", Parent = panel, Text = tostring(payload.Msg or ""),
    })
    local yes = ctx.create_node(scope, "EUIButton", {
      Name = "BtnYes", Parent = panel, ButtonText = "是", TouchEnabled = true,
    })
    local no = ctx.create_node(scope, "EUIButton", {
      Name = "BtnNo", Parent = panel, ButtonText = "否", TouchEnabled = true,
    })
    local function finish(value)
      if type(payload.CallBack) == "function" then pcall(payload.CallBack, value) end
      close_modal(ctx, "confirm")
    end
    ctx.connect(scope, yes.OnClicked, function() finish(true) end)
    ctx.connect(scope, no.OnClicked, function() finish(false) end)
  end
end

function FishermanView.presentation_spec(options)
  options = type(options) == "table" and options or {}
  local shared = options.shared or {}
  local models = options.models or {}
  return {
    name = "FishermanPresentation",
    mount = function(scope, ctx)
      local function notify(text)
        local fn = ctx.services and ctx.services.notify
        if text and type(fn) == "function" then fn(text) end
      end
      scope:subscribe(ctx.store.on_server_event, function(event)
        if event.channel ~= "InteractResult" or type(event.payload) ~= "table" then return end
        local result = event.payload
        if result.action == GameCfg.Rescue.Action and result.reason == "busy" then
          notify("正在抢救中")
        end
        if not result.ok then
          if result.reason == "nothing" then notify("未选中可喂食物品")
          elseif result.reason == "full" then notify("交付失败：产物需要背包空位") end
          return
        end
        if result.achievement then
          notify("交付完成：解锁新成果")
        elseif result.exchange then
          notify("交付完成：" .. tostring(result.exchange.from) .. " → " .. tostring(result.exchange.to))
        elseif result.coins and result.coins > 0 then
          notify("喂食成功，获得 " .. tostring(result.coins) .. " 金币")
        end
        shared.pulse_left = PULSE_FRAMES
      end)
      scope:subscribe(ctx.clock.on_frame, function()
        if (shared.pulse_left or 0) <= 0 then return end
        shared.pulse_left = shared.pulse_left - 1
        local index = shared.last_feed_index
        local model = models[index]
        if not model then return end
        local base = model.baseScale or Vector3.New(1, 1, 1)
        local progress = 1 - shared.pulse_left / PULSE_FRAMES
        local scale = 1 + PULSE_AMPLITUDE * math.sin(math.pi * progress)
        local ok, err = pcall(function()
          model.unit.Scale = Vector3.New(base.x * scale, base.y * scale, base.z * scale)
        end)
        if not ok then
          print("[FishermanView] 模型缩放失败", index, tostring(err))
          models[index] = nil
        end
      end)
      scope:on_cleanup(function()
        for _, model in pairs(models) do
          if model.unit and model.baseScale then model.unit.Scale = model.baseScale end
        end
      end)
    end,
  }
end

function FishermanView.rescue_state(options)
  return {
    rows = State.new("FishermanView.rescue_rows", {}),
    get_players = options.get_players,
    get_local_player = options.get_local_player,
    is_squad_member = options.is_squad_member,
  }
end

function FishermanView.rescue_driver_spec(shared)
  return {
    name = "FishermanRescueDriver",
    mount = function(scope, ctx)
      local function refresh()
        local list = {}
        local me = type(shared.get_local_player) == "function" and shared.get_local_player() or nil
        local position = ctx.store.position:now()
        local players = type(shared.get_players) == "function" and shared.get_players() or {}
        if position then
          for _, player in ipairs(players) do
            local phase = player and player.GetAttribute and player:GetAttribute("SurvivalPhase") or nil
            local target = player and player.Character and player.Character.Position
            local squad_owned = type(shared.is_squad_member) == "function" and shared.is_squad_member(player and player.UserId)
            if player ~= me and not squad_owned and (phase == "downed" or phase == "rescuing") and target then
              local dx, dz = position.x - target.x, position.z - target.z
              if dx * dx + dz * dz <= GameCfg.Rescue.Range * GameCfg.Rescue.Range then
                list[#list + 1] = { userId = player.UserId, position = target }
              end
            end
          end
        end
        shared.rows:set(list)
      end
      scope:subscribe(ctx.clock.on_frame, refresh)
      refresh()
    end,
  }
end

function FishermanView.rescue_bubble_spec(shared)
  return {
    items = function(es) return es:d(shared.rows) end,
    key_of = function(row) return "rescue:" .. tostring(row.userId) end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now()
      local create_scene = ctx.services and ctx.services.create_scene_node
      local node
      if type(create_scene) == "function" then
        node = ctx.own_node(scope, create_scene(row, GameCfg.Rescue.BubbleHeight, "rescue"))
      else
        node = ctx.create_node(scope, "EUIImage", { Name = "SceneNodeRescue_" .. tostring(row.userId) })
      end
      local ok, button = pcall(ctx.create_node, scope, "EUIButton", {
        Name = "BtnRescue" .. tostring(row.userId),
        Parent = node,
        ButtonText = GameCfg.Rescue.PromptText,
        TouchEnabled = true,
      })
      if not ok then
        if node and type(node.Destroy) == "function" then node:Destroy() end
        print("[FishermanView] 抢救按钮创建失败", tostring(button))
        return
      end
      ctx.connect(scope, button.OnClicked, function()
        local next_seq = ctx.services and ctx.services.next_seq
        local send = ctx.services and ctx.services.send_interact
        if type(send) == "function" then
          send({
            target = GameCfg.Rescue.Target,
            action = GameCfg.Rescue.Action,
            targetUserId = row.userId,
            seq = type(next_seq) == "function" and next_seq() or 1,
          })
        end
      end)
    end,
  }
end

return FishermanView
