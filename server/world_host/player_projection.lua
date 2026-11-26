-- 玩家快照与存档镜像的纯数据投影；State 收集、引擎写入与离场时序归 PlayerTree。
local GameCfg = require("common.game_cfg")

local PlayerProjection = {}

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function normalize_held(raw)
  if type(raw) ~= "table" then
    return { kind = nil, id = nil, slot = nil }
  end
  return {
    kind = raw.kind,
    id = raw.id,
    slot = raw.slot,
  }
end

local function copy_slots(items, capacity)
  local slots = {}
  if type(items) ~= "table" then
    return slots
  end
  for index = 1, capacity do
    local entry = items[index]
    if type(entry) == "table" and (entry.count or 0) > 0 then
      slots[index] = {
        itemId = entry.itemId,
        count = entry.count,
        containerId = entry.containerId,
        mult = entry.mult,
        cooked = entry.cooked,
      }
    end
  end
  return slots
end

function PlayerProjection.build_item_bar_snapshot(values)
  local item_bar = values.item_bar
  local slot_count = values.slot_count
  local backpack = values.backpack
  local backpack_count = values.backpack_count
  local upgrade_level = values.upgrade_level
  local bait = values.bait
  local coin = values.coin
  local selected_slot = values.selected_slot
  local selected_bait = values.selected_bait
  local weapons = values.weapons
  local selected_weapon = values.selected_weapon
  local held = values.held
  local bait_out = {}
  for item_id, count in pairs(type(bait) == "table" and bait or {}) do
    bait_out[item_id] = count
  end

  local boss_bait = GameCfg.Casting and GameCfg.Casting.BossBait
  if type(boss_bait) == "table" then
    local bosses = {}
    for item_id in pairs(boss_bait) do
      bosses[#bosses + 1] = item_id
    end
    table.sort(bosses)
    for _, item_id in ipairs(bosses) do
      local total = 0
      for _, entry in pairs(type(item_bar) == "table" and item_bar or {}) do
        if type(entry) == "table" and entry.itemId == item_id and (entry.count or 0) > 0 then
          total = total + entry.count
        end
      end
      if total >= 1 then
        bait_out[item_id] = total
      end
    end
  end

  return {
    slots = copy_slots(item_bar, slot_count),
    slotCount = slot_count,
    backpack = copy_slots(backpack, backpack_count),
    backpackCount = backpack_count,
    upgrade_level = upgrade_level,
    bait = bait_out,
    coin = coin,
    selectedSlot = selected_slot,
    selectedBait = selected_bait,
    weapons = deep_copy(type(weapons) == "table" and weapons or {}),
    selectedWeapon = selected_weapon,
    held = normalize_held(held),
  }
end

local function put(patch, path, value)
  patch[#patch + 1] = { path = path, value = value }
end

-- 返回有序赋值补丁。嵌套路径保留存档其他字段，叶子 table 整体替换以避免残留旧键。
function PlayerProjection.build_stage1_mirror(values, container_ids)
  local patch = {}
  put(patch, { "data", "FishCoin" }, values.coin)
  put(patch, { "data", "Zone" }, values.zone_id)
  put(patch, { "data", "upgrade_level" }, values.upgrade_level)
  put(patch, { "data", "containers", container_ids.ItemBar }, deep_copy(values.item_bar or {}))
  put(patch, { "data", "containers", container_ids.Backpack }, deep_copy(values.backpack or {}))
  put(patch, { "data", "Bait" }, deep_copy(values.bait or {}))
  put(patch, { "data", "weapons" }, deep_copy(values.weapons or {}))
  put(patch, { "data", "selected_slot" }, values.selected_slot)
  put(patch, { "data", "selected_bait" }, values.selected_bait)
  put(patch, { "data", "selected_weapon" }, values.selected_weapon)

  put(patch, { "extra", "inventory", "weapons" }, deep_copy(values.weapons or {}))
  put(patch, { "extra", "inventory", "selection", "slot" }, values.selected_slot)
  put(patch, { "extra", "inventory", "selection", "bait" }, values.selected_bait)
  put(patch, { "extra", "inventory", "selection", "weapon" }, values.selected_weapon)
  put(patch, { "extra", "inventory", "selection", "held" }, normalize_held(values.held))

  put(patch, { "extra", "growth", "potions", "item168" }, values.potion_big_count)
  put(patch, { "extra", "growth", "potions", "item167" }, values.potion_speed_count)
  put(patch, { "extra", "growth", "upgrades" }, deep_copy(values.shop_upgrades or {}))
  put(patch, { "extra", "cooldowns" }, deep_copy(values.cooldowns or {}))
  return patch
end

return PlayerProjection
