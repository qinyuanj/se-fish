local GameCfg = require("common.game_cfg")
local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")
local Controls = require("client.ui.controls")
local Modal = require("client.views.economy_modal")
local ViewUtil = require("client.views.view_util")

local GMView = {}

local PANEL_W = 1040
local PANEL_H = 680
local PAD = Tokens.SPACE.PANEL_PAD

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
  local fish_ids = { "eel", "alligatorGar" }
  local others = {}
  for fish_id in pairs(GameCfg.Fish) do
    if fish_id ~= "eel" and fish_id ~= "alligatorGar" then others[#others + 1] = fish_id end
  end
  table.sort(others)
  for _, fish_id in ipairs(others) do fish_ids[#fish_ids + 1] = fish_id end
  return fish_ids
end

-- GM 面板句柄：面板节点、分页位置与输入框都留在句柄上。
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
    local fish_id = self.fish_ids[first + index]
    button.Visible = fish_id ~= nil
    Controls.set_button_enabled(button, fish_id ~= nil, "card")
    Controls.set_button_text(button, fish_id and GameCfg.Fish[fish_id].Name or "")
  end
  local page_label = self.fish_page_label
  if page_label then
    page_label.Text = string.format("鱼类 %d/%d", self.fish_page, math.max(1, math.ceil(#self.fish_ids / 6)))
  end
end

---@param self GMPanelHandle
---@param index number
function GMBehavior.next_fish(self, index)
  local fish_id = self.fish_ids[(self.fish_page - 1) * 6 + index]
  if fish_id then self:send({ action = "NextFish", fishId = fish_id }) end
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

--- 建面板节点：基于 Controls.modal_shell 与 Layout.grid_cell 规范排布全部调试控件。
---@param self GMPanelHandle
function GMBehavior.create_nodes(self)
  local scope, ctx = self.scope, self.ctx
  local panel = Modal.panel(scope, ctx, "ScreenGM", "GM 调试面板", {
    width = PANEL_W,
    height = PANEL_H,
    close_name = "BtnGMClose",
    modal_id = "gm",
  })
  self.panel = panel

  local content_w = PANEL_W - PAD * 2
  self.result = Primitives.label(scope, ctx, {
    name = "LabelGMResult",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD, 84, content_w, 36),
    text = "等待操作",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.TEXT_GOLD_DARK,
    align_x = 0,
    align_y = 1,
    z_order = 2,
  })

  -- 鱼种分页栏
  Controls.button(scope, ctx, {
    name = "BtnGMFishPrev",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, PAD, 132, 136, 40),
    text = "上一页鱼",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 2,
    on_click = function() self:prev_fish_page() end,
  })
  self.fish_page_label = Primitives.label(scope, ctx, {
    name = "LabelGMFishPage",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 180, 132, 160, 40),
    text = "",
    font_size = Tokens.FONT_SIZE.CAPTION,
    bold = true,
    color = Tokens.COLOR.TEXT_DARK,
    align_x = 1,
    align_y = 1,
    z_order = 2,
  })
  Controls.button(scope, ctx, {
    name = "BtnGMFishNext",
    parent = panel,
    rect = Layout.from_top_left(PANEL_H, 352, 132, 136, 40),
    text = "下一页鱼",
    variant = "blue",
    font_size = Tokens.FONT_SIZE.CAPTION,
    z_order = 2,
    on_click = function() self:next_fish_page() end,
  })

  -- 6 个鱼种快捷按钮（6 列网格，总宽 976px）
  self.fish_ids = gm_fish_ids()
  for index = 1, 6 do
    local rect = Layout.grid_cell(PANEL_H, PAD, 184, 6, index, 156, 44, 8, 8)
    self.fish_buttons[index] = Controls.button(scope, ctx, {
      name = "BtnGMNextFish_" .. tostring(index),
      parent = panel,
      rect = rect,
      text = "",
      variant = "card",
      font_size = Tokens.FONT_SIZE.CAPTION,
      z_order = 2,
      on_click = function() self:next_fish(index) end,
    })
  end
  self:refresh_fish()

  -- 8 个状态补丁输入框（4 列 × 2 行，总宽 976px）
  for index, field in ipairs(GM_INPUT_FIELDS) do
    local rect = Layout.grid_cell(PANEL_H, PAD, 244, 4, index, 232, 40, 16, 12)
    local input = ctx.create_node(scope, "EUIInputField", {
      Parent = panel,
      Name = "GMInput_" .. field,
      Position = Tokens.vec2(rect.x, rect.y),
      Size = Tokens.vec2(rect.w, rect.h),
      Text = "",
      Visible = true,
      TouchEnabled = true,
      LocalZOrder = 2,
    })
    input.TouchEnabled = true
    pcall(function() input.PlaceholderText = field end) -- 兼容测试替身缺少 PlaceholderText 字段
    self.inputs[field] = input
  end

  -- 15 个一键调试动作按钮（5 列 × 3 行）
  local function add_action(idx, name, text, variant, on_click)
    local rect = Layout.grid_cell(PANEL_H, PAD, 356, 5, idx, 184, 56, 12, 16)
    Controls.button(scope, ctx, {
      name = name,
      parent = panel,
      rect = rect,
      text = text,
      variant = variant,
      font_size = Tokens.FONT_SIZE.CAPTION,
      z_order = 2,
      on_click = on_click,
    })
  end

  for index, action in ipairs(GM_ACTIONS) do
    add_action(index, action[1], action[2], "surface", function() self:send(action[3]) end)
  end
  add_action(#GM_ACTIONS + 1, "BtnGMApplyState", "应用状态补丁", "gold", function()
    self:send(self:state_payload("ApplyState"))
  end)
  add_action(#GM_ACTIONS + 2, "BtnGMSelectNamedSlot", "应用下次进图槽", "blue", function()
    self:send(self:state_payload("SelectSaveSlot"))
  end)
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
      local services = ctx.services or {}
      local rect = type(services.hud_entry_rect) == "function" and services.hud_entry_rect("GMEntry") or nil
      local button = Controls.button(scope, ctx, {
        name = "BtnGMEntry",
        parent = ctx.root_node,
        rect = rect or Layout.rect(80, 280, 96, 44),
        text = "GM",
        variant = "hud",
        font_size = Tokens.FONT_SIZE.CAPTION,
        z_order = Tokens.Z.HUD_CONTENT,
        visible = GameCfg.Debug and GameCfg.Debug.Enabled == true,
        on_click = function()
          if type(services.open_modal) == "function" then services.open_modal("gm") end
        end,
      })
      if rect then Layout.apply(button, rect) end
    end,
  }
end

function GMView.modal_spec()
  return mount
end

return GMView
