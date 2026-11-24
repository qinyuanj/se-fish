local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")

local BlindboxView = {}

local function prize_names()
  local names = {}
  for _, key in ipairs(GameCfg.Blindbox.Pity.prizeItemKeys or {}) do
    for _, entry in ipairs(GameCfg.Blindbox.Entries or {}) do
      if entry.itemKey == key then names[#names + 1] = entry.itemName break end
    end
  end
  return table.concat(names, "或")
end

local function result_text(result)
  local lines = {}
  for index, draw in ipairs(result.draws or {}) do
    local tags = {}
    if draw.guaranteed then tags[#tags + 1] = "保底" elseif draw.jackpot then tags[#tags + 1] = "大奖" end
    if draw.landed then tags[#tags + 1] = result.deliveryPending and "待交付" or "落在地上" end
    lines[#lines + 1] = string.format("%d. %s%s", index, draw.itemName or draw.itemKey or "?",
      #tags > 0 and ("（" .. table.concat(tags, "，") .. "）") or "")
  end
  if #lines == 0 and result.ok == false then return tostring(result.reason or "购买未完成") end
  return table.concat(lines, "\n")
end

function BlindboxView.entry_spec()
  return {
    name = "BlindboxEntry",
    mount = function(scope, ctx)
      local button = Modal.button(scope, ctx, ctx.root_node, "BtnBlindboxEntry", GameCfg.Blindbox.HintText, function()
        local services = ctx.services or {}
        if type(services.open_modal) == "function" then services.open_modal("blindbox") end
        if type(services.request_blindbox_state) == "function" then services.request_blindbox_state() end
      end)
      local rect = type((ctx.services or {}).hud_entry_rect) == "function" and ctx.services.hud_entry_rect("BlindboxEntry") or nil
      if rect then
        button.Position = Vector2.New(rect.x - rect.w / 2, rect.y - rect.h / 2)
        button.Size = Vector2.New(rect.w, rect.h)
      end
    end,
  }
end

function BlindboxView.modal_spec()
  return function(scope, ctx)
    local services = ctx.services or {}
    local panel = Modal.panel(scope, ctx, "ScreenBlindbox", GameCfg.Blindbox.HintText)
    local pity = Modal.label(scope, ctx, panel, "LabelBlindboxPity", "")
    local result_label = Modal.label(scope, ctx, panel, "LabelBlindboxResult", "")
    local seq, request_seq, request_id = 0, nil, nil
    local single, ten
    local awaiting, awaiting_elapsed = false, 0
    local confirm_full, snapshot = nil, nil
    local pity_count = 0
    local last_operation_id, last_delivery_pending = nil, nil

    local function notify(text)
      if type(services.notify) == "function" then services.notify(text) end
    end
    local function free_slots()
      if type(snapshot) ~= "table" then return nil end
      if type(snapshot.slotCount) ~= "number" and type(snapshot.backpackCount) ~= "number" then return nil end
      local free = 0
      for _, pair in ipairs({ { snapshot.slots, snapshot.slotCount }, { snapshot.backpack, snapshot.backpackCount } }) do
        local slots, capacity = pair[1] or {}, tonumber(pair[2]) or 0
        for index = 1, capacity do
          local entry = slots[index]
          if not entry or (entry.count or 0) <= 0 then free = free + 1 end
        end
      end
      return free
    end
    local function refresh_buttons()
      single.Disabled, ten.Disabled = awaiting, awaiting
      single.TouchEnabled, ten.TouchEnabled = not awaiting, not awaiting
      pity.Text = string.format("已连续 %d 次未出大奖；再抽 %d 次内必出%s",
        pity_count, math.max(1, GameCfg.Blindbox.Pity.afterMisses + 1 - pity_count), prize_names())
    end
    local function draw(count)
      if awaiting then return end
      local free = free_slots()
      if free and free < count and confirm_full ~= count then
        confirm_full = count
        notify(GameCfg.Blindbox.FullNoticeText)
        result_label.Text = GameCfg.Blindbox.FullNoticeText .. "\n再点一次确认抽取"
        return
      end
      confirm_full = nil
      seq = seq + 1
      request_seq, request_id = seq, nil
      awaiting, awaiting_elapsed = true, 0
      refresh_buttons()
      if type(services.send_blindbox) == "function" then
        services.send_blindbox({ action = "Draw", count = count, seq = seq })
      end
    end
    single = Modal.button(scope, ctx, panel, "BtnBlindboxSingle",
      string.format("单抽（%d金豆）", GameCfg.Platform.Goods.blindboxSingle.beans), function() draw(1) end)
    ten = Modal.button(scope, ctx, panel, "BtnBlindboxTen",
      string.format("十连（%d金豆）", GameCfg.Platform.Goods.blindboxTen.beans), function() draw(10) end)
    Modal.close(scope, ctx, panel, "BtnBlindboxClose", "blindbox")

    scope:effect("BlindboxInventoryProjection", function(es)
      snapshot = es:d(ctx.store.item_bar)
      confirm_full = nil
    end)
    scope:effect("BlindboxResultProjection", function(es)
      local result = es:d(ctx.store.blindbox_result)
      if type(result) ~= "table" then return end
      if result.action == "State" then
        if result.recovery then
          request_seq, request_id = result.recovery.seq, result.recovery.requestId
          seq = math.max(seq, request_seq or 0)
          awaiting, awaiting_elapsed = true, 0
          notify("购买结果待对账，请勿重复购买；真实订单由平台核对")
        end
        pity_count = tonumber(result.pity) or 0
        refresh_buttons()
        return
      end
      if awaiting and result.seq and result.seq ~= request_seq then return end
      if result.requestId then
        request_id = result.requestId
        if result.deliveryPending and result.originalSeq then request_seq = result.originalSeq end
      end
      if not result.ok then
        if result.deliveryPending or result.reason == "unknown" then
          awaiting, awaiting_elapsed = true, 0
          result_label.Text = "购买或交付结果待对账，请勿重复购买"
          notify("购买或交付结果待对账，请勿重复购买；真实订单由平台核对")
        else
          awaiting, awaiting_elapsed = false, 0
          local text = result.reason == "unavailable" and GameCfg.Blindbox.UnavailableText
            or GameCfg.Platform.ReasonText[result.reason] or GameCfg.Platform.UnavailableText
          result_label.Text = text
          notify(text)
        end
        refresh_buttons()
        return
      end
      if result.deliveryPending then notify("奖品已记录，落地交付待恢复；请稍后查看，勿重复购买") end
      local operation_id = result.operation and result.operation.id
      if operation_id and operation_id == last_operation_id and result.deliveryPending == last_delivery_pending then
        awaiting, awaiting_elapsed = false, 0
        refresh_buttons()
        return
      end
      last_operation_id, last_delivery_pending = operation_id, result.deliveryPending
      awaiting, awaiting_elapsed = false, 0
      pity_count = tonumber(result.pityAfter) or pity_count
      result_label.Text = result_text(result)
      if (result.grounded or 0) > 0 then
        notify(string.format("背包已满：%d 件物品落在面前地上，其他玩家可拾取", result.grounded))
      end
      refresh_buttons()
    end)
    scope:subscribe(ctx.clock.on_frame, function(frame)
      local dt = type(frame) == "table" and frame.dt or frame
      if not awaiting or type(dt) ~= "number" or dt < 0 then return end
      awaiting_elapsed = awaiting_elapsed + dt
      if awaiting_elapsed >= GameCfg.Blindbox.ResultTimeoutSec then
        awaiting_elapsed = 0
        if type(services.send_blindbox) == "function" then
          services.send_blindbox({ action = "Query", count = 1, seq = request_seq, requestId = request_id })
        end
        notify("盲盒回包超时，正在查询原请求，请勿重复购买")
      end
    end)
    refresh_buttons()
  end
end

return BlindboxView
