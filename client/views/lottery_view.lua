local GameCfg = require("common.game_cfg")
local Eligibility = require("common.lottery_eligibility")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")

local LotteryView = {}

local PANEL_W = 928
local PANEL_H = 640
local PAD = Tokens.SPACE.PANEL_PAD

local FAIL_TEXT = {
  ["not-premium"] = "只能投入极品鱼获或信物",
  ["cooked"] = "烤过的物品不能抽奖",
  ["bad-item"] = "这件物品不能抽奖",
  malformed = "这件物品不能抽奖",
  slot = "请先在道具栏选中一件极品食物",
  range = "请靠近抽奖机",
}

local REEL_SPECS = {
  { key = "left", card = "LotteryReelCardLeft", label = "LabelReelLeft" },
  { key = "middle", card = "LotteryReelCardMiddle", label = "LabelReelMiddle" },
  { key = "right", card = "LotteryReelCardRight", label = "LabelReelRight" },
}

local function pattern_name(number)
  local pattern = GameCfg.Lottery.Patterns[number]
  return pattern and pattern.name or "?"
end

-- 抽奖面板句柄：面板节点、请求序号与等待/滚动中标记都留在句柄上。
---@class LotteryPanelHandle: table<string, any>
---@type LotteryPanelHandle
local LotteryBehavior = {}

--- 建面板节点：浅奶白底板 + 投注信息条 + 三滚轴浅白卡片 + 结果卡片 + 金主抽奖按钮。
---@param self LotteryPanelHandle
function LotteryBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenLottery", "抽奖机", {
    width = PANEL_W,
    height = PANEL_H,
    close_name = "BtnLotteryClose",
    modal_id = "lottery",
  })
  self.panel = panel

  local content_w = PANEL_W - PAD * 2
  local bet_card = Modal.surface(scope, ctx, panel, "LotteryBetCard",
    Layout.from_top_left(PANEL_H, PAD, 84, content_w, 64), { z_order = 1 })
  self.bet = Primitives.label(scope, ctx, {
    name = "LabelLotteryBet",
    parent = bet_card,
    rect = Layout.from_top_left(64, 20, 8, content_w - 40, 48),
    text = "",
    font_size = Tokens.FONT_SIZE.BODY,
    bold = true,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 2,
  })

  self.reels = {}
  for index, spec in ipairs(REEL_SPECS) do
    local card_rect = Layout.grid_cell(PANEL_H, PAD, 168, 3, index, 264, 152, 36, 0)
    local card = Modal.surface(scope, ctx, panel, spec.card, card_rect, {
      color = Tokens.COLOR.MODAL_CARD,
      z_order = 1,
    })
    self.reels[spec.key] = Primitives.label(scope, ctx, {
      name = spec.label,
      parent = card,
      rect = Layout.center_in(264, 152, 232, 120),
      text = "?",
      font_size = 36,
      bold = true,
      color = Tokens.COLOR.TEXT_GOLD_DARK,
      align_x = 1,
      align_y = 1,
      z_order = 2,
    })
  end

  local result_card = Modal.surface(scope, ctx, panel, "LotteryResultCard",
    Layout.from_top_left(PANEL_H, PAD, 340, content_w, 120), { z_order = 1 })
  self.result_label = Primitives.label(scope, ctx, {
    name = "LabelLotteryResult",
    parent = result_card,
    rect = Layout.from_top_left(120, 24, 16, content_w - 48, 88),
    text = "",
    font_size = Tokens.FONT_SIZE.BUTTON,
    bold = true,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 2,
  })

  self.draw = Controls.button(scope, ctx, {
    name = "BtnLotteryDraw",
    parent = panel,
    rect = Layout.bottom_center(PANEL_W, 44, 320, 68),
    text = "抽奖",
    variant = "gold",
    font_size = Tokens.FONT_SIZE.SUBTITLE,
    z_order = 2,
    on_click = function()
      self:request_draw()
    end,
  })
end

--- 面板提示统一走 ViewUtil.notify（services.notify 缺失或文本为空时忽略）。
LotteryBehavior.notify = ViewUtil.notify

--- 三滚轴定格并写结果文案。
---@param self LotteryPanelHandle
---@param result table
function LotteryBehavior.show_result(self, result)
  self.spinning = nil
  for axis, index in pairs({ left = 1, right = 2, middle = 3 }) do
    self.reels[axis].Text = pattern_name(result.axes and result.axes[index])
  end
  local label = self.result_label
  if result.outcome == "pair" then
    label.Text = string.format("%s ×2！金币 +%d", result.patternName or "", result.coins or 0)
  elseif result.outcome == "triple" then
    label.Text = string.format("恭喜获得：%s（%s ×3）",
      result.prize and result.prize.name or "大奖", result.patternName or "")
  else
    label.Text = "未中奖，再接再厉"
  end
end

--- 按下注槽位刷新下注文案与按钮可用状态。
---@param self LotteryPanelHandle
function LotteryBehavior.refresh_bet(self)
  local snapshot = self.bet_snapshot
  local slot = snapshot and snapshot.selectedSlot
  local entry = slot and snapshot.slots and snapshot.slots[slot] or nil
  self.selected_slot = entry and slot or nil
  local enabled = entry ~= nil and Eligibility.check(entry) == true and not self.awaiting and not self.spinning
  Controls.set_button_enabled(self.draw, enabled, "gold")
  if not entry then
    self.bet.Text = "请先在道具栏选中一件极品食物"
  elseif Eligibility.check(entry) then
    local definition = GameCfg.Items.Definitions[entry.itemId]
    local value = GameCfg.Items.sale_price(entry.itemId, entry.mult) or 0
    self.bet.Text = string.format("投注：%s（价值 %d 金币）", definition and definition.Name or entry.itemId, value)
  else
    local _, reason = Eligibility.check(entry)
    self.bet.Text = FAIL_TEXT[reason] or "这件物品不能抽奖"
  end
end

--- 抽奖按钮：发一次 Draw 上行并进入等待回包。
---@param self LotteryPanelHandle
function LotteryBehavior.request_draw(self)
  if self.awaiting or self.spinning or not self.selected_slot then return end
  self.seq = self.seq + 1
  self.request_seq = self.seq
  self.awaiting, self.awaiting_elapsed = true, 0
  self:refresh_bet()
  local services = self.services
  if type(services.send_lottery) == "function" then
    services.send_lottery({ action = "Draw", slot = self.selected_slot, seq = self.seq })
  end
end

---@param self LotteryPanelHandle
---@param es table EffectScope
function LotteryBehavior.on_bet_projection(self, es)
  self.bet_snapshot = es:d(self.ctx.store.item_bar)
  self:refresh_bet()
end

--- 抽奖回包投影：失败提示、去重（operation id / seq）与滚动启动。
---@param self LotteryPanelHandle
---@param es table EffectScope
function LotteryBehavior.on_result_projection(self, es)
  local result = es:d(self.ctx.store.lottery_result)
  if type(result) ~= "table" then self.initialized = true; return end
  if not result.ok then
    self.awaiting, self.awaiting_elapsed = false, 0
    self.result_label.Text = FAIL_TEXT[result.reason] or "抽奖失败，请稍后再试"
    self:notify(self.result_label.Text)
    self:refresh_bet()
    self.initialized = true
    return
  end
  local operation_id = result.operation and result.operation.id
  if operation_id and operation_id == self.last_operation_id then return end
  if operation_id then self.last_operation_id = operation_id end
  if self.initialized and self.awaiting and result.seq and self.request_seq and result.seq ~= self.request_seq then return end
  self.awaiting, self.awaiting_elapsed = false, 0
  if result.recovered or not self.initialized then
    self:show_result(result)
  else
    self.spinning = { t = 0, stopped = {}, result = result }
    self.result_label.Text = "抽奖中…"
  end
  self.initialized = true
  self:refresh_bet()
end

--- 逐帧推进：回包超时与滚轴分段定格。
---@param self LotteryPanelHandle
---@param frame any
function LotteryBehavior.on_frame(self, frame)
  local dt = type(frame) == "table" and frame.dt or frame
  if type(dt) ~= "number" or dt < 0 then return end
  if self.awaiting then
    self.awaiting_elapsed = self.awaiting_elapsed + dt
    if self.awaiting_elapsed >= GameCfg.Lottery.ResultTimeoutSec then
      self.awaiting, self.awaiting_elapsed = false, 0
      self:notify("抽奖回包超时，请再试一次")
      self:refresh_bet()
    end
  end
  local current = self.spinning
  if not current then return end
  current.t = current.t + dt
  local cfg = GameCfg.Lottery
  local order = cfg.AxisOrder or { "left", "right", "middle" }
  local all_stopped = true
  for stop_index = 1, 3 do
    if not current.stopped[stop_index] then
      local axis = order[stop_index]
      local stop_at = cfg.SpinSec + (stop_index - 1) * cfg.AxisStopIntervalSec
      if current.t >= stop_at then
        current.stopped[stop_index] = true
        local axis_index = axis == "left" and 1 or axis == "right" and 2 or 3
        self.reels[axis].Text = pattern_name(current.result.axes[axis_index])
      else
        all_stopped = false
      end
    end
  end
  if all_stopped and current.stopped[1] and current.stopped[2] and current.stopped[3] then
    self:show_result(current.result)
    self:refresh_bet()
  end
end

--- 挂载抽奖面板：造句柄、建节点、接投影与帧订阅。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type LotteryPanelHandle
  local self = {
    scope = scope,
    ctx = ctx,
    services = ctx.services or {},
    seq = 0,
    request_seq = nil,
    awaiting = false,
    awaiting_elapsed = 0,
    spinning = nil,
    selected_slot = nil,
    bet_snapshot = nil,
    last_operation_id = nil,
    initialized = false,
    panel = nil,
    bet = nil,
    result_label = nil,
    reels = nil,
    draw = nil,
  }
  for name, method in pairs(LotteryBehavior) do self[name] = method end
  self:create_nodes()

  scope:effect("LotteryBetProjection", function(es) self:on_bet_projection(es) end)
  scope:effect("LotteryResultProjection", function(es) self:on_result_projection(es) end)
  scope:subscribe(ctx.clock.on_frame, function(frame) self:on_frame(frame) end)
end

function LotteryView.modal_spec()
  return mount
end

return LotteryView
