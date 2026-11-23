-- 客户端只读响应式状态仓库（ADR-0032 / #296，归属 L3 client.Store）：
-- 外围宿主入口持有 writer，将服务端下行 RemoteEvent 与本地角色位置/钓鱼区传感器归一化写入纯 Spoke State/Trigger；
-- 视图层与旧界面仅持有只读 store，只能通过 s:d / s:subscribe 订阅，无法反向修改仓库内部写入入口。

local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local SpokeClock = require("common.SpokeClock")
local BodyScale = require("common.BodyScale")
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

local function freeze_snapshot(value, depth, label)
  if type(value) ~= "table" then
    return value
  end
  if depth > 8 then
    return nil
  end
  local copy = {}
  for k, v in pairs(value) do
    copy[k] = freeze_snapshot(v, depth + 1, label)
  end
  return setmetatable({}, {
    __index = copy,
    __newindex = function(_, key)
      error((label or "ClientStore.Snapshot") .. " 为只读快照，禁止修改字段: " .. tostring(key), 2)
    end,
    __pairs = function()
      return pairs(copy)
    end,
    __len = function()
      return #copy
    end,
    __metatable = false,
  })
end

local function clone_value(value, depth)
  return freeze_snapshot(value, depth or 0, "ClientStore.Snapshot")
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

local function vitals_equals(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  return a.health == b.health
    and a.maxHealth == b.maxHealth
    and a.hunger == b.hunger
    and a.maxHunger == b.maxHunger
end

local function default_vitals()
  local c = GameCfg.Vitals
  return freeze_snapshot({
    health = c.MaxHealth,
    maxHealth = c.MaxHealth,
    hunger = c.MaxHunger,
    maxHunger = c.MaxHunger,
  }, 0, "ClientStore.vitals")
end

local function sanitize_vital_field(raw, fallback)
  if Number.IsFiniteNumber(raw) then
    return math.floor(raw)
  end
  return fallback
end

local function normalize_camera_distance(raw)
  if not Number.IsFiniteNumber(raw) or raw <= 0 then
    return nil
  end
  local base = GameCfg.Ability.BodyScale.CameraDistance
  if not Number.IsFiniteNumber(base) or base <= 0 then
    return nil
  end
  return BodyScale.Derive(BodyScale.Sanitize(raw / base)).CameraDistance
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
  return freeze_snapshot({ x = x, y = y, z = z }, 0, "ClientStore.position"), true
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
  return freeze_snapshot({
    phase = phase,
    endsAt = Number.IsFiniteNumber(payload.endsAt) and payload.endsAt or nil,
    weakUntil = Number.IsFiniteNumber(payload.weakUntil) and payload.weakUntil or nil,
    platformPending = payload.platformPending and true or nil,
  }, 0, "ClientStore.survival")
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
  return freeze_snapshot({
    state = payload.state,
    partyId = payload.partyId,
    members = members,
    invite = invite,
    notice = type(payload.notice) == "string" and payload.notice or nil,
  }, 0, "ClientStore.party")
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
      local ok, now = pcall(function() return World:GetServerTime() end) -- 宿主时钟未就绪或异常时安全降级为 dt 步进
      return ok and now or nil
    end,
    get_local_player = function()
      return Players.LocalPlayer
    end,
    get_local_character = function()
      local ok, character = pcall(function() -- 角色销毁/切换瞬态读取 Character 可能抛错，安全忽略等待下一帧
        local player = Players.LocalPlayer
        return player and player.Character or nil
      end)
      return ok and character or nil
    end,
    get_local_position = function()
      local ok, pos = pcall(function() -- 角色销毁/切换瞬态读取 Position 可能抛错，安全忽略等待下一帧
        local player = Players.LocalPlayer
        local character = player and player.Character
        return character and character.Position or nil
      end)
      return ok and pos or nil
    end,
    read_player_attr = function(player, key)
      if player == nil then return nil end
      local ok, val = pcall(function() return player:GetAttribute(key) end) -- 宿主玩家属性读取异常时安全回退
      return ok and val or nil
    end,
    read_char_attr = function(character, key)
      if character == nil then return nil end
      local ok, val = pcall(function() return character:GetAttribute(key) end) -- 角色销毁瞬态读取属性可能抛错，安全回退
      return ok and val or nil
    end,
    get_player_attr_signal = function(player, key)
      if player == nil then return nil end
      local ok, sig = pcall(function() return player:GetAttributeChangedSignal(key) end) -- 兼容未实现属性信号的环境
      return ok and sig or nil
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
    survival = State.new("ClientStore.survival", freeze_snapshot({ phase = "alive" }, 0, "ClientStore.survival")),
    party = State.new("ClientStore.party", freeze_snapshot({ state = "none", members = {} }, 0, "ClientStore.party")),
    cast = State.new("ClientStore.cast", nil),
    special_item = State.new("ClientStore.special_item", nil),
    fish_combat = State.new("ClientStore.fish_combat", nil),
    loot = State.new("ClientStore.loot", freeze_snapshot({}, 0, "ClientStore.loot")),
    quest = State.new("ClientStore.quest", nil),
    story = State.new("ClientStore.story", nil),
    ferry = State.new("ClientStore.ferry", nil),
    grill = State.new("ClientStore.grill", nil),
    lottery_result = State.new("ClientStore.lottery_result", nil),
    blindbox_result = State.new("ClientStore.blindbox_result", nil),
    platform_result = State.new("ClientStore.platform_result", nil),
    compendium = State.new("ClientStore.compendium", nil),
    records = State.new("ClientStore.records", nil),
    message = State.new("ClientStore.message", nil),
    gm_result = State.new("ClientStore.gm_result", nil),
    position = State.new("ClientStore.position", nil, position_equals),
    zone_id = State.new("ClientStore.zone_id", nil),
    zone_name = State.new("ClientStore.zone_name", nil),
    vitals = State.new("ClientStore.vitals", default_vitals(), vitals_equals),
    coin = State.new("ClientStore.coin", 0),
    shop = State.new("ClientStore.shop", freeze_snapshot({
      purchases = {}, upgradeLevels = {}, upgradeLevel = 0,
    }, 0, "ClientStore.shop")),
    local_character = State.new("ClientStore.local_character", nil),
    camera_distance = State.new("ClientStore.camera_distance", nil),
    hud_visible = State.new("ClientStore.hud_visible", true),
    active_modal = State.new("ClientStore.active_modal", nil),
    modal_payload = State.new("ClientStore.modal_payload", nil),
    overlays = State.new("ClientStore.overlays", freeze_snapshot({}, 0, "ClientStore.overlays")),
  }

  local on_server_event = Trigger.new("ClientStore.on_server_event")
  local on_reconnect = Trigger.new("ClientStore.on_reconnect")

  local function normalize_compendium(payload)
    if type(payload) ~= "table" then return nil end
    for _, key in ipairs({ "unlocked", "weights", "catches" }) do
      if payload[key] ~= nil and type(payload[key]) ~= "table" then return nil end
    end
    if payload.total ~= nil and not Number.IsFiniteNumber(payload.total) then return nil end
    return normalize_table_snapshot(payload)
  end

  local function normalize_records(payload)
    if type(payload) ~= "table" or type(payload.fishId) ~= "string" or payload.fishId == "" then return nil end
    return normalize_table_snapshot(payload)
  end

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
    LotteryResult = { state = states.lottery_result, normalize = normalize_table_snapshot },
    BlindboxResult = { state = states.blindbox_result, normalize = normalize_table_snapshot },
    PlatformResult = { state = states.platform_result, normalize = normalize_table_snapshot },
    CompendiumState = { state = states.compendium, normalize = normalize_compendium },
    RecordsState = { state = states.records, normalize = normalize_records },
    GMResult = { state = states.gm_result, normalize = normalize_table_snapshot },
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
    lottery_result = readonly_signal(states.lottery_result, "ClientStore.lottery_result"),
    blindbox_result = readonly_signal(states.blindbox_result, "ClientStore.blindbox_result"),
    platform_result = readonly_signal(states.platform_result, "ClientStore.platform_result"),
    compendium = readonly_signal(states.compendium, "ClientStore.compendium"),
    records = readonly_signal(states.records, "ClientStore.records"),
    message = readonly_signal(states.message, "ClientStore.message"),
    gm_result = readonly_signal(states.gm_result, "ClientStore.gm_result"),
    position = readonly_signal(states.position, "ClientStore.position"),
    zone_id = readonly_signal(states.zone_id, "ClientStore.zone_id"),
    zone_name = readonly_signal(states.zone_name, "ClientStore.zone_name"),
    vitals = readonly_signal(states.vitals, "ClientStore.vitals"),
    coin = readonly_signal(states.coin, "ClientStore.coin"),
    shop = readonly_signal(states.shop, "ClientStore.shop"),
    local_character = readonly_signal(states.local_character, "ClientStore.local_character"),
    camera_distance = readonly_signal(states.camera_distance, "ClientStore.camera_distance"),
    hud_visible = readonly_signal(states.hud_visible, "ClientStore.hud_visible"),
    active_modal = readonly_signal(states.active_modal, "ClientStore.active_modal"),
    modal_payload = readonly_signal(states.modal_payload, "ClientStore.modal_payload"),
    overlays = readonly_signal(states.overlays, "ClientStore.overlays"),
    on_server_event = readonly_trigger(on_server_event, "ClientStore.on_server_event"),
    on_reconnect = readonly_trigger(on_reconnect, "ClientStore.on_reconnect"),
  }, "ClientStore")

  local writer = {}
  local active_binding = nil
  local snapshot_seq = {}

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
      if (channel == "CompendiumState" or channel == "RecordsState") and type(payload) == "table"
        and Number.IsFiniteNumber(payload.seq) and Number.IsFiniteNumber(snapshot_seq[channel])
        and payload.seq <= snapshot_seq[channel] then return false end
      local normalized = entry.normalize(payload)
      if normalized == nil then
        return false
      end
      if type(payload) == "table" and Number.IsFiniteNumber(payload.seq) then snapshot_seq[channel] = payload.seq end
      SpokeRuntime.batch(function()
        states.connected:set(true)
        entry.state:set(normalized)
        if channel == "QuestState" and type(normalized.notice) == "string" and normalized.notice ~= "" then
          states.message:set(freeze_snapshot({ text = normalized.notice }, 0, "ClientStore.message"))
        end
        if channel == "StoryState" and normalized.read == true and states.active_modal:now() == "story" then
          local current = states.modal_payload:now()
          if type(current) ~= "table" or current.readKey == nil or current.readKey == normalized.readKey then
            states.active_modal:set(nil)
            states.modal_payload:set(nil)
          end
        end
        if channel == "ItemBarState" and Number.IsFiniteNumber(payload.coin) then
          states.coin:set(math.floor(payload.coin))
        end
        on_server_event:invoke({ channel = channel, payload = normalized })
      end)
      return true
    end

    local cloned = clone_value(payload, 0)
    SpokeRuntime.batch(function()
      states.connected:set(true)
      if channel == "StoryNotice" and type(cloned) == "table" then
        local story = freeze_snapshot(cloned, 0, "ClientStore.story")
        states.story:set(story)
        states.active_modal:set("story")
        states.modal_payload:set(story)
      end
      if channel == "ShopResult" and type(payload) == "table" then
        local previous = states.shop:now()
        local purchases, upgrade_levels = {}, {}
        for key, value in pairs(previous.purchases or {}) do purchases[key] = value end
        for key, value in pairs(previous.upgradeLevels or {}) do upgrade_levels[key] = value end
        local upgrade_level = previous.upgradeLevel or 0
        if payload.ok then
          if payload.number then purchases[payload.number] = (purchases[payload.number] or 0) + 1 end
          if payload.kind and payload.level then
            upgrade_levels[payload.kind] = math.max(upgrade_levels[payload.kind] or 0, payload.level)
          end
          if payload.action == "UpgradeStorage" and payload.level then upgrade_level = payload.level end
        end
        states.shop:set(freeze_snapshot({
          purchases = purchases, upgradeLevels = upgrade_levels, upgradeLevel = upgrade_level,
        }, 0, "ClientStore.shop"))
        if Number.IsFiniteNumber(payload.coinAfter) then states.coin:set(math.floor(payload.coinAfter)) end
      end
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

  function writer:set_coin(value)
    if not Number.IsFiniteNumber(value) then
      return false
    end
    states.coin:set(math.floor(value))
    return true
  end

  function writer:update_vitals(input)
    if type(input) ~= "table" then
      return false
    end
    local cur = states.vitals:now()
    local next_vitals = freeze_snapshot({
      health = sanitize_vital_field(input.health, cur.health),
      maxHealth = sanitize_vital_field(input.maxHealth, cur.maxHealth),
      hunger = sanitize_vital_field(input.hunger, cur.hunger),
      maxHunger = sanitize_vital_field(input.maxHunger, cur.maxHunger),
    }, 0, "ClientStore.vitals")
    SpokeRuntime.batch(function()
      states.vitals:set(next_vitals)
      if Number.IsFiniteNumber(input.coin) then
        states.coin:set(math.floor(input.coin))
      end
    end)
    return true
  end

  function writer:update_camera_target(character, raw_distance)
    local normalized = character ~= nil and normalize_camera_distance(raw_distance) or nil
    SpokeRuntime.batch(function()
      states.local_character:set(character)
      states.camera_distance:set(normalized)
    end)
    return true
  end

  function writer:set_hud_visible(flag)
    states.hud_visible:set(flag == true)
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

  function writer:show_notice(text)
    local value = text == nil and "" or tostring(text)
    states.message:set(freeze_snapshot({ text = value }, 0, "ClientStore.message"))
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
    states.overlays:set(freeze_snapshot(next_overlays, 0, "ClientStore.overlays"))
  end

  function writer:reset_session(reason)
    SpokeRuntime.batch(function()
      states.connected:set(false)
      snapshot_seq = {}
      states.item_bar:set(nil)
      states.survival:set(freeze_snapshot({ phase = "alive" }, 0, "ClientStore.survival"))
      states.party:set(freeze_snapshot({ state = "none", members = {} }, 0, "ClientStore.party"))
      states.cast:set(nil)
      states.special_item:set(nil)
      states.fish_combat:set(nil)
      states.loot:set(freeze_snapshot({}, 0, "ClientStore.loot"))
      states.quest:set(nil)
      states.story:set(nil)
      states.ferry:set(nil)
      states.grill:set(nil)
      states.lottery_result:set(nil)
      states.blindbox_result:set(nil)
      states.platform_result:set(nil)
      states.compendium:set(nil)
      states.records:set(nil)
      states.position:set(nil)
      states.zone_id:set(nil)
      states.zone_name:set(nil)
      states.vitals:set(default_vitals())
      states.coin:set(0)
      states.local_character:set(nil)
      states.camera_distance:set(nil)
      states.hud_visible:set(true)
      states.active_modal:set(nil)
      states.modal_payload:set(nil)
      states.compendium:set(nil)
      states.records:set(nil)
      states.quest:set(nil)
      states.story:set(nil)
      states.message:set(nil)
      states.gm_result:set(nil)
      states.overlays:set(freeze_snapshot({}, 0, "ClientStore.overlays"))
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

    local player_attr_conns = {}
    local bound_player = nil

    local function clear_player_attr_conns()
      for i = #player_attr_conns, 1, -1 do
        local conn = player_attr_conns[i]
        player_attr_conns[i] = nil
        if conn and type(conn.Disconnect) == "function" then
          conn:Disconnect()
        end
      end
      bound_player = nil
    end

    local read_player_attr = resolved.read_player_attr
    local get_player_attr_signal = resolved.get_player_attr_signal

    local function sync_player_vitals(player, include_coin)
      if player == nil or type(read_player_attr) ~= "function" then
        return
      end
      local c = GameCfg.Vitals
      local raw_health = tonumber(read_player_attr(player, "Health"))
      local raw_max_health = tonumber(read_player_attr(player, "MaxHealth"))
      local raw_hunger = tonumber(read_player_attr(player, "Hunger"))
      local raw_max_hunger = tonumber(read_player_attr(player, "MaxHunger"))
      local raw_coin = include_coin and tonumber(read_player_attr(player, "FishCoin")) or nil
      self:update_vitals({
        health = Number.IsFiniteNumber(raw_health) and raw_health or c.MaxHealth,
        maxHealth = Number.IsFiniteNumber(raw_max_health) and raw_max_health or c.MaxHealth,
        hunger = Number.IsFiniteNumber(raw_hunger) and raw_hunger or c.MaxHunger,
        maxHunger = Number.IsFiniteNumber(raw_max_hunger) and raw_max_hunger or c.MaxHunger,
        coin = Number.IsFiniteNumber(raw_coin) and raw_coin or nil,
      })
    end

    local function ensure_player_bound(player)
      if player == bound_player then
        return
      end
      clear_player_attr_conns()
      if player == nil then
        return
      end
      bound_player = player
      if type(get_player_attr_signal) == "function" then
        local coin_sig = get_player_attr_signal(player, "FishCoin")
        if coin_sig and type(coin_sig.Connect) == "function" then
          local conn = coin_sig:Connect(function()
            if disposed or bound_player ~= player then
              return
            end
            local raw = type(read_player_attr) == "function" and tonumber(read_player_attr(player, "FishCoin")) or nil
            if Number.IsFiniteNumber(raw) then
              self:set_coin(raw)
            end
          end)
          player_attr_conns[#player_attr_conns + 1] = conn
        end
        for _, key in ipairs({ "Health", "MaxHealth", "Hunger", "MaxHunger" }) do
          local sig = get_player_attr_signal(player, key)
          if sig and type(sig.Connect) == "function" then
            local conn = sig:Connect(function()
              if disposed or bound_player ~= player then
                return
              end
              sync_player_vitals(player, false)
            end)
            player_attr_conns[#player_attr_conns + 1] = conn
          end
        end
      end
      sync_player_vitals(player, true)
    end

    local get_local_player = resolved.get_local_player
    if type(get_local_player) == "function" then
      ensure_player_bound(get_local_player())
    end

    local heartbeat = resolved.heartbeat
    if heartbeat and type(heartbeat.Connect) == "function" then
      local get_server_time = resolved.get_server_time
      local get_local_position = resolved.get_local_position
      local get_local_character = resolved.get_local_character
      local read_char_attr = resolved.read_char_attr
      local get_zones = resolved.get_zones
      local hb_conn = heartbeat:Connect(function(dt)
        if disposed then
          return
        end
        if type(get_local_player) == "function" then
          ensure_player_bound(get_local_player())
        end
        local now = type(get_server_time) == "function" and get_server_time() or nil
        -- 先独立步进时钟（保留跨多秒时 SpokeClock 逐秒 batch 排空语义），再原子更新空间与相机传感状态
        self:step_clock(dt, now)
        SpokeRuntime.batch(function()
          if type(get_local_position) == "function" then
            local pos = get_local_position()
            local zones = type(get_zones) == "function" and get_zones() or nil
            self:update_spatial(pos, zones)
          end
          if type(get_local_character) == "function" then
            local character = get_local_character()
            local raw_dist = (character ~= nil and type(read_char_attr) == "function")
              and read_char_attr(character, "CameraDistance") or nil
            self:update_camera_target(character, raw_dist)
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
      clear_player_attr_conns()
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
