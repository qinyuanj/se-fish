local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local Dialogue = require("common.npc_dialogue")
local Spoke = require("common.packages.spoke.api")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local InteractPromptArbiter = require("client.views.interact_prompt_arbiter")
local RescueView = require("client.views.rescue_view")
local Modal = require("client.views.economy_modal")

local State = Spoke.State
local FishermanView = {}
local PULSE_FRAMES = 20
local PULSE_AMPLITUDE = 0.2

local DIALOG_W = 928
local DIALOG_H = 640
local CONFIRM_W = 640
local CONFIRM_H = 340
local PAD = Tokens.SPACE.PANEL_PAD

local function near(position, center, character)
  local dist_sq = ViewUtil.distance_sq_xz(position, center)
  if dist_sq == nil then return false end
  local radius = BodyScale.interaction_radius(character, GameCfg.Interact.Fisherman.Radius)
  return dist_sq <= radius * radius
end

function FishermanView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  return {
    items = function(es, store)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local list = {}
      for _, entry in ipairs(options.anchors or {}) do
        if entry.npc and near(position, entry.position, character)
            and InteractPromptArbiter.is_exclusive(position, character, entry.name) then
          list[#list + 1] = entry
        end
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
      local node = ViewUtil.create_anchor_scene_node(
        scope, ctx, entry, GameCfg.Interact.Fisherman.BubbleHeight, "fisherman", "SceneNodeFisherman_" .. suffix
      )
      Controls.button(scope, ctx, {
        name = "BtnFishermanTalk" .. suffix,
        parent = node,
        rect = Layout.rect(52, 24, 96, 44),
        text = "对话",
        variant = "blue",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = 2,
        on_click = function()
          Modal.open_modal(ctx, "fisherman", { zoneId = entry.npc.ZoneId, bubbleKey = key })
        end,
      })
      Controls.button(scope, ctx, {
        name = "BtnFishermanFeed" .. suffix,
        parent = node,
        rect = Layout.rect(156, 24, 96, 44),
        text = "喂食",
        variant = "gold",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = 2,
        on_click = function()
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
        end,
      })
      scope:on_cleanup(function()
        local payload = ctx.store.modal_payload:now()
        if ctx.store.active_modal:now() == "fisherman" and type(payload) == "table"
            and payload.bubbleKey == key then
          Modal.close_modal(ctx, "fisherman")
        end
      end)
    end,
  }
end

function FishermanView.modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local shell = Controls.modal_shell(scope, ctx, {
      name = "PanelFisherman",
      title = "钓鱼佬",
      title_name = "LabelFishermanTitle",
      close_name = "BtnFishermanClose",
      width = DIALOG_W,
      height = DIALOG_H,
      on_close = function() Modal.close_modal(ctx, "fisherman") end,
    })
    local panel = shell.panel
    local lines = Dialogue.Lines(payload.zoneId) or { GameCfg.Interact.Fisherman.DialogText }
    local count = math.max(1, #lines)
    local area_top = 84
    local area_h = DIALOG_H - area_top - PAD
    local gap = count > 1 and 4 or 0
    local line_h = math.max(20, math.floor((area_h - gap * (count - 1)) / count / 4) * 4)
    for index, line in ipairs(lines) do
      local top = area_top + (index - 1) * (line_h + gap)
      Primitives.label(scope, ctx, {
        name = "LabelFishermanLine" .. index,
        parent = panel,
        rect = Layout.from_top_left(DIALOG_H, PAD, top, DIALOG_W - PAD * 2, line_h),
        text = tostring(line),
        font_size = Tokens.FONT_SIZE.CAPTION,
        color = Tokens.COLOR.TEXT_DARK,
        align_x = 0,
        align_y = 1,
        z_order = 2,
      })
    end
  end
end

function FishermanView.confirm_modal_spec()
  return function(scope, ctx)
    local payload = ctx.store.modal_payload:now() or {}
    local shell = Controls.modal_shell(scope, ctx, {
      name = "PanelConfirm",
      title = tostring(payload.title or "确认提示"),
      title_name = "LabelConfirmTitle",
      width = CONFIRM_W,
      height = CONFIRM_H,
      show_close = false,
    })
    local panel = shell.panel
    Primitives.label(scope, ctx, {
      name = "LabelText",
      parent = panel,
      rect = Layout.from_top_left(CONFIRM_H, PAD, 96, CONFIRM_W - PAD * 2, 120),
      text = tostring(payload.msg or ""),
      font_size = Tokens.FONT_SIZE.BODY,
      color = Tokens.COLOR.TEXT_DARK,
      align_x = 1,
      align_y = 1,
      z_order = 2,
    })
    local function finish(value)
      if type(payload.call_back) == "function" then
        local ok, err = pcall(payload.call_back, value)
        if not ok then
          print("[FishermanView] 确认弹窗回调执行失败", tostring(err))
        end
      end
      Modal.close_modal(ctx, "confirm")
    end
    local btn_rects = Layout.centered_row(CONFIRM_W, PAD + 56 / 2, 2, 200, 56, 40)
    Controls.button(scope, ctx, {
      name = "BtnNo",
      parent = panel,
      rect = btn_rects[1],
      text = tostring(payload.no_text or "否"),
      variant = "blue",
      font_size = Tokens.FONT_SIZE.BUTTON,
      z_order = 2,
      on_click = function() finish(false) end,
    })
    Controls.button(scope, ctx, {
      name = "BtnYes",
      parent = panel,
      rect = btn_rects[2],
      text = tostring(payload.yes_text or "是"),
      variant = "gold",
      font_size = Tokens.FONT_SIZE.BUTTON,
      z_order = 2,
      on_click = function() finish(true) end,
    })
  end
end

function FishermanView.presentation_spec(options)
  options = type(options) == "table" and options or {}
  local shared = options.shared or {}
  local models = options.models or {}
  return {
    name = "FishermanPresentation",
    mount = function(scope, ctx)
      local pulse_active = State.new("FishermanView.pulse_active", false)

      scope:subscribe(ctx.store.on_server_event, function(event)
        if event.channel ~= "InteractResult" or type(event.payload) ~= "table" then return end
        local result = event.payload
        if result.action == GameCfg.Rescue.Action and result.reason == "busy" then
          ViewUtil.notify(ctx, "正在抢救中")
        end
        if not result.ok then
          if result.reason == "nothing" then ViewUtil.notify(ctx, "未选中可喂食物品")
          elseif result.reason == "full" then ViewUtil.notify(ctx, "交付失败：产物需要背包空位") end
          return
        end
        if result.achievement then
          ViewUtil.notify(ctx, "交付完成：解锁新成果")
        elseif result.exchange then
          ViewUtil.notify(ctx, "交付完成：" .. tostring(result.exchange.from) .. " → " .. tostring(result.exchange.to))
        elseif result.coins and result.coins > 0 then
          ViewUtil.notify(ctx, "喂食成功，获得 " .. tostring(result.coins) .. " 金币")
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
            print("[FishermanView] 模型缩放失败", index, tostring(err))
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
            if not ok then print("[FishermanView] 模型缩放恢复失败", tostring(err)) end
          end
        end
      end)
    end,
  }
end

-- 抢救入口（state / driver_spec / bubble_spec）的参数集中在 RescueView 的预设里，这里只绑定本视图的入口。
local RescueApi = RescueView.view_api("fisherman")

FishermanView.rescue_state = RescueApi.state
FishermanView.rescue_driver_spec = RescueApi.driver_spec
FishermanView.rescue_bubble_spec = RescueApi.bubble_spec

return FishermanView
