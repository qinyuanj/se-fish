local GameCfg = require("common.game_cfg")
local BodyScale = require("common.body_scale")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local ViewUtil = require("client.views.view_util")
local InteractPromptArbiter = require("client.views.interact_prompt_arbiter")

local LotteryInteraction = {}

local BUBBLE_W = 224
local BUBBLE_H = 84

-- 抽奖机交互句柄：文字泡列表与当前靠近的机器都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class LotteryInteractionHandle: table<string, any>
---@type LotteryInteractionHandle
local LotteryBehavior = {}

--- 取本地角色：优先用投影里存下来的角色。
---@param self LotteryInteractionHandle
---@param stored_character any
---@return any
function LotteryBehavior.resolve_character(self, stored_character)
  if stored_character ~= nil then
    return stored_character
  end
  local services = self.services
  return type(services.local_character) == "function" and services.local_character() or nil
end

--- 建文字泡场景节点；预设创建失败只打日志。
---@param self LotteryInteractionHandle
---@param preset any
---@param anchor any
---@param offset any
---@return any
function LotteryBehavior.create_scene(self, preset, anchor, offset)
  local services = self.services
  if type(services.create_lottery_scene_node) ~= "function" then return nil end
  local ok, node = pcall(services.create_lottery_scene_node, preset, anchor, offset)
  if not ok or not node then
    print("[LotteryInteraction] 文字泡预设创建失败", tostring(node))
    return nil
  end
  return node
end

--- 按位置刷新气泡显隐，离开机器时关掉抽奖面板。
---@param self LotteryInteractionHandle
---@param stored_pos any
---@param stored_character any
function LotteryBehavior.update(self, stored_pos, stored_character)
  local services = self.services
  local current = self:resolve_character(stored_character)
  local pos = stored_pos or (current and current.Position) or nil
  local radius = BodyScale.interaction_radius(current, GameCfg.Lottery.Radius)
  local radius_sq = radius * radius
  local near_machine = nil
  for _, bubble in ipairs(self.bubbles) do
    local dist_sq = pos ~= nil and ViewUtil.distance_sq_xz(pos, bubble.center) or nil
    local near = dist_sq ~= nil and dist_sq <= radius_sq
      and InteractPromptArbiter.is_exclusive(pos, current, bubble.name)
    if near then near_machine = bubble end
    if bubble.near ~= near then
      bubble.near = near
      local ok, err = pcall(function() bubble.node.Visible = near end)
      if not ok then print("[LotteryInteraction] 气泡显隐失败", tostring(err)) end
    end
  end
  if self.machine ~= near_machine then
    self.machine = near_machine
    if not near_machine and self.ctx.store.active_modal:now() == "lottery"
      and type(services.close_modal) == "function" then
      services.close_modal("lottery")
    end
  end
end

--- 建一台机器的文字泡：根节点、进入按钮与主题文案（全 4px 栅格、圆体、零 ButtonText 双字），并挂销毁收尾。
---@param self LotteryInteractionHandle
---@param anchor any
function LotteryBehavior.create_bubble(self, anchor)
  local services = self.services
  local offset = Vector3 and Vector3.New and Vector3.New(0, GameCfg.Lottery.BubbleHeight, 0) or nil
  local node = self:create_scene(GameCfg.Lottery.BubblePreset, anchor, offset)
  if not node then return end
  local bubble = { node = node, name = anchor.Name, center = anchor.Position, near = nil }
  self.bubbles[#self.bubbles + 1] = bubble
  self.scope:on_cleanup(function()
    local ok, err = pcall(function() if not node.Destroyed then node:Destroy() end end)
    if not ok then print("[LotteryInteraction] 气泡根节点销毁失败", tostring(err)) end
  end)

  Controls.button(self.scope, self.ctx, {
    name = "BtnLotteryEnter",
    parent = node,
    rect = Layout.rect(BUBBLE_W / 2, BUBBLE_H / 2, BUBBLE_W, BUBBLE_H),
    icon_only = true,
    variant = "gold",
    z_order = 1,
    on_click = function()
      self.machine = bubble
      if type(services.open_modal) == "function" then services.open_modal("lottery") end
    end,
  })

  Primitives.label(self.scope, self.ctx, {
    name = "LabelLotteryEnterTheme",
    parent = node,
    rect = Layout.rect(BUBBLE_W / 2, BUBBLE_H / 2, BUBBLE_W - 24, BUBBLE_H - 16),
    text = GameCfg.Lottery.HintText,
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.WHITE,
    outline = true,
    outline_color = Tokens.COLOR.OUTLINE_GOLD,
    z_order = 2,
  })

  node.Visible = false
  bubble.near = false
end

--- 逐台机器建气泡；锚点缺失只打日志。
---@param self LotteryInteractionHandle
function LotteryBehavior.mount_bubbles(self)
  local services = self.services
  for _, name in ipairs(GameCfg.Lottery.machine_anchors()) do
    local anchor = type(services.find_lottery_anchor) == "function" and services.find_lottery_anchor(name) or nil
    if not anchor or not anchor.Position then
      print("[LotteryInteraction] 找不到抽奖机锚点", name)
    else
      self:create_bubble(anchor)
    end
  end
end

---@param self LotteryInteractionHandle
---@param es table EffectScope
function LotteryBehavior.on_position_sync(self, es)
  local pos = es:d(self.ctx.store.position)
  local char = es:d(self.ctx.store.local_character)
  self:update(pos, char)
end

--- 挂载抽奖机交互：造文字泡、接位置投影。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type LotteryInteractionHandle
  local self = {
    scope = scope,
    ctx = ctx,
    services = ctx.services or {},
    bubbles = {},
    machine = nil,
  }
  for name, method in pairs(LotteryBehavior) do self[name] = method end
  self:mount_bubbles()
  scope:effect("LotteryInteractionSync", function(es) self:on_position_sync(es) end)
end

function LotteryInteraction.spec()
  return {
    name = "LotteryInteraction",
    when = function() return true end,
    mount = mount,
  }
end

return LotteryInteraction
