local GameCfg = require("common.GameCfg")
local BodyScale = require("common.BodyScale")
local Modal = require("client.Views.EconomyModal")
local ViewUtil = require("client.Views.ViewUtil")

local LotteryInteraction = {}

function LotteryInteraction.spec()
  return {
    name = "LotteryInteraction",
    when = function() return true end,
    mount = function(scope, ctx)
      local services = ctx.services or {}
      local bubbles = {}
      local machine = nil

      local function resolve_character(stored_character)
        if stored_character ~= nil then
          return stored_character
        end
        return type(services.local_character) == "function" and services.local_character() or nil
      end

      local function create_scene(preset, anchor, offset)
        if type(services.create_lottery_scene_node) ~= "function" then return nil end
        local ok, node = pcall(services.create_lottery_scene_node, preset, anchor, offset)
        if not ok or not node then
          print("[LotteryInteraction] 文字泡预设创建失败", tostring(node))
          return nil
        end
        return node
      end

      local function update(stored_pos, stored_character)
        local current = resolve_character(stored_character)
        local pos = stored_pos or (current and current.Position) or nil
        local radius = BodyScale.InteractionRadius(current, GameCfg.Lottery.Radius)
        local radius_sq = radius * radius
        local near_machine = nil
        for _, bubble in ipairs(bubbles) do
          local dist_sq = pos ~= nil and ViewUtil.distance_sq_xz(pos, bubble.center) or nil
          local near = dist_sq ~= nil and dist_sq <= radius_sq
          if near then near_machine = bubble end
          if bubble.near ~= near then
            bubble.near = near
            local ok, err = pcall(function() bubble.node.Visible = near end)
            if not ok then print("[LotteryInteraction] 气泡显隐失败", tostring(err)) end
          end
        end
        if machine ~= near_machine then
          machine = near_machine
          if not near_machine and ctx.store.active_modal:now() == "lottery"
            and type(services.close_modal) == "function" then
            services.close_modal("lottery")
          end
        end
      end

      for _, name in ipairs(GameCfg.Lottery.MachineAnchors()) do
        local anchor = type(services.find_lottery_anchor) == "function" and services.find_lottery_anchor(name) or nil
        if not anchor or not anchor.Position then
          print("[LotteryInteraction] 找不到抽奖机锚点", name)
        else
          local offset = Vector3 and Vector3.New and Vector3.New(0, GameCfg.Lottery.BubbleHeight, 0) or nil
          local node = create_scene(GameCfg.Lottery.BubblePreset, anchor, offset)
          if node then
            local bubble = { node = node, center = anchor.Position, near = nil }
            bubbles[#bubbles + 1] = bubble
            scope:on_cleanup(function()
              local ok, err = pcall(function() if not node.Destroyed then node:Destroy() end end)
              if not ok then print("[LotteryInteraction] 气泡根节点销毁失败", tostring(err)) end
            end)
            local button = Modal.button(scope, ctx, node, "BtnLotteryEnter", "", function()
              machine = bubble
              if type(services.open_modal) == "function" then services.open_modal("lottery") end
            end)
            button.NormalImage = "official://image/11017"
            button.PressImage = "official://image/11017"
            button.DisableImage = "official://image/11017"
            local label = Modal.label(scope, ctx, node, "LabelLotteryEnterTheme", GameCfg.Lottery.HintText)
            label.TouchEnabled = false
            label.SwallowTouchEnabled = false
            node.Visible = false
            bubble.near = false
          end
        end
      end

      scope:effect("LotteryInteractionSync", function(es)
        local pos = es:d(ctx.store.position)
        local char = es:d(ctx.store.local_character)
        update(pos, char)
      end)
    end,
  }
end

return LotteryInteraction
