local Tokens = require("client.ui.tokens")
local Layout = require("client.ui.layout")
local Primitives = require("client.ui.primitives")

local FishCombatView = {}

local CARD_W = 280
local CARD_GAP = 16
local BAR_H = 32
local TAG_H = 24
local WARN_SIZE = 120

local function rows_of(snapshot, key)
  local list = {}
  if type(snapshot) ~= "table" then return list end
  local source = snapshot[key]
  if type(source) ~= "table" then
    if key == "list" then source = snapshot end
  end
  if type(source) ~= "table" then return list end
  for _, row in pairs(source) do
    if type(row) == "table" and row.id ~= nil then
      list[#list + 1] = row
    end
  end
  table.sort(list, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)
  for index, row in ipairs(list) do
    local copy = {}
    for k, v in pairs(row) do
      copy[k] = v
    end
    copy._slot_index = index
    copy._slot_total = #list
    list[index] = copy
  end
  return list
end

local function bar_text(row)
  local name = row.name or row.fishId or "鱼"
  local health = row.health or 0
  local max_health = row.max_health or health
  return tostring(name) .. " " .. tostring(health) .. "/" .. tostring(max_health)
end

local function slot_x(res_w, index, total)
  local count = math.max(1, total or 1)
  local total_w = count * CARD_W + (count - 1) * CARD_GAP
  local start_left = (res_w - total_w) / 2
  local left = start_left + ((index or 1) - 1) * (CARD_W + CARD_GAP)
  return Layout.snap4(left + CARD_W / 2)
end

function FishCombatView.bar_spec()
  return {
    items = function(es, store)
      return rows_of(es:d(store.fish_combat), "list")
    end,
    key_of = function(item)
      return "fish:" .. tostring(item.id)
    end,
    mount = function(scope, ctx, item_signal)
      scope:effect("FishBar", function(es)
        local row = es:d(item_signal) or {}
        local id = tostring(row.id)
        local res = Primitives.resolution(ctx) or { x = 1920, y = 1080 }
        local cx = slot_x(res.x, row._slot_index, row._slot_total)
        local top_y = Layout.snap4(res.y - 208)

        Primitives.label(es, ctx, {
          name = "FishBar_" .. id,
          rect = Layout.rect(cx, top_y - BAR_H / 2, CARD_W, BAR_H),
          text = bar_text(row),
          font_size = Tokens.FONT_SIZE.BODY,
          bold = true,
          color = Tokens.COLOR.WHITE,
          outline = true,
          outline_color = Tokens.COLOR.OUTLINE_DARK,
          z_order = Tokens.Z.HUD_CONTENT,
        })

        if row.label ~= nil then
          Primitives.label(es, ctx, {
            name = "FishTag_" .. id,
            rect = Layout.rect(cx, top_y - BAR_H - 4 - TAG_H / 2, CARD_W, TAG_H),
            text = tostring(row.label),
            font_size = Tokens.FONT_SIZE.CAPTION,
            bold = false,
            color = Tokens.COLOR.TEXT_GOLD,
            outline = true,
            outline_color = Tokens.COLOR.OUTLINE_DARK,
            z_order = Tokens.Z.HUD_CONTENT,
          })
        end
      end, { item_signal })
    end,
  }
end

function FishCombatView.warning_spec()
  return {
    items = function(es, store)
      return rows_of(es:d(store.fish_combat), "warnings")
    end,
    key_of = function(item)
      return "warn:" .. tostring(item.id)
    end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now() or {}
      local res = Primitives.resolution(ctx) or { x = 1920, y = 1080 }
      Primitives.image(scope, ctx, {
        name = "FishWarn_" .. tostring(row.id),
        rect = Layout.center_in(res.x, res.y, WARN_SIZE, WARN_SIZE),
        image = Tokens.ASSET.CIRCLE,
        color = Tokens.COLOR.DANGER,
        opacity = 0.52,
        z_order = Tokens.Z.HUD_FLASH,
        visible = true,
        touch = false,
        swallow = false,
      })
    end,
  }
end

return FishCombatView
