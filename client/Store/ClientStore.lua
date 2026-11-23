-- 客户端只读响应式状态仓库（ADR-0032 / #296，归属 L3 client.Store）：
-- 外围宿主入口持有 writer，将服务端下行 RemoteEvent 与本地角色位置/钓鱼区传感器归一化写入纯 Spoke State/Trigger；
-- 视图层与旧界面仅持有只读 store，只能通过 s:d / s:subscribe 订阅，无法反向修改仓库内部写入入口。

local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local SpokeClock = require("common.SpokeClock")
local GameCfg = require("common.GameCfg")
local Number = require("common.Number")
local ZoneMarkers = require("common.ZoneMarkers")

local State = spoke.State
local Trigger = spoke.Trigger

local ClientStore = {}

local VALID_SURVIVAL_PHASES = {
  alive = true,
  downed = true,
  rescuing = true,
  dead = true,
}

local DEFAULT_CHANNELS = {
  -- 服务端状态快照频道
  "ItemBarState",
  "SurvivalState",
  "PartyState",
  "CastState",
  "SpecialItemState",
  "FishCombatState",
  "LootState",
  "QuestState",
  "StoryState",
  "FerryState",
  "GrillState",
  "CompendiumState",
  "RecordsState",
  -- 离散回执与通知频道
  "ItemBarResult",
  "SurvivalResult",
  "PartyResult",
  "SpecialItemResult",
  "WeaponResult",
  "LootResult",
  "InteractResult",
  "ShopResult",
  "FerryResult",
  "GrillResult",
  "LotteryResult",
  "BlindboxResult",
  "PlatformResult",
  "GMResult",
  "DamageNotice",
  "StoryNotice",
  "ReelInRE",
  "CloseReelIn",
  "OpenScreenRE",
  "CloseScreenRE",
}

local function clone_value(value, depth)
  if type(value) ~= "table" then
    return value
  end
  if depth > 8 then
    return nil
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = clone_value(v, depth + 1)
  end
  return copy
end

local function freeze_table(fields, label)
  return setmetatable({}, {
    __index = fields,
    __newindex = function(_, key)
      error(label .. " 为只读对象，禁止写入字段: " .. tostring(key), 2)
    end,
    __pairs = function()
      return pairs(fields)
    end,
    __metatable = false,
  })
end

local function readonly_signal(state, label)
  return freeze_table({
    now = function()
      return state:now()
    end,
    subscribe = function(_, fn)
      return state:subscribe(fn)
    end,
    unsubscribe = function(_, fn)
      state:unsubscribe(fn)
    end,
  }, label or "ReadOnlySignal")
end

local function readonly_trigger(trigger, label)
  return freeze_table({
    subscribe = function(_, fn)
      return trigger:subscribe(fn)
    end,
    unsubscribe = function(_, fn)
      trigger:unsubscribe(fn)
    end,
  }, label or "ReadOnlyTrigger")
end

local function readonly_clock(clock)
  return freeze_table({
    second = readonly_signal(clock.second, "ClientStore.clock.second"),
    on_second = readonly_trigger(clock.on_second, "ClientStore.clock.on_second"),
    on_frame = readonly_trigger(clock.on_frame, "ClientStore.clock.on_frame"),
    now = clock.now,
  }, "ClientStore.clock")
end

local function position_equals(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  return a.x == b.x and a.y == b.y and a.z == b.z
end

local function sanitize_position(pos)
  if pos == nil then
    return nil, true
  end
  if type(pos) ~= "table" and type(pos) ~= "userdata" then
    return nil, false
  end
  local ok, x, y, z = pcall(function()
    return pos.x, pos.y, pos.z
  end)
  if not ok then
    return nil, false
  end
  if not Number.IsFiniteNumber(x) or not Number.IsFiniteNumber(y) or not Number.IsFiniteNumber(z) then
    return nil, false
  end
  return { x = x, y = y, z = z }, true
end

local function resolve_zone(pos, zones)
  if pos == nil or type(zones) ~= "table" then
    return nil, nil
  end
  for _, zone in ipairs(GameCfg.Zones) do
    local scene = zones[zone.Id]
    local bounds = scene and scene.Boundary
    if type(bounds) == "table"
        and Number.IsFiniteNumber(bounds.MinX) and Number.IsFiniteNumber(bounds.MaxX)
        and Number.IsFiniteNumber(bounds.MinZ) and Number.IsFiniteNumber(bounds.MaxZ) then
      if pos.x >= bounds.MinX and pos.x <= bounds.MaxX
          and pos.z >= bounds.MinZ and pos.z <= bounds.MaxZ then
        return zone.Id, zone.Name
      end
    end
  end
  return nil, nil
end

local function normalize_survival(payload)
  if type(payload) ~= "table" then
    return nil
  end
  local phase = payload.phase
  if type(phase) ~= "string" or not VALID_SURVIVAL_PHASES[phase] then
    return nil
  end
  return {
    phase = phase,
    endsAt = Number.IsFiniteNumber(payload.endsAt) and payload.endsAt or nil,
    weakUntil = Number.IsFiniteNumber(payload.weakUntil) and payload.weakUntil or nil,
    platformPending = payload.platformPending and true or nil,
  }
end

local function normalize_party(payload)
  if type(payload) ~= "table" then
    return nil
  end
  if payload.state ~= "none" and payload.state ~= "party" then
    return nil
  end
  if type(payload.members) ~= "table" then
    return nil
  end
  local members = {}
  for i, member in ipairs(payload.members) do
    if type(member) ~= "table"
        or not Number.IsFiniteNumber(member.userId)
        or type(member.name) ~= "string" then
      return nil
    end
    if member.health ~= nil and not Number.IsFiniteNumber(member.health) then
      return nil
    end
    if member.maxHealth ~= nil and not Number.IsFiniteNumber(member.maxHealth) then
      return nil
    end
    members[i] = {
      userId = member.userId,
      name = member.name,
      health = member.health,
      maxHealth = member.maxHealth,
      self = member.self == true or nil,
    }
  end
  if payload.state == "party" and (not Number.IsFiniteNumber(payload.partyId) or #members < 1) then
    return nil
  end
  local invite = nil
  if payload.invite ~= nil then
    if type(payload.invite) ~= "table"
        or not Number.IsFiniteNumber(payload.invite.fromUserId)
        or not Number.IsFiniteNumber(payload.invite.expiresInSec)
        or payload.invite.expiresInSec < 0 then
      return nil
    end
    invite = {
      fromUserId = payload.invite.fromUserId,
      fromName = type(payload.invite.fromName) == "string" and payload.invite.fromName or nil,
      expiresInSec = payload.invite.expiresInSec,
    }
  end
  return {
    state = payload.state,
    partyId = payload.partyId,
    members = members,
    invite = invite,
    notice = type(payload.notice) == "string" and payload.notice or nil,
  }
end

local function normalize_table_snapshot(payload)
  if type(payload) ~= "table" then
    return nil
  end
  return clone_value(payload, 0)
end

local function default_host()
  local REUtil = require("common.REUtil")
  local Players = game:GetService("Players")
  local RunService = game:GetService("RunService")
  local World = game:GetService("World")
  return {
    get_re = function(name)
      return REUtil:GetRE(name)
    end,
    heartbeat = RunService.Heartbeat,
    get_server_time = function()
      local ok, now = pcall(function()
        return World:GetServerTime()
      end)
      return ok and now or nil
    end,
    get_local_position = function()
      local ok, pos = pcall(function()
        local player = Players.LocalPlayer
        local character = player and player.Character
        return character and character.Position or nil
      end)
      return ok and pos or nil
    end,
    get_zones = function()
      return ZoneMarkers.Zones
    end,
  }
end

function ClientStore.default_channels()
  local copy = {}
  for i = 1, #DEFAULT_CHANNELS do
    copy[i] = DEFAULT_CHANNELS[i]
  end
  return copy
end

---@param options table|nil { clock?: table, initial_now?: number }
---@return table store 只读响应式状态面
---@return table writer 写侧句柄（仅 L1 宿主入口持有）
function ClientStore.new(options)
  options = options or {}
  local clock = options.clock or SpokeClock.new(options.initial_now)

  local states = {
    connected = State.new("ClientStore.connected", false),
    item_bar = State.new("ClientStore.item_bar", nil),
    survival = State.new("ClientStore.survival", { phase = "alive" }),
    party = State.new("ClientStore.party", { state = "none", members = {} }),
    cast = State.new("ClientStore.cast", nil),
    special_item = State.new("ClientStore.special_item", nil),
    fish_combat = State.new("ClientStore.fish_combat", nil),
    loot = State.new("ClientStore.loot", {}),
    quest = State.new("ClientStore.quest", nil),
    story = State.new("ClientStore.story", nil),
    ferry = State.new("ClientStore.ferry", nil),
    grill = State.new("ClientStore.grill", nil),
    compendium = State.new("ClientStore.compendium", nil),
    records = State.new("ClientStore.records", nil),
    position = State.new("ClientStore.position", nil, position_equals),
    zone_id = State.new("ClientStore.zone_id", nil),
    zone_name = State.new("ClientStore.zone_name", nil),
    active_modal = State.new("ClientStore.active_modal", nil),
    modal_payload = State.new("ClientStore.modal_payload", nil),
    overlays = State.new("ClientStore.overlays", {}),
  }

  local on_server_event = Trigger.new("ClientStore.on_server_event")
  local on_reconnect = Trigger.new("ClientStore.on_reconnect")

  local snapshot_handlers = {
    ItemBarState = { state = states.item_bar, normalize = normalize_table_snapshot },
    SurvivalState = { state = states.survival, normalize = normalize_survival },
    PartyState = { state = states.party, normalize = normalize_party },
    CastState = { state = states.cast, normalize = normalize_table_snapshot },
    SpecialItemState = { state = states.special_item, normalize = normalize_table_snapshot },
    FishCombatState = { state = states.fish_combat, normalize = normalize_table_snapshot },
    LootState = { state = states.loot, normalize = normalize_table_snapshot },
    QuestState = { state = states.quest, normalize = normalize_table_snapshot },
    StoryState = { state = states.story, normalize = normalize_table_snapshot },
    FerryState = { state = states.ferry, normalize = normalize_table_snapshot },
    GrillState = { state = states.grill, normalize = normalize_table_snapshot },
    CompendiumState = { state = states.compendium, normalize = normalize_table_snapshot },
    RecordsState = { state = states.records, normalize = normalize_table_snapshot },
  }

  local store = freeze_table({
    clock = readonly_clock(clock),
    connected = readonly_signal(states.connected, "ClientStore.connected"),
    item_bar = readonly_signal(states.item_bar, "ClientStore.item_bar"),
    survival = readonly_signal(states.survival, "ClientStore.survival"),
    party = readonly_signal(states.party, "ClientStore.party"),
    cast = readonly_signal(states.cast, "ClientStore.cast"),
    special_item = readonly_signal(states.special_item, "ClientStore.special_item"),
    fish_combat = readonly_signal(states.fish_combat, "ClientStore.fish_combat"),
    loot = readonly_signal(states.loot, "ClientStore.loot"),
    quest = readonly_signal(states.quest, "ClientStore.quest"),
    story = readonly_signal(states.story, "ClientStore.story"),
    ferry = readonly_signal(states.ferry, "ClientStore.ferry"),
    grill = readonly_signal(states.grill, "ClientStore.grill"),
    compendium = readonly_signal(states.compendium, "ClientStore.compendium"),
    records = readonly_signal(states.records, "ClientStore.records"),
    position = readonly_signal(states.position, "ClientStore.position"),
    zone_id = readonly_signal(states.zone_id, "ClientStore.zone_id"),
    zone_name = readonly_signal(states.zone_name, "ClientStore.zone_name"),
    active_modal = readonly_signal(states.active_modal, "ClientStore.active_modal"),
    modal_payload = readonly_signal(states.modal_payload, "ClientStore.modal_payload"),
    overlays = readonly_signal(states.overlays, "ClientStore.overlays"),
    on_server_event = readonly_trigger(on_server_event, "ClientStore.on_server_event"),
    on_reconnect = readonly_trigger(on_reconnect, "ClientStore.on_reconnect"),
  }, "ClientStore")

  local writer = {}
  local active_binding = nil

  function writer:set_connected(flag)
    states.connected:set(flag == true)
  end

  function writer:step_clock(dt, now)
    local safe_dt = (Number.IsFiniteNumber(dt) and dt >= 0) and dt or 0
    local safe_now = Number.IsFiniteNumber(now) and now or nil
    clock:step(safe_dt, safe_now)
  end

  function writer:advance_clock(seconds)
    clock:advance(seconds)
  end

  function writer:ingest_event(channel, payload)
    if type(channel) ~= "string" or channel == "" then
      return false
    end
    local entry = snapshot_handlers[channel]
    if entry ~= nil then
      local normalized = entry.normalize(payload)
      if normalized == nil then
        return false
      end
      SpokeRuntime.batch(function()
        states.connected:set(true)
        entry.state:set(normalized)
        on_server_event:invoke({ channel = channel, payload = normalized })
      end)
      return true
    end

    local cloned = clone_value(payload, 0)
    SpokeRuntime.batch(function()
      states.connected:set(true)
      on_server_event:invoke({ channel = channel, payload = cloned })
    end)
    return true
  end

  function writer:update_spatial(position, zones)
    local clean_pos, valid = sanitize_position(position)
    if not valid then
      return false
    end
    local zone_id, zone_name = resolve_zone(clean_pos, zones)
    SpokeRuntime.batch(function()
      states.position:set(clean_pos)
      states.zone_id:set(zone_id)
      states.zone_name:set(zone_name)
    end)
    return true
  end

  function writer:open_modal(modal_id, payload)
    if type(modal_id) ~= "string" or modal_id == "" then
      error("ClientStore writer:open_modal 需要非空字符串 modal_id", 2)
    end
    local cloned = clone_value(payload, 0)
    SpokeRuntime.batch(function()
      states.active_modal:set(modal_id)
      states.modal_payload:set(cloned)
    end)
  end

  function writer:close_modal(expected_id)
    if expected_id ~= nil and states.active_modal:now() ~= expected_id then
      return
    end
    SpokeRuntime.batch(function()
      states.active_modal:set(nil)
      states.modal_payload:set(nil)
    end)
  end

  function writer:set_overlay(overlay_id, active)
    if type(overlay_id) ~= "string" or overlay_id == "" then
      error("ClientStore writer:set_overlay 需要非空字符串 overlay_id", 2)
    end
    local flag = active == true
    local current = states.overlays:now()
    if (current[overlay_id] == true) == flag then
      return
    end
    local next_overlays = {}
    for k, v in pairs(current) do
      if v == true then
        next_overlays[k] = true
      end
    end
    next_overlays[overlay_id] = flag and true or nil
    states.overlays:set(next_overlays)
  end

  function writer:reset_session(reason)
    SpokeRuntime.batch(function()
      states.connected:set(false)
      states.item_bar:set(nil)
      states.survival:set({ phase = "alive" })
      states.party:set({ state = "none", members = {} })
      states.cast:set(nil)
      states.special_item:set(nil)
      states.fish_combat:set(nil)
      states.loot:set({})
      states.quest:set(nil)
      states.story:set(nil)
      states.ferry:set(nil)
      states.grill:set(nil)
      states.compendium:set(nil)
      states.records:set(nil)
      states.position:set(nil)
      states.zone_id:set(nil)
      states.zone_name:set(nil)
      states.active_modal:set(nil)
      states.modal_payload:set(nil)
      states.overlays:set({})
      on_reconnect:invoke({ reason = reason or "reset" })
    end)
  end

  function writer:unbind_host()
    if active_binding ~= nil then
      local current = active_binding
      active_binding = nil
      current:dispose()
    end
  end

  function writer:bind_host(host)
    self:unbind_host()
    local resolved = host or default_host()
    local channels = resolved.channels or DEFAULT_CHANNELS
    local connections = {}
    local disposed = false

    local get_re = resolved.get_re
    if type(get_re) == "function" then
      for _, channel in ipairs(channels) do
        local re = get_re(channel)
        local signal = re and re.OnClientEvent
        if signal and type(signal.Connect) == "function" then
          local channel_name = channel
          local conn = signal:Connect(function(payload)
            if disposed then
              return
            end
            self:ingest_event(channel_name, payload)
          end)
          connections[#connections + 1] = conn
        end
      end
    end

    local heartbeat = resolved.heartbeat
    if heartbeat and type(heartbeat.Connect) == "function" then
      local get_server_time = resolved.get_server_time
      local get_local_position = resolved.get_local_position
      local get_zones = resolved.get_zones
      local hb_conn = heartbeat:Connect(function(dt)
        if disposed then
          return
        end
        local now = type(get_server_time) == "function" and get_server_time() or nil
        SpokeRuntime.batch(function()
          self:step_clock(dt, now)
          if type(get_local_position) == "function" then
            local pos = get_local_position()
            local zones = type(get_zones) == "function" and get_zones() or nil
            self:update_spatial(pos, zones)
          end
        end)
      end)
      connections[#connections + 1] = hb_conn
    end

    local binding = {}
    function binding:dispose()
      if disposed then
        return
      end
      disposed = true
      if active_binding == self then
        active_binding = nil
      end
      for i = #connections, 1, -1 do
        local conn = connections[i]
        connections[i] = nil
        if conn and type(conn.Disconnect) == "function" then
          conn:Disconnect()
        end
      end
    end

    active_binding = binding
    return binding
  end

  return store, writer
end

return ClientStore
