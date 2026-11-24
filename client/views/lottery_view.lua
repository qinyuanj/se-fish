local game_cfg = require("common.game_cfg")
local eligibility = require("common.lottery_eligibility")
local modal = require("client.views.economy_modal")

local lottery_view = {}
local FAIL_TEXT = {
  ["not-premium"] = "只能投入极品鱼获或信物",
  ["cooked"] = "烤过的物品不能抽奖",
  ["bad-item"] = "这件物品不能抽奖",
  malformed = "这件物品不能抽奖",
  slot = "请先在道具栏选中一件极品食物",
  range = "请靠近抽奖机",
}

local function pattern_name(number)
  local pattern = game_cfg.Lottery.Patterns[number]
  return pattern and pattern.name or "?"
end

function lottery_view.modal_spec()
  return function(scope, ctx)
    local services = ctx.services or {}
    local panel = modal.panel(scope, ctx, "ScreenLottery", "抽奖机")
    local bet = modal.label(scope, ctx, panel, "LabelLotteryBet", "")
    local result_label = modal.label(scope, ctx, panel, "LabelLotteryResult", "")
    local reels = {
      left = modal.label(scope, ctx, panel, "LabelReelLeft", "?"),
      right = modal.label(scope, ctx, panel, "LabelReelRight", "?"),
      middle = modal.label(scope, ctx, panel, "LabelReelMiddle", "?"),
    }
    local seq, request_seq = 0, nil
    local draw
    local awaiting, awaiting_elapsed = false, 0
    local spinning = nil
    local selected_slot, bet_snapshot = nil, nil
    local last_operation_id, initialized = nil, false

    local function notify(text)
      if type(services.notify) == "function" then services.notify(text) end
    end
    local function show_result(result)
      spinning = nil
      for axis, index in pairs({ left = 1, right = 2, middle = 3 }) do
        reels[axis].Text = pattern_name(result.axes and result.axes[index])
      end
      if result.outcome == "pair" then
        result_label.Text = string.format("%s ×2！金币 +%d", result.patternName or "", result.coins or 0)
      elseif result.outcome == "triple" then
        result_label.Text = string.format("恭喜获得：%s（%s ×3）",
          result.prize and result.prize.name or "大奖", result.patternName or "")
      else
        result_label.Text = "未中奖，再接再厉"
      end
    end
    local function refresh_bet()
      local snapshot = bet_snapshot
      local slot = snapshot and snapshot.selectedSlot
      local entry = slot and snapshot.slots and snapshot.slots[slot] or nil
      selected_slot = entry and slot or nil
      local enabled = entry ~= nil and eligibility.Check(entry) == true and not awaiting and not spinning
      draw.Disabled = not enabled
      draw.TouchEnabled = enabled
      if not entry then
        bet.Text = "请先在道具栏选中一件极品食物"
      elseif eligibility.Check(entry) then
        local definition = game_cfg.Items.Definitions[entry.itemId]
        local value = game_cfg.Items.SalePrice(entry.itemId, entry.mult) or 0
        bet.Text = string.format("投注：%s（价值 %d 金币）", definition and definition.Name or entry.itemId, value)
      else
        local _, reason = eligibility.Check(entry)
        bet.Text = FAIL_TEXT[reason] or "这件物品不能抽奖"
      end
    end

    draw = modal.button(scope, ctx, panel, "BtnLotteryDraw", "抽奖", function()
      if awaiting or spinning or not selected_slot then return end
      seq = seq + 1
      request_seq = seq
      awaiting, awaiting_elapsed = true, 0
      refresh_bet()
      if type(services.send_lottery) == "function" then
        services.send_lottery({ action = "draw", slot = selected_slot, seq = seq })
      end
    end)
    modal.close(scope, ctx, panel, "BtnLotteryClose", "lottery")

    scope:effect("LotteryBetProjection", function(es)
      bet_snapshot = es:d(ctx.store.item_bar)
      refresh_bet()
    end)
    scope:effect("LotteryResultProjection", function(es)
      local result = es:d(ctx.store.lottery_result)
      if type(result) ~= "table" then initialized = true; return end
      if not result.ok then
        awaiting, awaiting_elapsed = false, 0
        result_label.Text = FAIL_TEXT[result.reason] or "抽奖失败，请稍后再试"
        notify(result_label.Text)
        refresh_bet()
        initialized = true
        return
      end
      local operation_id = result.operation and result.operation.id
      if operation_id and operation_id == last_operation_id then return end
      if operation_id then last_operation_id = operation_id end
      if initialized and awaiting and result.seq and request_seq and result.seq ~= request_seq then return end
      awaiting, awaiting_elapsed = false, 0
      if result.recovered or not initialized then
        show_result(result)
      else
        spinning = { t = 0, stopped = {}, result = result }
        result_label.Text = "抽奖中…"
      end
      initialized = true
      refresh_bet()
    end)

    scope:subscribe(ctx.clock.on_frame, function(frame)
      local dt = type(frame) == "table" and frame.dt or frame
      if type(dt) ~= "number" or dt < 0 then return end
      if awaiting then
        awaiting_elapsed = awaiting_elapsed + dt
        if awaiting_elapsed >= game_cfg.Lottery.ResultTimeoutSec then
          awaiting, awaiting_elapsed = false, 0
          notify("抽奖回包超时，请再试一次")
          refresh_bet()
        end
      end
      local current = spinning
      if not current then return end
      current.t = current.t + dt
      local cfg = game_cfg.Lottery
      local order = cfg.AxisOrder or { "left", "right", "middle" }
      local all_stopped = true
      for stop_index = 1, 3 do
        if not current.stopped[stop_index] then
          local axis = order[stop_index]
          local stop_at = cfg.SpinSec + (stop_index - 1) * cfg.AxisStopIntervalSec
          if current.t >= stop_at then
            current.stopped[stop_index] = true
            local axis_index = axis == "left" and 1 or axis == "right" and 2 or 3
            reels[axis].Text = pattern_name(current.result.axes[axis_index])
          else
            all_stopped = false
          end
        end
      end
      if all_stopped and current.stopped[1] and current.stopped[2] and current.stopped[3] then
        show_result(current.result)
        refresh_bet()
      end
    end)
  end
end

return lottery_view
