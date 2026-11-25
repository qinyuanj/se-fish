
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local BodyScale = require("common.body_scale")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")

local Effect = Spoke.Effect

local GroundLoot = {}

local function copy_row(row)
  local out = {}
  for k, v in pairs(row) do
    if type(v) ~= "function" then out[k] = v end
  end
  return out
end

local function vec3(x, y, z)
  return Vector3.New(x, y, z)
end

local function read_pos(pos)
  if type(pos) ~= "table" and type(pos) ~= "userdata" then return nil end
  local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end) -- 兼容引擎 Vector3
  if not ok then return nil end
  if not Number.is_finite_number(x) or not Number.is_finite_number(y) or not Number.is_finite_number(z) then
    return nil
  end
  return x, y, z
end

local function distance(a, b)
  local ax, ay, az = read_pos(a)
  local bx, by, bz = read_pos(b)
  if ax == nil or bx == nil then return math.huge end
  local dx, dy, dz = ax - bx, ay - by, az - bz
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function zone_of(zones, zone_id)
  if type(zones) ~= "table" then return nil end
  if zones[zone_id] ~= nil then return zones[zone_id] end
  for _, zone in ipairs(zones) do
    if type(zone) == "table" and zone.id == zone_id then return zone end
  end
  return nil
end

local function item_kind(item_id)
  local definition = type(item_id) == "string" and GameCfg.Items.Definitions[item_id]
  if type(definition) ~= "table" then return nil end
  if definition.Container == GameCfg.Items.ContainerId.Bait then return "bait" end
  if definition.Type == "近战武器" or definition.Type == "远程武器" then return "weapon" end
  return "item"
end

local function occupied(items, capacity)
  local free = 0
  local used = {}
  for index, entry in pairs(type(items) == "table" and items or {}) do
    if type(index) == "number" and type(entry) == "table" and (entry.count or 0) > 0 then
      used[index] = true
    end
  end
  for index = 1, capacity do
    if not used[index] then free = free + 1 end
  end
  return free
end

local function capacities(tree)
  local level = tree.states.upgrade_level and tree.states.upgrade_level:now() or 0
  if not Number.is_finite_number(level) or level < 0 then level = 0 end
  level = math.floor(level)
  local bar = GameCfg.Items.InitialItemBarSlots + level
  if bar > GameCfg.Items.ItemBarSlots then bar = GameCfg.Items.ItemBarSlots end
  local pack = GameCfg.Items.InitialBackpackSlots + level * GameCfg.Items.BackpackSlotsPerUpgrade
  if pack > GameCfg.Items.MaxBackpackSlots then pack = GameCfg.Items.MaxBackpackSlots end
  return bar, pack
end

local function can_accept(tree, item_id, count)
  local kind = item_kind(item_id)
  if kind == nil or not Number.is_finite_number(count) or count < 1 or count ~= math.floor(count) then
    return false
  end
  if kind == "bait" or kind == "weapon" then return true end
  if count > 1 then return false end
  local bar_cap, pack_cap = capacities(tree)
  local free = occupied(tree.states.item_bar:now(), bar_cap) + occupied(tree.states.backpack:now(), pack_cap)
  return free >= 1
end

local function put_into(items, capacity, entry)
  local next_items = {}
  for index = 1, capacity do
    if items[index] ~= nil then next_items[index] = items[index] end
  end
  for index = 1, capacity do
    local current = next_items[index]
    if type(current) ~= "table" or (current.count or 0) <= 0 then
      next_items[index] = entry
      return next_items, true
    end
  end
  return items, false
end

local function grant(tree, spec)
  local kind = item_kind(spec.itemId)
  local count = spec.count or 1
  if kind == "bait" then
    local bait = {}
    local current = tree.states.bait:now() or {}
    for item_id, amount in pairs(current) do bait[item_id] = amount end
    bait[spec.itemId] = (bait[spec.itemId] or 0) + count
    tree:set_bait(bait)
    return true
  end
  if kind == "weapon" then
    local weapons = {}
    local current = tree.states.weapons:now() or {}
    for item_id, amount in pairs(current) do weapons[item_id] = amount end
    weapons[spec.itemId] = (weapons[spec.itemId] or 0) + count
    tree:set_weapons(weapons)
    return true
  end
  if kind ~= "item" or count > 1 then return false end
  local bar_cap, pack_cap = capacities(tree)
  local entry = {
    itemId = spec.itemId,
    count = 1,
    containerId = GameCfg.Items.ContainerId.ItemBar,
    mult = spec.mult,
    cooked = spec.cooked,
  }
  local bar, ok_bar = put_into(tree.states.item_bar:now() or {}, bar_cap, entry)
  if ok_bar then
    tree:set_item_bar(bar)
    return true
  end
  entry.containerId = GameCfg.Items.ContainerId.Backpack
  local pack, ok_pack = put_into(tree.states.backpack:now() or {}, pack_cap, entry)
  if ok_pack then
    tree:set_backpack(pack)
    return true
  end
  return false
end

local function take_slot(tree, container, index)
  local source = container == GameCfg.Items.ContainerId.Backpack
    and (tree.states.backpack:now() or {})
    or (tree.states.item_bar:now() or {})
  local entry = source[index]
  if type(entry) ~= "table" or (entry.count or 0) <= 0 or type(entry.itemId) ~= "string" then
    return nil
  end
  local next_items = {}
  for slot, value in pairs(source) do
    if slot ~= index then next_items[slot] = value end
  end
  if container == GameCfg.Items.ContainerId.Backpack then
    tree:set_backpack(next_items)
  else
    tree:set_item_bar(next_items)
  end
  return {
    itemId = entry.itemId,
    count = entry.count or 1,
    mult = entry.mult,
    cooked = entry.cooked,
    kind = "item",
  }
end

local function player_can_act(tree)
  return tree ~= nil and tree.memos and tree.memos.can_act and tree.memos.can_act:now() == true
end

local function within_reach(player, position)
  local character = player and player.Character
  local pos = character and character.Position
  if pos == nil then return false end
  local radius = BodyScale.interaction_radius(character, GameCfg.Loot.PickupRadius) + (GameCfg.Loot.PickupSlack or 0)
  return distance(pos, position) <= radius
end

function GroundLoot.mount(world, opts)
  opts = type(opts) == "table" and opts or {}
  local scope = assert(opts.scope, "GroundLoot 必须由 SharedWorldTree 根作用域持有")
  local clock = world.clock
  local create_unit = opts.create_unit
  local zones = world.zones or {}
  local spots_cfg = opts.bait_spots or GameCfg.BaitSpots
  local cap = GameCfg.Loot.PerZoneCap
  local flash_sec = GameCfg.Loot.FlashBeforeRecycleSec
  local respawn_sec = spots_cfg.RespawnSec or GameCfg.BaitSpots.RespawnSec

  local records = {}
  local order = {}
  local spot_state = {}
  local next_id = 0
  local broadcasting = false

  local function reply(player, payload)
    local remote = opts.remote
    if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return end
    local event = remote:get_re("LootResult")
    if event and type(event.FireClient) == "function" then event:FireClient(player, payload) end
  end

  local function publish()
    local remote = opts.remote
    if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return end
    local list = {}
    for _, id in ipairs(order) do
      local row = records[id]
      if row ~= nil then
        list[#list + 1] = {
          id = row.id,
          kind = row.kind,
          itemId = row.itemId,
          count = row.count,
          mult = row.mult,
          cooked = row.cooked,
          x = row.x,
          y = row.y,
          z = row.z,
          zoneId = row.zoneId,
          spotId = row.spotId,
          warn = row.warn == true,
        }
      end
    end
    local payload = { list = list }
    if broadcasting then return end
    broadcasting = true
    local ok, err = pcall(function() -- 下行失败不回滚权威地面集合
      remote:get_re("LootState"):FireAllClients(payload)
    end)
    broadcasting = false
    if not ok and opts.logger and type(opts.logger.error) == "function" then
      opts.logger.error("[GroundLoot] LootState 下发失败", err)
    end
  end

  local function destroy_row(id)
    local row = records[id]
    if row == nil then return false end
    records[id] = nil
    for index, value in ipairs(order) do
      if value == id then table.remove(order, index) break end
    end
    local zone = zone_of(zones, row.zoneId)
    if zone and zone.ground_loot and type(zone.ground_loot.drop) == "function" then
      zone.ground_loot:drop(row.key)
    end
    if row.spotId and spot_state[row.spotId] then
      spot_state[row.spotId].loot_id = nil
      spot_state[row.spotId].respawn_at = math.floor(clock.now()) + respawn_sec
    end
    return true
  end

  local function place(zone_id, spec)
    if type(spec) ~= "table" or type(spec.itemId) ~= "string" then return nil end
    if spec.Position ~= nil or spec.Count ~= nil or spec.SpotId ~= nil then return nil end
    local count = spec.count == nil and 1 or spec.count
    if not Number.is_finite_number(count) or count < 1 or count ~= math.floor(count) then return nil end
    if spec.spotId ~= nil and type(spec.spotId) ~= "string" then return nil end
    local zone = zone_of(zones, zone_id)
    if zone == nil or zone.ground_loot == nil then return nil end
    local x, y, z = read_pos(spec)
    if x == nil then x, y, z = read_pos(spec.position) end
    if x == nil then return nil end
    next_id = next_id + 1
    local id = tostring(next_id)
    local key = "loot:" .. id
    local row = {
      id = id,
      key = key,
      kind = spec.kind or "item",
      itemId = spec.itemId,
      count = count,
      mult = spec.mult,
      cooked = spec.cooked,
      x = x, y = y, z = z,
      zoneId = zone_id,
      spotId = spec.spotId,
      warn = false,
      recycle_at = nil,
    }
    records[id] = row
    order[#order + 1] = id
    zone.ground_loot:effect(key, function(es)
      local unit = nil
      if type(create_unit) == "function" then
        local mesh = row.kind == "bait" and spots_cfg.Mesh or GameCfg.Loot.ItemMesh
        local scale = row.kind == "bait" and (spots_cfg.Scale or GameCfg.BaitSpots.Scale) or GameCfg.Loot.ItemScale
        unit = create_unit("WorldUnit", {
          Name = (row.kind == "bait" and "BaitSpot_" or "GroundLoot_") .. id,
          Position = vec3(x, y + GameCfg.Loot.Height, z),
          RenderMeshId = mesh,
          Scale = vec3(scale, scale, scale),
          PhysicsActive = false,
          GravityEnabled = false,
          CanCollide = false,
          Liftable = false,
        })
      end
      row.unit = unit
      es:on_cleanup(function()
        if unit ~= nil and type(unit.Destroy) == "function" and unit.Destroyed ~= true then
          local ok_destroy, err_destroy = pcall(function() unit:Destroy() end) -- 宿主单位可能已随场景销毁
          if not ok_destroy and opts.logger and type(opts.logger.error) == "function" then
            opts.logger.error("[GroundLoot] 单位销毁失败", id, err_destroy)
          end
        end
        if records[id] == row then
          records[id] = nil
          for index, value in ipairs(order) do
            if value == id then table.remove(order, index) break end
          end
        end
        local spot = row.spotId and spot_state[row.spotId]
        if spot and spot.loot_id == id then
          spot.loot_id = nil
          spot.respawn_at = math.floor(clock.now()) + respawn_sec
        end
      end)
    end)
    local zone_count = 0
    for _, existing_id in ipairs(order) do
      local existing = records[existing_id]
      if existing and existing.zoneId == zone_id and existing.recycle_at == nil then
        zone_count = zone_count + 1
      end
    end
    if zone_count > cap then
      for _, existing_id in ipairs(order) do
        local existing = records[existing_id]
        if existing and existing.zoneId == zone_id and existing.recycle_at == nil then
          existing.warn = true
          existing.recycle_at = math.floor(clock.now()) + flash_sec
          break
        end
      end
    end
    publish()
    return id
  end

  local function spawn_spot(spot)
    local state = spot_state[spot.Id]
    if state == nil or state.loot_id ~= nil then return nil end
    local zone_id = spot.ZoneId
    if zone_id == nil then
      local pos = spot.Position or {}
      zone_id = world.zones and nil
      for _, zone in ipairs(world.zone_list or {}) do
        if zone_id == nil then zone_id = zone.id end
      end
      if pos.x == nil then return nil end
    end
    if zone_of(zones, zone_id) == nil then return nil end
    local pos = spot.Position or { x = 0, y = 0, z = 0 }
    local id = place(zone_id, {
      kind = "bait",
      itemId = spot.ItemId,
      count = spot.Count or 1,
      x = pos.x,
      y = pos.y or 0,
      z = pos.z,
      spotId = spot.Id,
    })
    if id ~= nil then
      state.loot_id = id
      state.respawn_at = nil
    end
    return id
  end

  if spots_cfg.Enabled ~= false then
    for _, spot in ipairs(spots_cfg.Spots or {}) do
      if type(spot) == "table" and type(spot.Id) == "string" then
        spot_state[spot.Id] = { cfg = spot, loot_id = nil, respawn_at = nil }
        spawn_spot(spot)
      end
    end
  end

  local function on_second()
    local sec = math.floor(clock.now())
    local expired = {}
    for _, id in ipairs(order) do
      local row = records[id]
      if row and row.recycle_at ~= nil and sec >= row.recycle_at then
        expired[#expired + 1] = id
      end
    end
    for _, id in ipairs(expired) do
      local row = records[id]
      if row then
        local zone = zone_of(zones, row.zoneId)
        if zone and zone.ground_loot then zone.ground_loot:drop(row.key) end
      end
    end
    for _, state in pairs(spot_state) do
      if state.loot_id == nil and state.respawn_at ~= nil and sec >= state.respawn_at then
        spawn_spot(state.cfg)
      end
    end
    if #expired > 0 then publish() end
  end

  scope:effect("GroundLootClock", function(es)
    es:subscribe(clock.on_second, on_second)
  end)

  function world:place_ground_item(zone_id, spec)
    if world:is_disposed() then return false end
    local id = place(zone_id, spec or {})
    return id ~= nil
  end

  local deliveries = {}

  function world:place_delivery(key, zone_id, spec)
    if type(key) ~= "string" or key == "" then return nil, "bad-key" end
    local prior = deliveries[key]
    if prior ~= nil then return prior end
    if world:is_disposed() then return nil, "disposed" end
    local id = place(zone_id, spec or {})
    if id == nil then return nil, "rejected" end
    local receipt = { Id = id }
    deliveries[key] = receipt
    return receipt
  end

  function world:ground_snapshot()
    local list = {}
    for _, id in ipairs(order) do
      local row = records[id]
      if row then list[#list + 1] = copy_row(row) end
    end
    return { list = list }
  end

  local function lookup_tree(player)
    if type(opts.lookup_tree) == "function" then return opts.lookup_tree(player) end
    return nil
  end

  local remote_active = false
  scope:effect("GroundLootRemote", function(es)
    remote_active = true
    es:on_cleanup(function()
      remote_active = false
    end)
  end)

  local function allow_remote(player, channel, skip_cd)
    local tree = lookup_tree(player)
    if not remote_active or world:is_disposed() or not tree or tree:is_disposed() then return false end
    local remote = opts.remote
    if not skip_cd and type(remote) == "table" and type(remote.check_recd) == "function"
        and remote:check_recd(player, channel, GameCfg.Items.ActionCooldownSec) then
      return false
    end
    return true
  end

  function world:handle_item_bar_action(player, payload, skip_cd)
    if type(payload) ~= "table" then return false end
    if payload.action ~= "Pickup" and payload.action ~= "Drop" then return false end
    if not allow_remote(player, "ItemBarAction", skip_cd) then return false end
    if payload.action == "Pickup" then
      return world:try_pickup(player, payload.value)
    end
    return world:try_drop(player, payload.container, payload.index)
  end

  function world:handle_loot_request(player, skip_cd)
    if not allow_remote(player, "RequestLoot", skip_cd) then return false end
    local remote = opts.remote
    if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return false end
    local list = {}
    for _, id in ipairs(order) do
      local row = records[id]
      if row then
        list[#list + 1] = {
          id = row.id, kind = row.kind, itemId = row.itemId,
          x = row.x, y = row.y, z = row.z,
          warn = row.warn == true, spotId = row.spotId, zoneId = row.zoneId,
        }
      end
    end
    local state = remote:get_re("LootState")
    if state and type(state.FireClient) == "function" then
      state:FireClient(player, { list = list })
      return true
    end
    return false
  end

  function world:try_pickup(player, loot_id)
    if world:is_disposed() then return false, "disposed" end
    if type(loot_id) ~= "string" and type(loot_id) ~= "number" then return false, "bad" end
    local id = tostring(loot_id)
    local row = records[id]
    if row == nil then return false, "missing" end
    local tree = lookup_tree(player)
    if not player_can_act(tree) then return false, "cannot-act" end
    if not within_reach(player, { x = row.x, y = row.y, z = row.z }) then return false, "far" end
    if not can_accept(tree, row.itemId, row.kind == "bait" and (row.count or 1) or 1) then
      return false, "full"
    end
    local committed = false
    local function commit()
      local current = records[id]
      if current == nil or not player_can_act(tree) then return end
      if not can_accept(tree, current.itemId, current.kind == "bait" and (current.count or 1) or 1) then return end
      if not grant(tree, current) then return end
      local zone = zone_of(zones, current.zoneId)
      if zone and zone.ground_loot then zone.ground_loot:drop(current.key) end
      committed = records[id] == nil
    end
    SpokeRuntime.batch(commit)
    if committed then
      publish()
      reply(player, { ok = true, action = "Pickup", id = id })
      return true
    end
    reply(player, { ok = false, action = "Pickup", id = id, reason = "rejected" })
    return false, "rejected"
  end

  function world:on_carrier_killed(killed)
    if world:is_disposed() or type(killed) ~= "table" or (type(killed.position) ~= "table" and type(killed.position) ~= "userdata") then return false end
    local species = GameCfg.Fish[killed.fishId]
    if species == nil then return false end
    local zone_id = killed.zoneId
    if zone_of(zones, zone_id) == nil then
      zone_id = world.zone_list[1] and world.zone_list[1].id
    end
    if zone_of(zones, zone_id) == nil then return false end
    local placed = {}
    local function commit()
      local origin = killed.position
      local drops = species.Drops
      if type(drops) == "table" then
        local total = 0
        for _, drop in ipairs(drops) do total = total + (drop.Count or 0) end
        local index = 0
        for _, drop in ipairs(drops) do
          for _ = 1, drop.Count or 0 do
            index = index + 1
            local id = place(zone_id, {
              kind = "item",
              itemId = drop.ItemId,
              count = 1,
              mult = killed.mult,
              fishId = killed.fishId,
              x = origin.x + (index - (total + 1) / 2) * (GameCfg.Loot.DropSpacing or 1),
              y = origin.y or 0,
              z = origin.z,
            })
            if id ~= nil then placed[#placed + 1] = id end
          end
        end
      else
        local id = place(zone_id, {
          kind = "item",
          itemId = killed.fishId,
          count = 1,
          mult = killed.mult,
          fishId = killed.fishId,
          x = origin.x, y = origin.y or 0, z = origin.z,
        })
        if id ~= nil then placed[#placed + 1] = id end
      end
    end
    SpokeRuntime.batch(commit)
    return #placed > 0, placed
  end

  function world:try_drop(player, container, index)
    if world:is_disposed() then return false, "disposed" end
    local tree = lookup_tree(player)
    if not player_can_act(tree) then return false, "cannot-act" end
    if not Number.is_finite_number(index) or index ~= math.floor(index) or index < 1 then return false, "bad" end
    local source = container == GameCfg.Items.ContainerId.Backpack
      and (tree.states.backpack:now() or {})
      or (tree.states.item_bar:now() or {})
    local entry = source[index]
    if type(entry) ~= "table" or (entry.count or 0) <= 0 then return false, "empty" end
    local pos = player.Character and player.Character.Position
    local x, y, z = read_pos(pos)
    if x == nil then return false, "no-character" end
    local zone_id = tree.states.zone_id:now()
    if zone_of(zones, zone_id) == nil then
      zone_id = world.zone_list[1] and world.zone_list[1].id
    end
    if zone_of(zones, zone_id) == nil then return false, "no-zone" end
    local dropped = false
    local function commit_drop()
      if not player_can_act(tree) then return end
      local taken = take_slot(tree, container, index)
      if taken == nil then return end
      local id = place(zone_id, {
        kind = "item",
        itemId = taken.itemId,
        count = taken.count,
        mult = taken.mult,
        cooked = taken.cooked,
        x = x + GameCfg.Loot.DropOffset,
        y = y,
        z = z,
      })
      dropped = id ~= nil
    end
    SpokeRuntime.batch(commit_drop)
    reply(player, { ok = dropped == true, action = "Drop", index = index })
    return dropped
  end

  return world
end

return GroundLoot
