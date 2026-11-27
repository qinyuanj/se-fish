-- 主 HUD 装备浮层的候选清单构建（#412 从 main_hud_equip_popups 拆出，归属 L2 client.views）：
-- 产出候选数据（武器/鱼饵候选、物品名与库存）与选择回调 `choose`；
-- 上行函数 send_operate / send_action 由视图注入、在视图内执行，节点与 Effect 也留在视图里。

local GameCfg = require("common.game_cfg")
local ViewUtil = require("client.views.view_util")

local MainHudEquipCandidates = {}

--- 物品显示名；配置缺项时退回 id 字符串。
---@param id any
---@return string
function MainHudEquipCandidates.item_name(id)
  local def = GameCfg.Items.Definitions[id]
  return def and def.Name or tostring(id)
end

--- 某种鱼饵的库存数；状态非法或缺项按 0。
---@param state any
---@param id any
---@return number
function MainHudEquipCandidates.bait_stock(state, id)
  local bait = type(state) == "table" and type(state.bait) == "table" and state.bait or nil
  local count = (bait ~= nil and id ~= nil) and bait[id] or nil
  return type(count) == "number" and count or 0
end

local function worm_count(state)
  return MainHudEquipCandidates.bait_stock(state, GameCfg.Items.Id.Worm)
end

--- 武器候选：按 id 排序，装备中的武器标记选中，点击经 send_operate 发攻击上行。
---@param state any
---@param send_operate fun(payload: table)
---@return table
function MainHudEquipCandidates.build_weapon_candidates(state, send_operate)
  local weapons = type(state) == "table" and type(state.weapons) == "table" and state.weapons or {}
  local ids = {}
  for id, count in pairs(weapons) do
    if type(count) == "number" then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local equipped = ViewUtil.equipped_weapon(state)
  local list = {}
  for _, id in ipairs(ids) do
    local weapon_id = id
    list[#list + 1] = {
      key = weapon_id,
      name = MainHudEquipCandidates.item_name(weapon_id),
      count = weapons[weapon_id],
      enabled = weapons[weapon_id] > 0,
      selected = weapon_id == equipped,
      choose = function()
        send_operate({ op = "attack", weapon = weapon_id })
      end,
    }
  end
  return list
end

--- 鱼饵候选：固定三种在前、有库存的动态鱼饵在后，再补「不挂鱼饵」与「吃蚯蚓」。
---@param state any
---@param send_action fun(action: string, value: any)
---@return table
function MainHudEquipCandidates.build_bait_candidates(state, send_action)
  local ids = GameCfg.Items.Id
  local fixed = { ids.Worm, ids.Sausage, ids.Duck }
  local dynamic, is_fixed = {}, {}
  for _, id in ipairs(fixed) do
    is_fixed[id] = true
  end
  local bait_map = type(state) == "table" and type(state.bait) == "table" and state.bait or {}
  for id in pairs(bait_map) do
    if not is_fixed[id] and MainHudEquipCandidates.bait_stock(state, id) > 0 then
      dynamic[#dynamic + 1] = id
    end
  end
  table.sort(dynamic)
  local list = {}
  local function add(id)
    local bait_id = id
    local count = MainHudEquipCandidates.bait_stock(state, bait_id)
    list[#list + 1] = {
      key = bait_id,
      name = MainHudEquipCandidates.item_name(bait_id),
      count = count,
      enabled = count > 0,
      selected = type(state) == "table" and state.selectedBait == bait_id,
      choose = function()
        send_action("SelectBait", bait_id)
      end,
    }
  end
  for _, id in ipairs(fixed) do
    add(id)
  end
  for _, id in ipairs(dynamic) do
    add(id)
  end
  list[#list + 1] = {
    key = "NoBait",
    name = "不挂鱼饵",
    enabled = true,
    selected = type(state) ~= "table" or state.selectedBait == nil,
    choose = function()
      send_action("SelectBait")
    end,
  }
  list[#list + 1] = {
    key = "EatWorm",
    name = "吃蚯蚓",
    enabled = worm_count(state) > 0,
    choose = function()
      send_action("EatBait", ids.Worm)
    end,
  }
  return list
end

return MainHudEquipCandidates
