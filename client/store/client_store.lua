-- 客户端只读响应式状态仓库（ADR-0032 / #296，归属 L3 client.store）：
-- 外围宿主入口持有 writer，将服务端下行 RemoteEvent 与本地角色位置/钓鱼区传感器归一化写入纯 Spoke State/Trigger；
-- 视图层与旧界面仅持有只读 store，只能通过 s:d / s:subscribe 订阅，无法反向修改仓库内部写入入口。

local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local SpokeClock = require("common.spoke_clock")
local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local ZoneMarkers = require("common.zone_markers")
local EngineRead = require("common.engine_read")

local State = Spoke.State
local Trigger = Spoke.Trigger

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
  local ta, tb = type(a), type(b)
  if (ta ~= "table" and ta ~= "userdata") or (tb ~= "table" and tb ~= "userdata") then
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
    and a.max_health == b.max_health
    and a.hunger == b.hunger
    and a.max_hunger == b.max_hunger
end

local function default_vitals()
  local c = GameCfg.Vitals
  return freeze_snapshot({
    health = c.MaxHealth,
    max_health = c.MaxHealth,
    hunger = c.MaxHunger,
    max_hunger = c.MaxHunger,
  }, 0, "ClientStore.vitals")
end

local function sanitize_vital_field(raw, fallback)
  if Number.is_finite_number(raw) then
    return math.floor(raw)
  end
  return fallback
end

local function normalize_camera_distance(raw)
  if not Number.is_finite_number(raw) or raw <= 0 then
    return nil
  end
  local base = GameCfg.Ability.BodyScale.CameraDistance
  if not Number.is_finite_number(base) or base <= 0 then
    return nil
  end
  return BodyScale.derive(BodyScale.sanitize(raw / base)).CameraDistance
end

local function sanitize_position(pos)
  if pos == nil then
    return nil, true
  end
  local ok, vec = EngineRead.read_vec3(
    pos,
    "ClientStore.sanitize_position"
  )
  if not ok or vec == nil then
    return nil, false
  end
  return freeze_snapshot({
    x = vec.x,
    y = vec.y,
    z = vec.z,
  }, 0, "ClientStore.position"), true
end

local function resolve_zone(pos, zones)
  if pos == nil or type(zones) ~= "table" then
    return nil, nil
  end
  for _, zone in ipairs(GameCfg.Zones) do
    local scene = zones[zone.Id]
    local bounds = scene and scene.Boundary
    if type(bounds) == "table"
        and Number.is_finite_number(bounds.MinX) and Number.is_finite_number(bounds.MaxX)
        and Number.is_finite_number(bounds.MinZ) and Number.is_finite_number(bounds.MaxZ) then
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
    endsAt = Number.is_finite_number(payload.endsAt) and payload.endsAt or nil,
    weakUntil = Number.is_finite_number(payload.weakUntil) and payload.weakUntil or nil,
    platformPending = payload.platformPending and true or nil,
  }, 0, "ClientStore.survival")
end

--- 归一化一名队友：字段非法返回 nil 表示整条快照丢弃。
---@param member any
---@return table|nil
local function normalize_party_member(member)
  if type(member) ~= "table"
      or not Number.is_finite_number(member.userId)
      or type(member.name) ~= "string" then
    return nil
  end
  if member.health ~= nil and not Number.is_finite_number(member.health) then
    return nil
  end
  if member.max_health ~= nil and not Number.is_finite_number(member.max_health) then
    return nil
  end
  local phase = member.phase
  if phase == nil then
    phase = "alive"
  elseif type(phase) ~= "string" or not VALID_SURVIVAL_PHASES[phase] then
    return nil
  end
  return {
    userId = member.userId,
    name = member.name,
    health = member.health,
    max_health = member.max_health,
    phase = phase,
    self = member.self == true or nil,
  }
end

--- 归一化组队邀请；返回 (邀请表或 nil, 载荷是否合法)。
---@param raw any
---@return table|nil, boolean
local function normalize_party_invite(raw)
  if raw == nil then
    return nil, true
  end
  if type(raw) ~= "table"
      or not Number.is_finite_number(raw.fromUserId)
      or not Number.is_finite_number(raw.expiresInSec)
      or raw.expiresInSec < 0 then
    return nil, false
  end
  if raw.expiresAt ~= nil and not Number.is_finite_number(raw.expiresAt) then
    return nil, false
  end
  return {
    fromUserId = raw.fromUserId,
    fromName = type(raw.fromName) == "string" and raw.fromName or nil,
    expiresInSec = raw.expiresInSec,
    expiresAt = raw.expiresAt,
  }, true
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
    local normalized = normalize_party_member(member)
    if normalized == nil then
      return nil
    end
    members[i] = normalized
  end
  if payload.state == "party" and (not Number.is_finite_number(payload.partyId) or #members < 1) then
    return nil
  end
  local invite, invite_ok = normalize_party_invite(payload.invite)
  if not invite_ok then
    return nil
  end
  return freeze_snapshot({
    state = payload.state,
    partyId = payload.partyId,
    members = members,
    invite = invite,
    notice = type(payload.notice) == "string" and payload.notice or nil,
  }, 0, "ClientStore.party")
end

local function default_shop()
  return freeze_snapshot({
    purchases = {},
    upgrade_levels = {},
    upgrade_level = 0,
  }, 0, "ClientStore.shop")
end

local function normalize_table_snapshot(payload)
  if type(payload) ~= "table" then
    return nil
  end
  return clone_value(payload, 0)
end

local function default_host()
  local REUtil = require("common.re_util")
  local Players = game:GetService("Players")
  ---@type any
  local RunService = game:GetService("RunService")
  local World = game:GetService("World")
  return {
    get_re = function(name)
      return REUtil:get_re(name)
    end,
    heartbeat = RunService.Heartbeat,
    get_server_time = function()
      local ok, now = EngineRead.call_method(World, "GetServerTime", "ClientStore.default_host.get_server_time") -- 宿主时钟未就绪或异常时安全降级为 dt 步进
      return (ok and Number.is_finite_number(now)) and now or nil
    end,
    get_local_player = function()
      local ok, player = EngineRead.read_field(Players, "LocalPlayer", "ClientStore.default_host.get_local_player")
      return ok and player or nil
    end,
    get_local_character = function()
      local ok_p, player = EngineRead.read_field(Players, "LocalPlayer", "ClientStore.default_host.get_local_character")
      if not ok_p then return nil end
      local ok_ch, character = EngineRead.read_character(player, "ClientStore.default_host.get_local_character")
      return ok_ch and character or nil
    end,
    get_local_position = function()
      local ok_p, player = EngineRead.read_field(Players, "LocalPlayer", "ClientStore.default_host.get_local_position")
      if not ok_p then return nil end
      local ok_pos, pos = EngineRead.read_player_position(player, "ClientStore.default_host.get_local_position")
      return ok_pos and pos or nil
    end,
    read_player_attr = function(player, key)
      local ok, val = EngineRead.read_attribute(
        player,
        key,
        "ClientStore.default_host.read_player_attr"
      )
      return ok and val or nil
    end,
    read_char_attr = function(character, key)
      local ok, val = EngineRead.read_attribute(character,
        key, "ClientStore.default_host.read_char_attr")
      return ok and val or nil
    end,
    get_player_attr_signal = function(player, key)
      local ok, sig = EngineRead.call_method(player, "GetAttributeChangedSignal", "ClientStore.default_host.get_player_attr_signal", key)
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

--- 造全部状态：字段名、初值与比较器沿用拆分前的内联构造。
---@return table<string, table>
local function create_states()
  return {
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
    shop = State.new("ClientStore.shop", default_shop()),
    local_character = State.new("ClientStore.local_character", nil),
    camera_distance = State.new("ClientStore.camera_distance", nil),
    hud_visible = State.new("ClientStore.hud_visible", true),
    active_modal = State.new("ClientStore.active_modal", nil),
    modal_payload = State.new("ClientStore.modal_payload", nil),
    overlays = State.new("ClientStore.overlays", freeze_snapshot({}, 0, "ClientStore.overlays")),
  }
end

--- 图鉴快照：三个集合字段必须是表，总数必须是有限数。
---@param payload any
---@return table|nil
local function normalize_compendium(payload)
  if type(payload) ~= "table" then return nil end
  for _, key in ipairs({ "unlocked", "weights", "catches" }) do
    if payload[key] ~= nil and type(payload[key]) ~= "table" then return nil end
  end
  if payload.total ~= nil and not Number.is_finite_number(payload.total) then return nil end
  return normalize_table_snapshot(payload)
end

--- 纪录快照：必须带非空 fishId。
---@param payload any
---@return table|nil
local function normalize_records(payload)
  if type(payload) ~= "table" or type(payload.fishId) ~= "string" or payload.fishId == "" then return nil end
  return normalize_table_snapshot(payload)
end

--- 任务快照落地后把通知文案转成一条 message。
---@param states table<string, table>
---@param normalized table
local function apply_quest_snapshot(states, normalized)
  if type(normalized.notice) == "string" and normalized.notice ~= "" then
    states.message:set(freeze_snapshot({ text = normalized.notice }, 0, "ClientStore.message"))
  end
end

--- 剧情快照落地后：读过的那条剧情要把剧情弹窗关掉。
---@param states table<string, table>
---@param normalized table
local function apply_story_snapshot(states, normalized)
  if normalized.read == true and states.active_modal:now() == "story" then
    local current = states.modal_payload:now()
    if type(current) ~= "table" or current.read_key == nil or current.read_key == normalized.read_key then
      states.active_modal:set(nil)
      states.modal_payload:set(nil)
    end
  end
end

--- 道具栏快照落地后顺带同步金币。
---@param states table<string, table>
---@param _ table 归一化后的快照（本动作不用）
---@param payload any
local function apply_item_bar_snapshot(states, _, payload)
  if type(payload) == "table" and Number.is_finite_number(payload.coin) then
    states.coin:set(math.floor(payload.coin))
  end
end

--- 剧情通知：写剧情状态并打开剧情弹窗。
---@param states table<string, table>
---@param cloned any
local function apply_story_notice(states, cloned)
  if type(cloned) ~= "table" then
    return
  end
  local story = freeze_snapshot(cloned, 0, "ClientStore.story")
  states.story:set(story)
  states.active_modal:set("story")
  states.modal_payload:set(story)
end

--- 商店回执：合并购买与升级进度，并同步金币。
---@param states table<string, table>
---@param _ any 克隆载荷（本动作不用）
---@param payload any
local function apply_shop_result(states, _, payload)
  if type(payload) ~= "table" then
    return
  end
  local previous = states.shop:now()
  local purchases, upgrade_levels = {}, {}
  for key, value in pairs(previous.purchases or {}) do purchases[key] = value end
  for key, value in pairs(previous.upgrade_levels or {}) do upgrade_levels[key] = value end
  local upgrade_level = previous.upgrade_level or 0
  if payload.ok then
    if payload.number then purchases[payload.number] = (purchases[payload.number] or 0) + 1 end
    if payload.kind and payload.level then
      upgrade_levels[payload.kind] = math.max(upgrade_levels[payload.kind] or 0, payload.level)
    end
    if payload.action == "UpgradeStorage" and payload.level then upgrade_level = payload.level end
  end
  states.shop:set(freeze_snapshot({
    purchases = purchases, upgrade_levels = upgrade_levels, upgrade_level = upgrade_level,
  }, 0, "ClientStore.shop"))
  if Number.is_finite_number(payload.coinAfter) then
    states.coin:set(math.floor(payload.coinAfter))
  end
end

--- 快照频道登记表：归一化函数、目标状态与落地后的附加动作。
---@param states table<string, table>
---@return table<string, table>
local function snapshot_handlers_of(states)
  return {
    ItemBarState = { state = states.item_bar, normalize = normalize_table_snapshot, after = apply_item_bar_snapshot },
    SurvivalState = { state = states.survival, normalize = normalize_survival },
    PartyState = { state = states.party, normalize = normalize_party },
    CastState = { state = states.cast, normalize = normalize_table_snapshot },
    SpecialItemState = { state = states.special_item, normalize = normalize_table_snapshot },
    FishCombatState = { state = states.fish_combat, normalize = normalize_table_snapshot },
    LootState = { state = states.loot, normalize = normalize_table_snapshot },
    QuestState = { state = states.quest, normalize = normalize_table_snapshot, after = apply_quest_snapshot },
    StoryState = { state = states.story, normalize = normalize_table_snapshot, after = apply_story_snapshot },
    FerryState = { state = states.ferry, normalize = normalize_table_snapshot },
    GrillState = { state = states.grill, normalize = normalize_table_snapshot },
    LotteryResult = { state = states.lottery_result, normalize = normalize_table_snapshot },
    BlindboxResult = { state = states.blindbox_result, normalize = normalize_table_snapshot },
    PlatformResult = { state = states.platform_result, normalize = normalize_table_snapshot },
    CompendiumState = { state = states.compendium, normalize = normalize_compendium, ordered_seq = true },
    RecordsState = { state = states.records, normalize = normalize_records, ordered_seq = true },
    GMResult = { state = states.gm_result, normalize = normalize_table_snapshot },
  }
end

--- 离散回执频道。
local DISCRETE_HANDLERS = {
  StoryNotice = apply_story_notice,
  ShopResult = apply_shop_result,
}

--- 组装只读状态面：每个字段都套上 readonly 包装。
---@param states table<string, table>
---@param clock table
---@param on_server_event table
---@param on_reconnect table
---@return table
local function build_store(states, clock, on_server_event, on_reconnect)
  return freeze_table({
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
end

-- 宿主绑定句柄：连接表、已绑玩家与销毁标记都留在绑定句柄上；
-- 方法名沿用拆分前的局部函数名，bind_host 只做装配。
---@class ClientStoreBinding: table<string, any>
---@type ClientStoreBinding
local BindingBehavior = {}

--- 订阅全部下行频道：每个回调转发给写侧句柄的 ingest_event。
---@param self ClientStoreBinding
function BindingBehavior.connect_channels(self)
  local get_re = self.resolved.get_re
  if type(get_re) ~= "function" then
    return
  end
  local writer = self.writer
  for _, channel in ipairs(self.channels) do
    local re = get_re(channel)
    local signal = re and re.OnClientEvent
    if signal and type(signal.Connect) == "function" then
      local channel_name = channel
      local conn = signal:Connect(function(payload)
        if self.disposed then
          return
        end
        writer:ingest_event(channel_name, payload)
      end)
      self.connections[#self.connections + 1] = conn
    end
  end
end

--- 断开并清空玩家属性连接。
---@param self ClientStoreBinding
function BindingBehavior.clear_player_attr_conns(self)
  local conns = self.player_attr_conns
  for i = #conns, 1, -1 do
    local conn = conns[i]
    conns[i] = nil
    if conn and type(conn.Disconnect) == "function" then
      conn:Disconnect()
    end
  end
  self.bound_player = nil
end

--- 读玩家属性同步生命与饥饿，可选同步金币。
---@param self ClientStoreBinding
---@param player any
---@param include_coin any
function BindingBehavior.sync_player_vitals(self, player, include_coin)
  local read_player_attr = self.read_player_attr
  if player == nil or type(read_player_attr) ~= "function" then
    return
  end
  local c = GameCfg.Vitals
  local raw_health = tonumber(read_player_attr(player, "Health"))
  local raw_max_health = tonumber(read_player_attr(player, "MaxHealth"))
  local raw_hunger = tonumber(read_player_attr(player, "Hunger"))
  local raw_max_hunger = tonumber(read_player_attr(player, "MaxHunger"))
  local raw_coin = include_coin and tonumber(read_player_attr(player, "FishCoin")) or nil
  self.writer:update_vitals({
    health = Number.is_finite_number(raw_health) and raw_health or c.MaxHealth,
    max_health = Number.is_finite_number(raw_max_health) and raw_max_health or c.MaxHealth,
    hunger = Number.is_finite_number(raw_hunger) and raw_hunger or c.MaxHunger,
    max_hunger = Number.is_finite_number(raw_max_hunger) and raw_max_hunger or c.MaxHunger,
    coin = Number.is_finite_number(raw_coin) and raw_coin or nil,
  })
end

--- 绑定玩家：换玩家先断上一轮属性信号，再订阅金币与四项生命属性。
---@param self ClientStoreBinding
---@param player any
function BindingBehavior.ensure_player_bound(self, player)
  if player == self.bound_player then
    return
  end
  self:clear_player_attr_conns()
  if player == nil then
    return
  end
  self.bound_player = player
  local get_player_attr_signal = self.get_player_attr_signal
  local read_player_attr = self.read_player_attr
  if type(get_player_attr_signal) == "function" then
    local coin_sig = get_player_attr_signal(player, "FishCoin")
    if coin_sig and type(coin_sig.Connect) == "function" then
      local conn = coin_sig:Connect(function()
        if self.disposed or self.bound_player ~= player then
          return
        end
        local raw = type(read_player_attr) == "function" and tonumber(read_player_attr(player, "FishCoin")) or nil
        if Number.is_finite_number(raw) then
          self.writer:set_coin(raw)
        end
      end)
      self.player_attr_conns[#self.player_attr_conns + 1] = conn
    end
    for _, key in ipairs({ "Health", "MaxHealth", "Hunger", "MaxHunger" }) do
      local sig = get_player_attr_signal(player, key)
      if sig and type(sig.Connect) == "function" then
        local conn = sig:Connect(function()
          if self.disposed or self.bound_player ~= player then
            return
          end
          self:sync_player_vitals(player, false)
        end)
        self.player_attr_conns[#self.player_attr_conns + 1] = conn
      end
    end
  end
  self:sync_player_vitals(player, true)
end

--- 心跳：步进时钟并在同一 batch 内更新空间与相机传感状态。
---@param self ClientStoreBinding
function BindingBehavior.connect_heartbeat(self)
  local resolved = self.resolved
  local heartbeat = resolved.heartbeat
  if not heartbeat or type(heartbeat.Connect) ~= "function" then
    return
  end
  local writer = self.writer
  local get_server_time = resolved.get_server_time
  local get_local_position = resolved.get_local_position
  local get_local_character = resolved.get_local_character
  local read_char_attr = resolved.read_char_attr
  local get_zones = resolved.get_zones
  local hb_conn = heartbeat:Connect(function(dt)
    if self.disposed then
      return
    end
    if type(self.get_local_player) == "function" then
      self:ensure_player_bound(self.get_local_player())
    end
    local now = type(get_server_time) == "function" and get_server_time() or nil
    -- 先独立步进时钟（保留跨多秒时 SpokeClock 逐秒 batch 排空语义），再原子更新空间与相机传感状态
    writer:step_clock(dt, now)
    SpokeRuntime.batch(function()
      if type(get_local_position) == "function" then
        local pos = get_local_position()
        local zones = type(get_zones) == "function" and get_zones() or nil
        writer:update_spatial(pos, zones)
      end
      if type(get_local_character) == "function" then
        local character = get_local_character()
        local raw_dist = (character ~= nil and type(read_char_attr) == "function")
          and read_char_attr(character, "CameraDistance") or nil
        writer:update_camera_target(character, raw_dist)
      end
    end)
  end)
  self.connections[#self.connections + 1] = hb_conn
end

--- 解绑：断频道与玩家属性连接；重复调用无副作用。
---@param self ClientStoreBinding
function BindingBehavior.dispose(self)
  if self.disposed then
    return
  end
  self.disposed = true
  if self.writer.active_binding == self then
    self.writer.active_binding = nil
  end
  self:clear_player_attr_conns()
  local connections = self.connections
  for i = #connections, 1, -1 do
    local conn = connections[i]
    connections[i] = nil
    if conn and type(conn.Disconnect) == "function" then
      conn:Disconnect()
    end
  end
end

-- 写侧句柄：状态表、clock、快照序号与当前宿主绑定都留在句柄上；
-- 方法名沿用拆分前的 writer 方法名，ClientStore.new 只做装配。
---@class ClientStoreHandle: table<string, any>
---@type ClientStoreHandle
local WriterBehavior = {}

---@param self ClientStoreHandle
---@param flag any
function WriterBehavior.set_connected(self, flag)
  self.states.connected:set(flag == true)
end

---@param self ClientStoreHandle
---@param dt any
---@param now any
function WriterBehavior.step_clock(self, dt, now)
  local safe_dt = (Number.is_finite_number(dt) and dt >= 0) and dt or 0
  local safe_now = Number.is_finite_number(now) and now or nil
  self.clock:step(safe_dt, safe_now)
end

---@param self ClientStoreHandle
---@param seconds any
function WriterBehavior.advance_clock(self, seconds)
  self.clock:advance(seconds)
end

--- 一条下行事件：登记表频道走快照落地，其余走离散回执。
---@param self ClientStoreHandle
---@param channel any
---@param payload any
---@return boolean
function WriterBehavior.ingest_event(self, channel, payload)
  local states = self.states
  if type(channel) ~= "string" or channel == "" then
    return false
  end
  local entry = self.snapshot_handlers[channel]
  if entry ~= nil then
    if entry.ordered_seq and type(payload) == "table"
      and Number.is_finite_number(payload.seq) and Number.is_finite_number(self.snapshot_seq[channel])
      and payload.seq <= self.snapshot_seq[channel] then
      return false
    end
    local normalized = entry.normalize(payload)
    if normalized == nil then
      return false
    end
    if type(payload) == "table" and Number.is_finite_number(payload.seq) then
      self.snapshot_seq[channel] = payload.seq
    end
    SpokeRuntime.batch(function()
      states.connected:set(true)
      entry.state:set(normalized)
      if entry.after ~= nil then
        entry.after(states, normalized, payload)
      end
      self.on_server_event:invoke({ channel = channel, payload = normalized })
    end)
    return true
  end

  local cloned = clone_value(payload, 0)
  local discrete = DISCRETE_HANDLERS[channel]
  SpokeRuntime.batch(function()
    states.connected:set(true)
    if discrete ~= nil then
      discrete(states, cloned, payload)
    end
    self.on_server_event:invoke({ channel = channel, payload = cloned })
  end)
  return true
end

---@param self ClientStoreHandle
---@param position any
---@param zones any
---@return boolean
function WriterBehavior.update_spatial(self, position, zones)
  local states = self.states
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

---@param self ClientStoreHandle
---@param value any
---@return boolean
function WriterBehavior.set_coin(self, value)
  if not Number.is_finite_number(value) then
    return false
  end
  self.states.coin:set(math.floor(value))
  return true
end

---@param self ClientStoreHandle
---@param input any
---@return boolean
function WriterBehavior.update_vitals(self, input)
  local states = self.states
  if type(input) ~= "table" then
    return false
  end
  local cur = states.vitals:now()
  local next_vitals = freeze_snapshot({
    health = sanitize_vital_field(input.health, cur.health),
    max_health = sanitize_vital_field(input.max_health, cur.max_health),
    hunger = sanitize_vital_field(input.hunger, cur.hunger),
    max_hunger = sanitize_vital_field(input.max_hunger, cur.max_hunger),
  }, 0, "ClientStore.vitals")
  SpokeRuntime.batch(function()
    states.vitals:set(next_vitals)
    if Number.is_finite_number(input.coin) then
      states.coin:set(math.floor(input.coin))
    end
  end)
  return true
end

---@param self ClientStoreHandle
---@param character any
---@param raw_distance any
---@return boolean
function WriterBehavior.update_camera_target(self, character, raw_distance)
  local states = self.states
  local normalized = character ~= nil and normalize_camera_distance(raw_distance) or nil
  SpokeRuntime.batch(function()
    states.local_character:set(character)
    states.camera_distance:set(normalized)
  end)
  return true
end

---@param self ClientStoreHandle
---@param flag any
function WriterBehavior.set_hud_visible(self, flag)
  self.states.hud_visible:set(flag == true)
end

---@param self ClientStoreHandle
---@param modal_id any
---@param payload any
function WriterBehavior.open_modal(self, modal_id, payload)
  if type(modal_id) ~= "string" or modal_id == "" then
    error("ClientStore writer:open_modal 需要非空字符串 modal_id", 2)
  end
  local states = self.states
  local cloned = clone_value(payload, 0)
  SpokeRuntime.batch(function()
    states.active_modal:set(modal_id)
    states.modal_payload:set(cloned)
  end)
end

---@param self ClientStoreHandle
---@param text any
function WriterBehavior.show_notice(self, text)
  local value = text == nil and "" or tostring(text)
  self.states.message:set(freeze_snapshot({ text = value }, 0, "ClientStore.message"))
end

---@param self ClientStoreHandle
---@param expected_id any
function WriterBehavior.close_modal(self, expected_id)
  local states = self.states
  if expected_id ~= nil and states.active_modal:now() ~= expected_id then
    return
  end
  SpokeRuntime.batch(function()
    states.active_modal:set(nil)
    states.modal_payload:set(nil)
  end)
end

---@param self ClientStoreHandle
---@param overlay_id any
---@param active any
function WriterBehavior.set_overlay(self, overlay_id, active)
  local states = self.states
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

--- 重连/离场清场：状态复位、序号清空、发 reconnect 通知。
---@param self ClientStoreHandle
---@param reason any
function WriterBehavior.reset_session(self, reason)
  local states = self.states
  SpokeRuntime.batch(function()
    states.connected:set(false)
    self.snapshot_seq = {}
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
    states.shop:set(default_shop())
    states.local_character:set(nil)
    states.camera_distance:set(nil)
    states.hud_visible:set(true)
    states.active_modal:set(nil)
    states.modal_payload:set(nil)
    states.message:set(nil)
    states.gm_result:set(nil)
    states.overlays:set(freeze_snapshot({}, 0, "ClientStore.overlays"))
    self.on_reconnect:invoke({ reason = reason or "reset" })
  end)
end

---@param self ClientStoreHandle
function WriterBehavior.unbind_host(self)
  local current = self.active_binding
  if current ~= nil then
    self.active_binding = nil
    current:dispose()
  end
end

--- 绑宿主：先解上一轮绑定，再依次接频道、玩家属性与心跳。
---@param self ClientStoreHandle
---@param host table|nil
---@return ClientStoreBinding binding
function WriterBehavior.bind_host(self, host)
  self:unbind_host()
  local resolved = host or default_host()
  local channels = resolved.channels or DEFAULT_CHANNELS
  ---@type ClientStoreBinding
  local binding = {
    writer = self,
    resolved = resolved,
    channels = channels,
    connections = {},
    disposed = false,
    player_attr_conns = {},
    bound_player = nil,
    read_player_attr = resolved.read_player_attr,
    get_player_attr_signal = resolved.get_player_attr_signal,
    get_local_player = resolved.get_local_player,
  }
  for name, method in pairs(BindingBehavior) do binding[name] = method end
  binding:connect_channels()

  local get_local_player = resolved.get_local_player
  if type(get_local_player) == "function" then
    binding:ensure_player_bound(get_local_player())
  end

  binding:connect_heartbeat()

  self.active_binding = binding
  return binding
end

---@param options table|nil { clock?: table, initial_now?: number }
---@return table store 只读响应式状态面
---@return table writer 写侧句柄（仅 L1 宿主入口持有）
function ClientStore.new(options)
  options = options or {}
  local clock = options.clock or SpokeClock.new(options.initial_now)

  local states = create_states()
  local on_server_event = Trigger.new("ClientStore.on_server_event")
  local on_reconnect = Trigger.new("ClientStore.on_reconnect")

  local store = build_store(states, clock, on_server_event, on_reconnect)

  ---@type ClientStoreHandle
  local writer = {
    states = states,
    clock = clock,
    snapshot_handlers = snapshot_handlers_of(states),
    snapshot_seq = {},
    active_binding = nil,
    on_server_event = on_server_event,
    on_reconnect = on_reconnect,
  }
  for name, method in pairs(WriterBehavior) do writer[name] = method end
  return store, writer
end

return ClientStore
