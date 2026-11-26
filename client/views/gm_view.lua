local GameCfg = require("common.game_cfg")
local Modal = require("client.views.economy_modal")
local GMView = {}

local function copy(payload)
  local out = {}
  for key, value in pairs(payload) do out[key] = value end
  return out
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
  return function(scope, ctx)
    local services = ctx.services or {}
    local panel = Modal.panel(scope, ctx, "ScreenGM", "GM 调试面板")
    local result = Modal.place(Modal.label(scope, ctx, panel, "LabelGMResult", "等待操作"), 20, 54, 860, 30)
    local function send(payload)
      if type(services.send_gm) == "function" then services.send_gm(copy(payload)) end
    end
    local fishIds = { "eel", "alligatorGar" }
    local others = {}
    for fishId in pairs(GameCfg.Fish) do
      if fishId ~= "eel" and fishId ~= "alligatorGar" then others[#others + 1] = fishId end
    end
    table.sort(others)
    for _, fishId in ipairs(others) do fishIds[#fishIds + 1] = fishId end
    local fishPage = 1
    local fishButtons, fishPageLabel = {}, nil
    local function refresh_fish()
      local first = (fishPage - 1) * 6
      for index, button in ipairs(fishButtons) do
        local fishId = fishIds[first + index]
        button.Visible = fishId ~= nil
        button.TouchEnabled = fishId ~= nil
        button.ButtonText = fishId and GameCfg.Fish[fishId].Name or ""
      end
      if fishPageLabel then fishPageLabel.Text = string.format("鱼类 %d/%d", fishPage, math.max(1, math.ceil(#fishIds / 6))) end
    end
    for index = 1, 6 do
      fishButtons[index] = Modal.place(Modal.button(scope, ctx, panel, "BtnGMNextFish_" .. tostring(index), "", function()
        local fishId = fishIds[(fishPage - 1) * 6 + index]
        if fishId then send({ action = "NextFish", fishId = fishId }) end
      end), 20 + (index - 1) * 144, 134, 136, 36)
    end
    Modal.place(Modal.button(scope, ctx, panel, "BtnGMFishPrev", "上一页鱼", function()
      fishPage = math.max(1, fishPage - 1)
      refresh_fish()
    end), 20, 92, 120, 34)
    Modal.place(Modal.button(scope, ctx, panel, "BtnGMFishNext", "下一页鱼", function()
      fishPage = math.min(math.max(1, math.ceil(#fishIds / 6)), fishPage + 1)
      refresh_fish()
    end), 300, 92, 120, 34)
    fishPageLabel = Modal.place(Modal.label(scope, ctx, panel, "LabelGMFishPage", ""), 150, 92, 140, 34)
    refresh_fish()
    local inputs = {}
    local input_fields = { "coin", "upgrade_level", "container", "index", "itemId", "count", "mult", "slot" }
    for index, field in ipairs(input_fields) do
      local col = (index - 1) % 4
      local row_idx = math.floor((index - 1) / 4)
      inputs[field] = Modal.place(
        ctx.create_node(scope, "EUIInputField", { Parent = panel, Name = "GMInput_" .. field, Text = "" }),
        20 + col * 218, 182 + row_idx * 42, 206, 34)
    end
    local function state_payload(action)
      local payload = { action = action }
      for field, input in pairs(inputs) do
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
    local actions = {
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
    local function place_action(btn, idx)
      local col = (idx - 1) % 5
      local row_idx = math.floor((idx - 1) / 5)
      Modal.place(btn, 20 + col * 174, 274 + row_idx * 48, 164, 40)
    end
    for index, action in ipairs(actions) do
      place_action(Modal.button(scope, ctx, panel, action[1], action[2], function() send(action[3]) end), index)
    end
    place_action(Modal.button(scope, ctx, panel, "BtnGMApplyState", "应用状态补丁", function() send(state_payload("ApplyState")) end), #actions + 1)
    place_action(Modal.button(scope, ctx, panel, "BtnGMSelectNamedSlot", "应用下次进图槽", function() send(state_payload("SelectSaveSlot")) end), #actions + 2)
    Modal.close(scope, ctx, panel, "BtnGMClose", "gm")
    scope:effect("GMResultProjection", function(es)
      local value = es:d(ctx.store.gm_result)
      if type(value) ~= "table" then return end
      if value.ok then
        result.Text = "服务端确认：" .. tostring(value.action or "操作") .. " 成功"
      else
        result.Text = "操作失败：" .. tostring(value.reason or "请求未通过")
      end
      if value.damage then result.Text = result.Text .. "，伤害=" .. tostring(value.damage) end
      local snapshot = value.snapshot
      if type(snapshot) == "table" then
        if snapshot.coin ~= nil then inputs.coin.Text = tostring(snapshot.coin) end
        if snapshot.upgrade_level ~= nil then inputs.upgrade_level.Text = tostring(snapshot.upgrade_level) end
        if value.status and value.status.slot ~= nil then inputs.slot.Text = tostring(value.status.slot) end
      end
    end)
  end
end

return GMView
