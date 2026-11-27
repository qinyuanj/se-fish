local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")

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

-- 盲盒面板句柄：面板节点、请求序号与等待/确认标记都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class BlindboxPanelHandle: table<string, any>
---@type BlindboxPanelHandle
local BlindboxBehavior = {}

--- 建面板节点：保底行、结果行与单抽/十连/关闭按钮。
---@param self BlindboxPanelHandle
function BlindboxBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenBlindbox", GameCfg.Blindbox.HintText)
  self.panel = panel
  self.pity = Modal.place(Modal.label(scope, ctx, panel, "LabelBlindboxPity", ""), 20, 64, 860, 44)
  self.result_label = Modal.place(Modal.label(scope, ctx, panel, "LabelBlindboxResult", ""), 20, 196, 860, 384)
  self.single = Modal.place(Modal.button(scope, ctx, panel, "BtnBlindboxSingle",
    string.format("单抽（%d金豆）", GameCfg.Platform.Goods.blindboxSingle.beans), function() self:draw(1) end), 140, 124, 280, 56)
  self.ten = Modal.place(Modal.button(scope, ctx, panel, "BtnBlindboxTen",
    string.format("十连（%d金豆）", GameCfg.Platform.Goods.blindboxTen.beans), function() self:draw(10) end), 480, 124, 280, 56)
  Modal.close(scope, ctx, panel, "BtnBlindboxClose", "blindbox")
end

--- 面板提示统一走 ViewUtil.notify（services.notify 缺失或文本为空时忽略）。
BlindboxBehavior.notify = ViewUtil.notify

--- 背包与道具栏合计空位数；快照结构不全时返回 nil。
---@param self BlindboxPanelHandle
---@return number|nil
function BlindboxBehavior.free_slots(self)
  local snapshot = self.snapshot
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

---@param self BlindboxPanelHandle
function BlindboxBehavior.refresh_buttons(self)
  local awaiting = self.awaiting
  self.single.Disabled, self.ten.Disabled = awaiting, awaiting
  self.single.TouchEnabled, self.ten.TouchEnabled = not awaiting, not awaiting
  self.pity.Text = string.format("已连续 %d 次未出大奖；再抽 %d 次内必出%s",
    self.pity_count, math.max(1, GameCfg.Blindbox.Pity.afterMisses + 1 - self.pity_count), prize_names())
end

--- 下单：背包空位不足时先要求二次确认，再发 Draw 上行。
---@param self BlindboxPanelHandle
---@param count number
function BlindboxBehavior.draw(self, count)
  if self.awaiting then return end
  local free = self:free_slots()
  if free and free < count and self.confirm_full ~= count then
    self.confirm_full = count
    self:notify(GameCfg.Blindbox.FullNoticeText)
    self.result_label.Text = GameCfg.Blindbox.FullNoticeText .. "\n再点一次确认抽取"
    return
  end
  self.confirm_full = nil
  self.seq = self.seq + 1
  self.request_seq, self.request_id = self.seq, nil
  self.awaiting, self.awaiting_elapsed = true, 0
  self:refresh_buttons()
  local services = self.services
  if type(services.send_blindbox) == "function" then
    services.send_blindbox({ action = "Draw", count = count, seq = self.seq })
  end
end

---@param self BlindboxPanelHandle
---@param es table EffectScope
function BlindboxBehavior.on_inventory_projection(self, es)
  self.snapshot = es:d(self.ctx.store.item_bar)
  self.confirm_full = nil
end

--- 盲盒回包投影：状态对账、序号去重、失败文案与结果行。
---@param self BlindboxPanelHandle
---@param es table EffectScope
function BlindboxBehavior.on_result_projection(self, es)
  local result = es:d(self.ctx.store.blindbox_result)
  if type(result) ~= "table" then return end
  if result.action == "State" then
    if result.recovery then
      self.request_seq, self.request_id = result.recovery.seq, result.recovery.requestId
      self.seq = math.max(self.seq, self.request_seq or 0)
      self.awaiting, self.awaiting_elapsed = true, 0
      self:notify("购买结果待对账，请勿重复购买；真实订单由平台核对")
    end
    self.pity_count = tonumber(result.pity) or 0
    self:refresh_buttons()
    return
  end
  if self.awaiting and result.seq and result.seq ~= self.request_seq then return end
  if result.requestId then
    self.request_id = result.requestId
    if result.deliveryPending and result.originalSeq then self.request_seq = result.originalSeq end
  end
  if not result.ok then
    if result.deliveryPending or result.reason == "unknown" then
      self.awaiting, self.awaiting_elapsed = true, 0
      self.result_label.Text = "购买或交付结果待对账，请勿重复购买"
      self:notify("购买或交付结果待对账，请勿重复购买；真实订单由平台核对")
    else
      self.awaiting, self.awaiting_elapsed = false, 0
      local text = result.reason == "unavailable" and GameCfg.Blindbox.UnavailableText
        or GameCfg.Platform.ReasonText[result.reason] or GameCfg.Platform.UnavailableText
      self.result_label.Text = text
      self:notify(text)
    end
    self:refresh_buttons()
    return
  end
  if result.deliveryPending then self:notify("奖品已记录，落地交付待恢复；请稍后查看，勿重复购买") end
  local operation_id = result.operation and result.operation.id
  if operation_id and operation_id == self.last_operation_id and result.deliveryPending == self.last_delivery_pending then
    self.awaiting, self.awaiting_elapsed = false, 0
    self:refresh_buttons()
    return
  end
  self.last_operation_id, self.last_delivery_pending = operation_id, result.deliveryPending
  self.awaiting, self.awaiting_elapsed = false, 0
  self.pity_count = tonumber(result.pityAfter) or self.pity_count
  self.result_label.Text = result_text(result)
  if (result.grounded or 0) > 0 then
    self:notify(string.format("背包已满：%d 件物品落在面前地上，其他玩家可拾取", result.grounded))
  end
  self:refresh_buttons()
end

--- 逐帧推进：等待超时后按原请求号查询，避免重复购买。
---@param self BlindboxPanelHandle
---@param frame any
function BlindboxBehavior.on_frame(self, frame)
  local dt = type(frame) == "table" and frame.dt or frame
  if not self.awaiting or type(dt) ~= "number" or dt < 0 then return end
  self.awaiting_elapsed = self.awaiting_elapsed + dt
  if self.awaiting_elapsed >= GameCfg.Blindbox.ResultTimeoutSec then
    self.awaiting_elapsed = 0
    local services = self.services
    if type(services.send_blindbox) == "function" then
      services.send_blindbox({ action = "Query", count = 1, seq = self.request_seq, requestId = self.request_id })
    end
    self:notify("盲盒回包超时，正在查询原请求，请勿重复购买")
  end
end

--- 挂载盲盒面板：造句柄、建节点、接投影与帧订阅。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type BlindboxPanelHandle
  local self = {
    scope = scope,
    ctx = ctx,
    services = ctx.services or {},
    seq = 0,
    request_seq = nil,
    request_id = nil,
    awaiting = false,
    awaiting_elapsed = 0,
    confirm_full = nil,
    snapshot = nil,
    pity_count = 0,
    last_operation_id = nil,
    last_delivery_pending = nil,
    panel = nil,
    pity = nil,
    result_label = nil,
    single = nil,
    ten = nil,
  }
  for name, method in pairs(BlindboxBehavior) do self[name] = method end
  self:create_nodes()

  scope:effect("BlindboxInventoryProjection", function(es) self:on_inventory_projection(es) end)
  scope:effect("BlindboxResultProjection", function(es) self:on_result_projection(es) end)
  scope:subscribe(ctx.clock.on_frame, function(frame) self:on_frame(frame) end)
  self:refresh_buttons()
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
        button.Position = Vector2.New(rect.x, rect.y)
        button.Size = Vector2.New(rect.w, rect.h)
      end
    end,
  }
end

function BlindboxView.modal_spec()
  return mount
end

return BlindboxView
