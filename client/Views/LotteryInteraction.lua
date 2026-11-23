-- 抽奖机场景入口（#312）：RootView 时钟驱动，场景节点与按钮由同一作用域回收。
local GameCfg = require("common.GameCfg")
local BodyScale = require("common.BodyScale")
local Modal = require("client.Views.EconomyModal")

local LotteryInteraction = {}

function LotteryInteraction.spec()
  return {
    name = "LotteryInteraction",
    when = function() return true end,
    mount = function(scope, ctx)
      local services = ctx.services or {}
      local bubbles = {}
      local machine = nil

      local function character()
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
      local function update()
        local current = character()
        local pos = current and current.Position
        local radius = BodyScale.InteractionRadius(current, GameCfg.Lottery.Radius)
        local near_machine = nil
        for _, bubble in ipairs(bubbles) do
          local near = false
          if pos then
            local dx, dz = pos.x - bubble.center.x, pos.z - bubble.center.z
            near = dx * dx + dz * dz <= radius * radius
          end
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
      scope:subscribe(ctx.clock.on_frame, update)
      update()
    end,
  }
end

return LotteryInteraction
