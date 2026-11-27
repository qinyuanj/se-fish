local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")
local GMView = {}

local function shallow_copy(payload)
  local out = {}
  for key, value in pairs(payload) do out[key] = value end
  return out
end

-- GM 面板一键动作：按钮名、文案与上行载荷。
local GM_ACTIONS = {
  { "BtnGMCoin", "+100 金币", { action = "Coin", amount = 100 } },
  { "BtnGMCoinLarge", "+6300 金币", { action = "Coin", amount = 6300 } },
  { "BtnGMItem", "罗非鱼 ×1", { action = "Item", itemId = GameCfg.Items.Id.Tilapia, count = 1 } },
  { "BtnGMItemFive", "罗非鱼 ×5", { action = "Item", itemId = GameCfg.Items.Id.Tilapia, count = 5 } },
  { "BtnGMAddAttack", "挥砍伤害 +25", { action = "AddAttack" } },
  { "BtnGMGetAttack", "查询挥砍伤害", { action = "GetAttack" } },
  { "BtnGMNextFish", "下一条鲈鱼", { action = "NextFish", fishId = "bass" } },
  { "BtnGMSetHealth", "恢复 100 生命", { action = "SetHealth", value = 100 } },
  { "BtnGMSetHunger", "恢复 100 饥饿", { action = "SetHunger", value = 100 } },
  { "BtnGMGetState", "读取状态", { action = "GetState" } },

  { "BtnGMSaveState", "显式保存", { action = "SaveState" } },
  { "BtnGMReadState", "显式读档", { action = "ReadState" } },
  { "BtnGMSelectSaveSlot", "切换存档槽", { action = "SelectSaveSlot", slot = 1 } },
}

-- 状态补丁输入框的字段顺序（决定排布与类型转换）。
local GM_INPUT_FIELDS = { "coin", "upgrade_level", "container", "index", "itemId", "count", "mult", "slot" }

--- 鱼按钮分页顺序：先两条固定鱼，其余按 id 排序。
---@return string[]
local function gm_fish_ids()
  local fishIds = { "eel", "alligatorGar" }
  local others = {}
  for fishId in pairs(GameCfg.Fish) do
    if fishId ~= "eel" and fishId ~= "alligatorGar" then others[#others + 1] = fishId end
  end
  table.sort(others)
  for _, fishId in ipairs(others) do fishIds[#fishIds + 1] = fishId end
  return fishIds
end

--- 动作按钮按 5 列网格排布。
---@param btn table
---@param idx number
local function place_action(btn, idx)
  local col = (idx - 1) % 5
  local row_idx = math.floor((idx - 1) / 5)
  Modal.place(btn, 20 + col * 174, 274 + row_idx * 48, 164, 40)
end

-- GM 面板句柄：面板节点、分页位置与输入框都留在句柄上；
-- 方法名沿用拆分前的局部函数名，挂载入口只做装配。
---@class GMPanelHandle: table<string, any>
---@type GMPanelHandle
local GMBehavior = {}

--- 发一条 GM 上行（载荷浅拷贝，不暴露面板内部表）。
---@param self GMPanelHandle
---@param payload table
function GMBehavior.send(self, payload)
  local services = self.services
  if type(services.send_gm) == "function" then services.send_gm(shallow_copy(payload)) end
end

--- 按当前分页刷新六个鱼按钮的可见性与文案。
---@param self GMPanelHandle
function GMBehavior.refresh_fish(self)
  local first = (self.fish_page - 1) * 6
  for index, button in ipairs(self.fish_buttons) do
    local fishId = self.fish_ids[first + index]
    button.Visible = fishId ~= nil
    button.TouchEnabled = fishId ~= nil
    Modal.set_button_text(button, fishId and GameCfg.Fish[fishId].Name or "")
  end
  local page_label = self.fish_page_label
  if page_label then
    page_label.Text = string.format("鱼类 %d/%d", self.fish_page, math.max(1, math.ceil(#self.fish_ids / 6)))
  end
end

---@param self GMPanelHandle
---@param index number
function GMBehavior.next_fish(self, index)
  local fishId = self.fish_ids[(self.fish_page - 1) * 6 + index]
  if fishId then self:send({ action = "NextFish", fishId = fishId }) end
end

---@param self GMPanelHandle
function GMBehavior.prev_fish_page(self)
  self.fish_page = math.max(1, self.fish_page - 1)
  self:refresh_fish()
end

---@param self GMPanelHandle
function GMBehavior.next_fish_page(self)
  self.fish_page = math.min(math.max(1, math.ceil(#self.fish_ids / 6)), self.fish_page + 1)
  self:refresh_fish()
end

--- 读输入框拼状态补丁载荷：数值字段转 number，其余按字符串。
---@param self GMPanelHandle
---@param action string
---@return table
function GMBehavior.state_payload(self, action)
  local payload = { action = action }
  for field, input in pairs(self.inputs) do
    local text = input.Text
    if type(text) == "string" and text ~= "" then
      if field == "coin" or field == "upgrade_level" or field == "index" or field == "count" or field == "mult" then
        payload[field] = tonumber(text)
      else
        payload[field] = text
      end
    end
  end
  return payload
end

--- 建面板节点：结果行、鱼分页、状态补丁输入框与一键动作按钮。
---@param self GMPanelHandle
function GMBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenGM", "GM 调试面板")
  self.panel = panel
  self.result = Modal.place(Modal.label(scope, ctx, panel, "LabelGMResult", "等待操作"), 20, 54, 860, 30)
  self.fish_ids = gm_fish_ids()
  for index = 1, 6 do
    self.fish_buttons[index] = Modal.place(Modal.button(scope, ctx, panel, "BtnGMNextFish_" .. tostring(index), "", function()
      self:next_fish(index)
    end), 20 + (index - 1) * 144, 134, 136, 36)
  end
  Modal.place(Modal.button(scope, ctx, panel, "BtnGMFishPrev", "上一页鱼", function()
    self:prev_fish_page()
  end), 20, 92, 120, 34)
  Modal.place(Modal.button(scope, ctx, panel, "BtnGMFishNext", "下一页鱼", function()
    self:next_fish_page()
  end), 300, 92, 120, 34)
  self.fish_page_label = Modal.place(Modal.label(scope, ctx, panel, "LabelGMFishPage", ""), 150, 92, 140, 34)
  self:refresh_fish()

  for index, field in ipairs(GM_INPUT_FIELDS) do
    local col = (index - 1) % 4
    local row_idx = math.floor((index - 1) / 4)
    self.inputs[field] = Modal.place(
      ctx.create_node(scope, "EUIInputField", { Parent = panel, Name = "GMInput_" .. field, Text = "" }),
      20 + col * 218, 182 + row_idx * 42, 206, 34)
  end

  for index, action in ipairs(GM_ACTIONS) do
    place_action(Modal.button(scope, ctx, panel, action[1], action[2], function() self:send(action[3]) end), index)
  end
  place_action(Modal.button(scope, ctx, panel, "BtnGMApplyState", "应用状态补丁", function()
    self:send(self:state_payload("ApplyState"))
  end), #GM_ACTIONS + 1)
  place_action(Modal.button(scope, ctx, panel, "BtnGMSelectNamedSlot", "应用下次进图槽", function()
    self:send(self:state_payload("SelectSaveSlot"))
  end), #GM_ACTIONS + 2)
  Modal.close(scope, ctx, panel, "BtnGMClose", "gm")
end

--- GM 回包投影：结果行文案与状态快照回填输入框。
---@param self GMPanelHandle
---@param es table EffectScope
function GMBehavior.on_result_projection(self, es)
  local value = es:d(self.ctx.store.gm_result)
  if type(value) ~= "table" then return end
  local result = self.result
  if value.ok then
    result.Text = "服务端确认：" .. tostring(value.action or "操作") .. " 成功"
  else
    result.Text = "操作失败：" .. tostring(value.reason or "请求未通过")
  end
  if value.damage then result.Text = result.Text .. "，伤害=" .. tostring(value.damage) end
  local snapshot = value.snapshot
  if type(snapshot) == "table" then
    if snapshot.coin ~= nil then self.inputs.coin.Text = tostring(snapshot.coin) end
    if snapshot.upgrade_level ~= nil then self.inputs.upgrade_level.Text = tostring(snapshot.upgrade_level) end
    if value.status and value.status.slot ~= nil then self.inputs.slot.Text = tostring(value.status.slot) end
  end
end

--- 挂载 GM 面板：造句柄、建节点、接回包投影。
---@param scope table
---@param ctx table
local function mount(scope, ctx)
  ---@type GMPanelHandle
  return ViewUtil.mount_panel(scope, ctx, GMBehavior, {
    fish_ids = {}, fish_page = 1, fish_buttons = {}, fish_page_label = nil,
    inputs = {}, panel = nil, result = nil,
  }, { name = "GMResultProjection", method = "on_result_projection" })
end

function GMView.entry_spec()
  return {
    name = "GMEntry",
    mount = function(scope, ctx)
      local button = Modal.button(scope, ctx, ctx.root_node, "BtnGMEntry", "GM", function()
        local services = ctx.services or {}
        if type(services.open_modal) == "function" then services.open_modal("gm") end
      end)
      button.Visible = GameCfg.Debug and GameCfg.Debug.Enabled == true
    end,
  }
end

function GMView.modal_spec()
  return mount
end

return GMView
