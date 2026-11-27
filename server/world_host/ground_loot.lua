local EngineRead = require("common.engine_read")
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

-- 统一经 EngineRead 读取三维坐标，区分缺失、销毁与异常。
local function read_pos(pos)
  local ok, vec = EngineRead.read_vec3(pos, "GroundLoot.read_pos")
  if not ok or vec == nil then
    return nil
  end
  return vec.x, vec.y, vec.z
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
  local ok_ch, character = EngineRead.read_character(player, "GroundLoot.within_reach")
  if not ok_ch or character == nil then return false end
  local ok_pos, pos = EngineRead.read_position(character, "GroundLoot.within_reach")
  if not ok_pos or pos == nil then return false end
  local radius = BodyScale.interaction_radius(character, GameCfg.Loot.PickupRadius) + (GameCfg.Loot.PickupSlack or 0)
  return distance(pos, position) <= radius
end

-- 战利品句柄的内部行为：self 是挂载句柄（即 world），依赖统一从 self.ground_loot_env 读取。
local GroundLootBehavior = {}

-- 对外方法表：mount 时整体装到 world 上，方法名与签名沿用拆分前的 world 方法。
local GroundLootHost = {}

-- 取远程连接：缺少 get_re 的 remote 视为不可用，调用方静默跳过。
local function remote_of(env)
  local remote = env.opts.remote
  if type(remote) ~= "table" or type(remote.get_re) ~= "function" then return nil end
  return remote
end

local function log_error(env, message, err)
  local logger = env.opts.logger
  if logger and type(logger.error) == "function" then logger.error(message, err) end
end

local function lookup_tree(env, player)
  if type(env.opts.lookup_tree) == "function" then return env.opts.lookup_tree(player) end
  return nil
end

-- 校验投放参数：只接受小写字段形态，非法直接拒绝。
local function place_args(spec)
  if type(spec) ~= "table" or type(spec.itemId) ~= "string" then return nil end
  if spec.Position ~= nil or spec.Count ~= nil or spec.SpotId ~= nil then return nil end
  local count = spec.count == nil and 1 or spec.count
  if not Number.is_finite_number(count) or count < 1 or count ~= math.floor(count) then return nil end
  if spec.spotId ~= nil and type(spec.spotId) ~= "string" then return nil end
  return count
end

-- 统计某区域尚未进入回收倒计时的行数。
local function live_zone_count(env, zone_id)
  local count = 0
  for _, existing_id in ipairs(env.order) do
    local existing = env.records[existing_id]
    if existing and existing.zoneId == zone_id and existing.recycle_at == nil then
      count = count + 1
    end
  end
  return count
end

function GroundLootBehavior.reply(self, player, payload)
  local env = self.ground_loot_env
  local remote = remote_of(env)
  if remote == nil then return end
  local event = remote:get_re("LootResult")
  if event and type(event.FireClient) == "function" then event:FireClient(player, payload) end
end

function GroundLootBehavior.publish(self)
  local env = self.ground_loot_env
  local remote = remote_of(env)
  if remote == nil then return end
  local list = {}
  for _, id in ipairs(env.order) do
    local row = env.records[id]
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
  if env.broadcasting then return end
  env.broadcasting = true
  local ok, err = pcall(function() -- 下行失败不回滚权威地面集合
    remote:get_re("LootState"):FireAllClients(payload)
  end)
  env.broadcasting = false
  if not ok then log_error(env, "[GroundLoot] LootState 下发失败", err) end
end

-- 登记一行战利品：先进 records/order，再返回行本体供作用域持有。
function GroundLootBehavior.register(self, zone_id, spec, count, x, y, z)
  local env = self.ground_loot_env
  env.next_id = env.next_id + 1
  local id = tostring(env.next_id)
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
  env.records[id] = row
  env.order[#env.order + 1] = id
  return row
end

-- 在区域地面挂出单位与清理效果：单位随行销毁，清理时同步退登记与占位。
function GroundLootBehavior.mount_row(self, zone, row)
  local env = self.ground_loot_env
  local id = row.id
  zone.ground_loot:effect(row.key, function(es)
    local unit = nil
    if type(env.create_unit) == "function" then
      local mesh = row.kind == "bait" and env.spots_cfg.Mesh or GameCfg.Loot.ItemMesh
      local scale = row.kind == "bait" and (env.spots_cfg.Scale or GameCfg.BaitSpots.Scale) or GameCfg.Loot.ItemScale
      unit = env.create_unit("WorldUnit", {
        Name = (row.kind == "bait" and "BaitSpot_" or "GroundLoot_") .. id,
        Position = vec3(row.x, row.y + GameCfg.Loot.Height, row.z),
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
      if unit ~= nil then
        EngineRead.destroy_unit(unit, {
          context = "GroundLoot.cleanup:" .. tostring(id),
          logger = env.opts.logger,
        })
      end
      if env.records[id] == row then
        env.records[id] = nil
        for index, value in ipairs(env.order) do
          if value == id then table.remove(env.order, index) break end
        end
      end
      local spot = row.spotId and env.spot_state[row.spotId]
      if spot and spot.loot_id == id then
        spot.loot_id = nil
        spot.respawn_at = math.floor(env.clock.now()) + env.respawn_sec
      end
    end)
  end)
end

-- 每区上限：超出时给最早一行打回收警告，由 on_second 到点回收。
function GroundLootBehavior.flag_overflow(self, zone_id)
  local env = self.ground_loot_env
  if live_zone_count(env, zone_id) <= env.cap then return end
  for _, existing_id in ipairs(env.order) do
    local existing = env.records[existing_id]
    if existing and existing.zoneId == zone_id and existing.recycle_at == nil then
      existing.warn = true
      existing.recycle_at = math.floor(env.clock.now()) + env.flash_sec
      return
    end
  end
end

-- 投放一行战利品：校验、定位、登记、挂效果、压制超量，最后广播。
function GroundLootBehavior.place(self, zone_id, spec)
  local env = self.ground_loot_env
  local count = place_args(spec)
  if count == nil then return nil end
  local zone = zone_of(env.zones, zone_id)
  if zone == nil or zone.ground_loot == nil then return nil end
  local x, y, z = read_pos(spec)
  if x == nil then x, y, z = read_pos(spec.position) end
  if x == nil then return nil end
  local row = GroundLootBehavior.register(self, zone_id, spec, count, x, y, z)
  GroundLootBehavior.mount_row(self, zone, row)
  GroundLootBehavior.flag_overflow(self, zone_id)
  GroundLootBehavior.publish(self)
  return row.id
end

-- 补一个 bait spot：已有行或区域缺失时跳过，成功则记住行号与下次刷新点。
function GroundLootBehavior.spawn_spot(self, spot)
  local env = self.ground_loot_env
  local state = env.spot_state[spot.Id]
  if state == nil or state.loot_id ~= nil then return nil end
  local zone_id = spot.ZoneId
  if zone_id == nil then
    local pos = spot.Position or {}
    zone_id = env.world.zones and nil
    for _, zone in ipairs(env.world.zone_list or {}) do
      if zone_id == nil then zone_id = zone.id end
    end
    if pos.x == nil then return nil end
  end
  if zone_of(env.zones, zone_id) == nil then return nil end
  local pos = spot.Position or { x = 0, y = 0, z = 0 }
  local id = GroundLootBehavior.place(self, zone_id, {
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

-- 初始 bait spot 布点。
function GroundLootBehavior.seed_spots(self)
  local env = self.ground_loot_env
  if env.spots_cfg.Enabled == false then return end
  for _, spot in ipairs(env.spots_cfg.Spots or {}) do
    if type(spot) == "table" and type(spot.Id) == "string" then
      env.spot_state[spot.Id] = { cfg = spot, loot_id = nil, respawn_at = nil }
      GroundLootBehavior.spawn_spot(self, spot)
    end
  end
end

-- 每秒回收到期行，并补刷空着的 bait spot。
function GroundLootBehavior.on_second(self)
  local env = self.ground_loot_env
  local sec = math.floor(env.clock.now())
  local expired = {}
  for _, id in ipairs(env.order) do
    local row = env.records[id]
    if row and row.recycle_at ~= nil and sec >= row.recycle_at then
      expired[#expired + 1] = id
    end
  end
  for _, id in ipairs(expired) do
    local row = env.records[id]
    if row then
      local zone = zone_of(env.zones, row.zoneId)
      if zone and zone.ground_loot then zone.ground_loot:drop(row.key) end
    end
  end
  for _, state in pairs(env.spot_state) do
    if state.loot_id == nil and state.respawn_at ~= nil and sec >= state.respawn_at then
      GroundLootBehavior.spawn_spot(self, state.cfg)
    end
  end
  if #expired > 0 then GroundLootBehavior.publish(self) end
end

-- 远程入口的前置校验：作用域在、世界未销毁、树可操作，且不在频控冷却里。
function GroundLootBehavior.allow_remote(self, player, channel, skip_cd)
  local env = self.ground_loot_env
  local tree = lookup_tree(env, player)
  if not env.remote_active or env.world:is_disposed() or not tree or tree:is_disposed() then return false end
  local remote = env.opts.remote
  if not skip_cd and type(remote) == "table" and type(remote.check_recd) == "function"
      and remote:check_recd(player, channel, GameCfg.Items.ActionCooldownSec) then
    return false
  end
  return true
end

-- 按鱼种掉落表铺开：多份掉落沿 X 轴居中排开。
function GroundLootBehavior.place_drops(self, zone_id, killed, species, placed)
  local origin = killed.position
  local drops = species.Drops
  if type(drops) ~= "table" then
    local id = GroundLootBehavior.place(self, zone_id, {
      kind = "item",
      itemId = killed.fishId,
      count = 1,
      mult = killed.mult,
      fishId = killed.fishId,
      x = origin.x, y = origin.y or 0, z = origin.z,
    })
    if id ~= nil then placed[#placed + 1] = id end
    return
  end
  local total = 0
  for _, drop in ipairs(drops) do total = total + (drop.Count or 0) end
  local index = 0
  for _, drop in ipairs(drops) do
    for _ = 1, drop.Count or 0 do
      index = index + 1
      local id = GroundLootBehavior.place(self, zone_id, {
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
end

function GroundLootHost.place_ground_item(self, zone_id, spec)
  if self:is_disposed() then return false end
  local id = GroundLootBehavior.place(self, zone_id, spec or {})
  return id ~= nil
end

function GroundLootHost.place_delivery(self, key, zone_id, spec)
  local env = self.ground_loot_env
  if type(key) ~= "string" or key == "" then return nil, "bad-key" end
  local prior = env.deliveries[key]
  if prior ~= nil then return prior end
  if self:is_disposed() then return nil, "disposed" end
  local id = GroundLootBehavior.place(self, zone_id, spec or {})
  if id == nil then return nil, "rejected" end
  local receipt = { Id = id }
  env.deliveries[key] = receipt
  return receipt
end

function GroundLootHost.ground_snapshot(self)
  local env = self.ground_loot_env
  local list = {}
  for _, id in ipairs(env.order) do
    local row = env.records[id]
    if row then list[#list + 1] = copy_row(row) end
  end
  return { list = list }
end

function GroundLootHost.handle_item_bar_action(self, player, payload, skip_cd)
  if type(payload) ~= "table" then return false end
  if payload.action ~= "Pickup" and payload.action ~= "Drop" then return false end
  if not GroundLootBehavior.allow_remote(self, player, "ItemBarAction", skip_cd) then return false end
  if payload.action == "Pickup" then
    return self:try_pickup(player, payload.value)
  end
  return self:try_drop(player, payload.container, payload.index)
end

function GroundLootHost.handle_loot_request(self, player, skip_cd)
  local env = self.ground_loot_env
  if not GroundLootBehavior.allow_remote(self, player, "RequestLoot", skip_cd) then return false end
  local remote = remote_of(env)
  if remote == nil then return false end
  local list = {}
  for _, id in ipairs(env.order) do
    local row = env.records[id]
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

function GroundLootHost.try_pickup(self, player, loot_id)
  local env = self.ground_loot_env
  if self:is_disposed() then return false, "disposed" end
  if type(loot_id) ~= "string" and type(loot_id) ~= "number" then return false, "bad" end
  local id = tostring(loot_id)
  local row = env.records[id]
  if row == nil then return false, "missing" end
  local tree = lookup_tree(env, player)
  if not player_can_act(tree) then return false, "cannot-act" end
  if not within_reach(player, { x = row.x, y = row.y, z = row.z }) then return false, "far" end
  if not can_accept(tree, row.itemId, row.kind == "bait" and (row.count or 1) or 1) then
    return false, "full"
  end
  local committed = false
  local function commit()
    local current = env.records[id]
    if current == nil or not player_can_act(tree) then return end
    if not can_accept(tree, current.itemId, current.kind == "bait" and (current.count or 1) or 1) then return end
    if not grant(tree, current) then return end
    local zone = zone_of(env.zones, current.zoneId)
    if zone and zone.ground_loot then zone.ground_loot:drop(current.key) end
    committed = env.records[id] == nil
  end
  SpokeRuntime.batch(commit)
  if committed then
    GroundLootBehavior.publish(self)
    GroundLootBehavior.reply(self, player, { ok = true, action = "Pickup", id = id })
    return true
  end
  GroundLootBehavior.reply(self, player, { ok = false, action = "Pickup", id = id, reason = "rejected" })
  return false, "rejected"
end

function GroundLootHost.on_carrier_killed(self, killed)
  local env = self.ground_loot_env
  if self:is_disposed() or type(killed) ~= "table" or not EngineRead.is_object(killed.position) then return false end
  local species = GameCfg.Fish[killed.fishId]
  if species == nil then return false end
  local zone_id = killed.zoneId
  if zone_of(env.zones, zone_id) == nil then
    zone_id = self.zone_list[1] and self.zone_list[1].id
  end
  if zone_of(env.zones, zone_id) == nil then return false end
  local placed = {}
  SpokeRuntime.batch(function()
    GroundLootBehavior.place_drops(self, zone_id, killed, species, placed)
  end)
  return #placed > 0, placed
end

function GroundLootHost.try_drop(self, player, container, index)
  local env = self.ground_loot_env
  if self:is_disposed() then return false, "disposed" end
  local tree = lookup_tree(env, player)
  if not player_can_act(tree) then return false, "cannot-act" end
  if not Number.is_finite_number(index) or index ~= math.floor(index) or index < 1 then return false, "bad" end
  local source = container == GameCfg.Items.ContainerId.Backpack
    and (tree.states.backpack:now() or {})
    or (tree.states.item_bar:now() or {})
  local entry = source[index]
  if type(entry) ~= "table" or (entry.count or 0) <= 0 then return false, "empty" end
  local ok_pos, pos = EngineRead.read_player_position(player, { context = "GroundLoot.try_drop", logger = env.opts.logger })
  local x, y, z = read_pos(ok_pos and pos or nil)
  if x == nil then return false, "no-character" end
  local zone_id = tree.states.zone_id:now()
  if zone_of(env.zones, zone_id) == nil then
    zone_id = self.zone_list[1] and self.zone_list[1].id
  end
  if zone_of(env.zones, zone_id) == nil then return false, "no-zone" end
  local dropped = false
  local function commit_drop()
    if not player_can_act(tree) then return end
    local taken = take_slot(tree, container, index)
    if taken == nil then return end
    local id = GroundLootBehavior.place(self, zone_id, {
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
  GroundLootBehavior.reply(self, player, { ok = dropped == true, action = "Drop", index = index })
  return dropped
end

--- 组装战利品句柄：状态与依赖集中在 world.ground_loot_env，方法由 GroundLootHost 提供。
--- 对外方法名、参数顺序与返回值沿用拆分前的 world 方法，调用方照旧用 :method(...)。
function GroundLoot.mount(world, opts)
  opts = type(opts) == "table" and opts or {}
  local scope = assert(opts.scope, "GroundLoot 必须由 SharedWorldTree 根作用域持有")
  local spots_cfg = opts.bait_spots or GameCfg.BaitSpots
  local env = {
    world = world,
    opts = opts,
    scope = scope,
    clock = world.clock,
    create_unit = opts.create_unit,
    zones = world.zones or {},
    spots_cfg = spots_cfg,
    cap = GameCfg.Loot.PerZoneCap,
    flash_sec = GameCfg.Loot.FlashBeforeRecycleSec,
    respawn_sec = spots_cfg.RespawnSec or GameCfg.BaitSpots.RespawnSec,
    records = {},
    order = {},
    spot_state = {},
    next_id = 0,
    broadcasting = false,
    deliveries = {},
    remote_active = false,
  }
  world.ground_loot_env = env
  for name, method in pairs(GroundLootHost) do
    world[name] = method
  end
  GroundLootBehavior.seed_spots(world)
  scope:effect("GroundLootClock", function(es)
    es:subscribe(env.clock.on_second, function() GroundLootBehavior.on_second(world) end)
  end)
  scope:effect("GroundLootRemote", function(es)
    env.remote_active = true
    es:on_cleanup(function()
      env.remote_active = false
    end)
  end)
  return world
end

return GroundLoot
