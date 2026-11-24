
local body_scale = require("common.body_scale")
local game_cfg = require("common.game_cfg")
local view_util = require("client.views.view_util")

local ground_loot_view = {}

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
  local dist_sq = view_util.distance_sq_xyz(position, row)
  return dist_sq ~= nil and dist_sq <= radius * radius
end

function ground_loot_view.pick_nearest(store, radius)
  if type(store) ~= "table" then return nil end
  local position = store.position and store.position:now() or nil
  local character = store.local_character and store.local_character:now() or nil
  local loot = store.loot and store.loot:now() or nil
  if position == nil then return nil end
  local base_radius = radius or game_cfg.Loot.PickupRadius
  local effective = body_scale.InteractionRadius(character, base_radius)
  local limit_sq = effective * effective
  local best_id, best_dist = nil, nil
  for _, row in ipairs(rows_of(loot)) do
    local dist_sq = view_util.distance_sq_xyz(position, row)
    if dist_sq ~= nil and dist_sq <= limit_sq and (best_dist == nil or dist_sq < best_dist) then
      best_dist = dist_sq
      best_id = row.id or row.Id
    end
  end
  return best_id
end

function ground_loot_view.bubble_spec(options)
  options = type(options) == "table" and options or {}
  local base_radius = options.radius or game_cfg.Loot.PickupRadius
  return {
    items = function(es, store)
      local loot = es:d(store.loot)
      local position = es:d(store.position)
      local character = es:d(store.local_character)
      local radius = options.radius or body_scale.InteractionRadius(character, base_radius)
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

function ground_loot_view.aim_toggle_spec(options)
  options = type(options) == "table" and options or {}
  local base_radius = options.radius or game_cfg.Loot.PickupRadius
  return {
    name = "GroundLootAimToggle",
    mount = function(scope, ctx)
      local function set_aim(active)
        local fn = ctx.services and ctx.services.set_overlay
        if type(fn) == "function" then
          fn("aim_pickup", active == true)
        end
      end

      local has_nearby = scope:memo("GroundLootNearby", function(ms)
        if ms:d(ctx.store.hud_visible) == false then
          return false
        end
        local position = ms:d(ctx.store.position)
        if position == nil then
          return false
        end
        local character = ms:d(ctx.store.local_character)
        local radius = options.radius or body_scale.InteractionRadius(character, base_radius)
        local loot = ms:d(ctx.store.loot)
        for _, row in ipairs(rows_of(loot)) do
          if near(position, row, radius) then
            return true
          end
        end
        return false
      end)

      scope:phase("GroundLootAimTogglePhase", has_nearby, function(ps)
        local button = ctx.create_node(ps, "EUIButton", {
          Name = "BtnAimPickup",
          ButtonText = "瞄准拾取",
          TouchEnabled = true,
          Visible = true,
        })
        ctx.connect(ps, button.OnClicked, function()
          local flags = ctx.store.overlays:now()
          local active = type(flags) == "table" and flags.aim_pickup == true
          set_aim(not active)
        end)
        ps:on_cleanup(function()
          set_aim(false)
        end)
      end)

      scope:subscribe(ctx.store.on_server_event, function(event)
        if type(event) ~= "table" or event.channel ~= "LootResult" then
          return
        end
        local result = event.payload
        if type(result) == "table" and result.reason == "full" then
          view_util.notify(ctx, "背包已满")
        end
      end)
    end,
  }
end

function ground_loot_view.aim_spec(options)
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
      mask.TouchEnabled = true
      local function handle_pick()
        if type(options.on_pick) == "function" then
          options.on_pick(ctx)
        elseif type(options.send) == "function" then
          local id = ground_loot_view.pick_nearest(ctx.store, options.radius)
          if id ~= nil then
            options.send({ action = "Pickup", value = id })
          end
        end
        local set_overlay = ctx.services and ctx.services.set_overlay
        if type(set_overlay) == "function" then
          set_overlay("aim_pickup", false)
        end
      end
      ctx.connect(scope, mask.OnClicked, handle_pick)
    end,
  }
end

return ground_loot_view
