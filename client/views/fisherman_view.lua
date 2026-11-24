local game_cfg = require("common.game_cfg")
local body_scale = require("common.body_scale")
local dialogue = require("common.npc_dialogue")
local spoke = require("common.packages.spoke.api")
local view_util = require("client.views.view_util")
local rescue_view = require("client.views.rescue_view")

local State = spoke.State
local fisherman_view = {}
local PULSE_FRAMES = 20
local PULSE_AMPLITUDE = 0.2

local function near(position, center, character)
  local dist_sq = view_util.distance_sq_xz(position, center)
  if dist_sq == nil then return false end
  local radius = body_scale.InteractionRadius(character, game_cfg.Interact.Fisherman.Radius)
  return dist_sq <= radius * radius
end

local function open_modal(ctx, id, payload)
  local fn = ctx.services and ctx.services.open_modal
  if type(fn) == "function" then fn(id, payload) end
end

local function close_modal(ctx, id)
  local fn = ctx.services and ctx.services.close_modal
  if type(fn) == "function" then fn(id) end
end

function fisherman_view.bubble_spec(options)
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
      local node = view_util.create_anchor_scene_node(
        scope, ctx, entry, game_cfg.Interact.Fisherman.BubbleHeight, "fisherman", "SceneNodeFisherman_" .. suffix
      )
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

function fisherman_view.modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local panel = ctx.create_node(scope, "EUIImage", { Name = "FishermanDialog" })
    ctx.create_node(scope, "EUITextLabel", {
      Name = "LabelFishermanTitle", Parent = panel, Text = "钓鱼佬",
    })
    local lines = dialogue.Lines(payload.zoneId) or { game_cfg.Interact.Fisherman.DialogText }
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

function fisherman_view.confirm_modal_spec()
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
      if type(payload.CallBack) == "function" then
        local ok, err = pcall(payload.CallBack, value)
        if not ok then
          print("[fisherman_view] 确认弹窗回调执行失败", tostring(err))
        end
      end
      close_modal(ctx, "confirm")
    end
    ctx.connect(scope, yes.OnClicked, function() finish(true) end)
    ctx.connect(scope, no.OnClicked, function() finish(false) end)
  end
end

function fisherman_view.presentation_spec(options)
  options = type(options) == "table" and options or {}
  local shared = options.shared or {}
  local models = options.models or {}
  return {
    name = "FishermanPresentation",
    mount = function(scope, ctx)
      local pulse_active = State.new("fisherman_view.pulse_active", false)

      scope:subscribe(ctx.store.on_server_event, function(event)
        if event.channel ~= "InteractResult" or type(event.payload) ~= "table" then return end
        local result = event.payload
        if result.action == game_cfg.Rescue.Action and result.reason == "busy" then
          view_util.notify(ctx, "正在抢救中")
        end
        if not result.ok then
          if result.reason == "nothing" then view_util.notify(ctx, "未选中可喂食物品")
          elseif result.reason == "full" then view_util.notify(ctx, "交付失败：产物需要背包空位") end
          return
        end
        if result.achievement then
          view_util.notify(ctx, "交付完成：解锁新成果")
        elseif result.exchange then
          view_util.notify(ctx, "交付完成：" .. tostring(result.exchange.from) .. " → " .. tostring(result.exchange.to))
        elseif result.coins and result.coins > 0 then
          view_util.notify(ctx, "喂食成功，获得 " .. tostring(result.coins) .. " 金币")
        end
        shared.pulse_left = PULSE_FRAMES
        pulse_active:set(true)
      end)

      scope:phase("FishermanPulsePhase", pulse_active, function(ps)
        ps:subscribe(ctx.clock.on_frame, function()
          local left = shared.pulse_left or 0
          if left <= 0 then
            pulse_active:set(false)
            return
          end
          left = left - 1
          shared.pulse_left = left
          local index = shared.last_feed_index
          local model = models[index]
          if not model then
            if left <= 0 then pulse_active:set(false) end
            return
          end
          local base = model.baseScale or Vector3.New(1, 1, 1)
          local progress = 1 - left / PULSE_FRAMES
          local scale = 1 + PULSE_AMPLITUDE * math.sin(math.pi * progress)
          local ok, err = pcall(function()
            model.unit.Scale = Vector3.New(base.x * scale, base.y * scale, base.z * scale)
          end)
          if not ok then
            print("[fisherman_view] 模型缩放失败", index, tostring(err))
            models[index] = nil
          end
          if left <= 0 then
            pulse_active:set(false)
          end
        end)
      end)

      scope:on_cleanup(function()
        for _, model in pairs(models) do
          if model.unit and model.baseScale then
            local ok, err = pcall(function() model.unit.Scale = model.baseScale end)
            if not ok then print("[fisherman_view] 模型缩放恢复失败", tostring(err)) end
          end
        end
      end)
    end,
  }
end

function fisherman_view.rescue_state(options)
  return rescue_view.create_state("fisherman_view.rescue_rows", options)
end

function fisherman_view.rescue_driver_spec(shared)
  return rescue_view.driver_spec(shared, {
    name = "FishermanRescueDriver",
    mode = "world",
  })
end

function fisherman_view.rescue_bubble_spec(shared)
  return rescue_view.bubble_spec(shared, {
    key_prefix = "rescue:",
    scene_kind = "rescue",
    scene_prefix = "SceneNodeRescue_",
    button_prefix = "BtnRescue",
    log_tag = "[fisherman_view]",
    fail_label = "抢救按钮创建失败",
  })
end

return fisherman_view
