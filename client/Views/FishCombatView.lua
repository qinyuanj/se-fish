
local FishCombatView = {}

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
  return list
end

local function bar_text(row)
  local name = row.name or row.fishId or "鱼"
  local health = row.health or 0
  local max_health = row.maxHealth or health
  return tostring(name) .. " " .. tostring(health) .. "/" .. tostring(max_health)
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
        ctx.create_node(es, "EUITextLabel", {
          Name = "FishBar_" .. id,
          Text = bar_text(row),
          Visible = true,
        })
        if row.label ~= nil then
          ctx.create_node(es, "EUITextLabel", {
            Name = "FishTag_" .. id,
            Text = tostring(row.label),
            Visible = true,
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
      ctx.create_node(scope, "EUIImage", {
        Name = "FishWarn_" .. tostring(row.id),
        Visible = true,
      })
    end,
  }
end

return FishCombatView
