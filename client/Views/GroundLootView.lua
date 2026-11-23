-- 地面物品气泡与瞄准拾取蒙版（ADR-0032 / #301，归属 L2 client.Views）。
-- 订阅只读 ClientStore 的地面快照与本地位置：范围内才建气泡，离开、消失或根销毁时由视图树拆干净。
-- 瞄准拾取蒙版挂在 RootView 覆盖相位上，退出瞄准或销毁根后零残留。

local GameCfg = require("common.GameCfg")
local Number = require("common.Number")

local GroundLootView = {}

local function rows_of(loot)
  local list = {}
  if type(loot) ~= "table" then return list end
  local source = type(loot.list) == "table" and loot.list or loot
  for _, row in pairs(source) do
    if type(row) == "table" and (row.id ~= nil or row.Id ~= nil) then
      list[#list + 1] = row
    end
  end
  table.sort(list, function(a, b)
    return tostring(a.id or a.Id) < tostring(b.id or b.Id)
  end)
  return list
end

local function near(position, row, radius)
  if type(position) ~= "table" or type(row) ~= "table" then return false end
  if not Number.IsFiniteNumber(position.x) or not Number.IsFiniteNumber(row.x) then return false end
  local dx = position.x - row.x
  local dy = (position.y or 0) - (row.y or 0)
  local dz = (position.z or 0) - (row.z or 0)
  return dx * dx + dy * dy + dz * dz <= radius * radius
end

function GroundLootView.bubble_spec(options)
  options = type(options) == "table" and options or {}
  local radius = options.radius or GameCfg.Loot.PickupRadius
  return {
    items = function(es, store)
      local loot = es:d(store.loot)
      local position = es:d(store.position)
      local list = {}
      for _, row in ipairs(rows_of(loot)) do
        if near(position, row, radius) then
          list[#list + 1] = row
        end
      end
      return list
    end,
    key_of = function(item)
      return "loot:" .. tostring(item.id or item.Id)
    end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now() or {}
      local id = row.id or row.Id
      local button = ctx.create_node(scope, "EUIButton", {
        Name = "BtnPickup_" .. tostring(id),
        ButtonText = "拾取",
        TouchEnabled = true,
        Visible = true,
      })
      ctx.connect(scope, button.OnClicked, function()
        if type(options.send) == "function" then
          options.send({ action = "Pickup", value = id })
        end
      end)
    end,
  }
end

function GroundLootView.aim_spec(options)
  options = type(options) == "table" and options or {}
  return {
    when = function(ms, store)
      local flags = ms:d(store.overlays)
      return type(flags) == "table" and flags.aim_pickup == true
    end,
    mount = function(scope, ctx)
      local mask = ctx.create_node(scope, "EUIImage", {
        Name = "AimPickupMask",
        Visible = true,
      })
      if type(options.on_pick) == "function" then
        ctx.connect(scope, mask.OnClicked, function()
          options.on_pick()
        end)
      end
    end,
  }
end

return GroundLootView
