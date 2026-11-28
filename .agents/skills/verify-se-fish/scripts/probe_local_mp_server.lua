-- ADR-0044 试玩服务端只读语义探针：本地多人测试（多窗口）与调试插件 AI（添加AI / 切换AI）共用。
-- 用法（试玩就绪后执行；一键调度见 probe_local_mp_run.lua）：
--   '$CLI' exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_local_mp_server.lua --json
--   '$CLI' log grep 'PROBE_MP_SRV_' --play-session <session> --max-matches 500
-- 输出：每行 `PROBE_MP_SRV_<nonce> <KIND> k=v ...`，值做百分号转义（空格、=、% 与控制字符），KIND 依次为
--   SUMMARY（汇总）/ PLAYER（逐个 Player）/ CONFLICT（存档键冲突）/ EGGY（非玩家 EggyUnit 抽样）/ END。
-- 严格只读：
--   - 不调用 SaveHost:key / SaveHost:session（二者会固定槽位或新建会话），存档键只从已有会话的 Key 读取，
--     缺失时按 GameCfg.Save.KeyPrefix + UserId + 会话槽位纯计算；
--   - 不写 Attribute、不改玩家/存档/世界对象；所有引擎读取都包 pcall，缺失时记 nil 不报错。
-- nonce：调度脚本会在文件头注入 `local PROBE_MP_NONCE = '<nonce>'`；直接执行时回退为服务器时间戳。
-- 全文字符串只用单引号，与客户端探针保持同一 exec 约束。

local MAX_EGGY_SAMPLES = 10

local function safe(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function encode(value)
  local text = tostring(value)
  return (text:gsub('[%s=%%%c]', function(ch)
    return string.format('%%%02X', string.byte(ch))
  end))
end

local function peek_module(name)
  local loaded = type(package) == 'table' and type(package.loaded) == 'table' and package.loaded[name] or nil
  if type(loaded) == 'table' then return loaded end
  local ok, mod = pcall(require, name)
  if ok and type(mod) == 'table' then return mod end
  return nil
end

local function service(name)
  return safe(function() return game:GetService(name) end)
end

local function count_keys(map)
  if type(map) ~= 'table' then return nil end
  local n = 0
  for _ in pairs(map) do n = n + 1 end
  return n
end

local function format_pos(pos)
  if pos == nil then return nil end
  local x = safe(function() return pos.x or pos.X end)
  local y = safe(function() return pos.y or pos.Y end)
  local z = safe(function() return pos.z or pos.Z end)
  if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
  return string.format('%.2f,%.2f,%.2f', x, y, z)
end

local function read_character(player)
  return safe(function() return player.Character end)
end

local function read_position(unit)
  if unit == nil then return nil end
  local pos = safe(function() return unit.Position end)
  if pos == nil then
    pos = safe(function() return unit:GetPosition() end)
  end
  return format_pos(pos)
end

local function is_eggy_unit(unit)
  if unit == nil then return false end
  if safe(function() return unit:IsA('EggyUnit') end) == true then return true end
  return safe(function() return unit.UnitType end) == 'EggyUnit'
end

-- 纯计算存档键：与 SaveHost:key 同式，但不触碰 slot_pinned / sessions。
local function compute_save_key(save_host, game_cfg, uid)
  local sessions = save_host and rawget(save_host, 'sessions')
  local session = type(sessions) == 'table' and sessions[uid] or nil
  if type(session) == 'table' and type(session.Key) == 'string' then
    return session.Key, 'session', session
  end
  local save_cfg = game_cfg and game_cfg.Save
  local prefix = save_cfg and save_cfg.KeyPrefix
  if type(prefix) ~= 'string' then return nil, 'unavailable', session end
  local slot = (type(session) == 'table' and session.current)
    or (save_host and rawget(save_host, 'QaSlot'))
    or (save_cfg and save_cfg.QaSlot)
    or ''
  slot = tostring(slot)
  return prefix .. tostring(uid) .. (slot ~= '' and (':qa:' .. slot) or ''), 'computed', session
end

local function render(tag, kind, fields)
  local parts = { tag, kind }
  for _, pair in ipairs(fields) do
    local value = pair[2]
    if value == nil then value = 'nil' end
    parts[#parts + 1] = pair[1] .. '=' .. encode(value)
  end
  print(table.concat(parts, ' '))
end

-- ===== 采集 =====
local Players = service('Players')
local WorldService = service('World')
local ServerRuntime = peek_module('server.world_host.server_runtime')
local PlayerDataHost = peek_module('server.player_data_host')
local SaveHost = (PlayerDataHost and rawget(PlayerDataHost, 'Save')) or peek_module('server.save_host')
local GameCfg = peek_module('common.game_cfg')

-- 闭包内引用自由名：有注入的文件头 local 时取 local，否则读全局（缺失为 nil，严格全局表下由 pcall 兜住）。
local nonce = safe(function() return PROBE_MP_NONCE end)
if nonce == nil then
  local now = WorldService and safe(function() return WorldService:GetServerTime() end)
  nonce = string.format('%d', math.floor((tonumber(now) or os.time()) * 1000))
end
local tag = 'PROBE_MP_SRV_' .. tostring(nonce)

local players = (Players and safe(function() return Players:GetPlayers() end)) or {}
local rt = ServerRuntime and type(ServerRuntime.current) == 'function' and safe(ServerRuntime.current) or nil
local env = rt and rawget(rt, 'runtime_env') or nil
local world = rt and type(rt.get_world) == 'function' and safe(rt.get_world, rt) or nil
local squad = world and safe(function() return world.squad end) or nil

local report = {
  tag = tag,
  players = {},
  conflicts = {},
  eggy_samples = {},
}

local uid_seen, dup_uid = {}, 0
local key_holders, key_order = {}, {}
local save_key_missing = 0
local character_set = {}

for idx, player in ipairs(players) do
  local uid = safe(function() return player.UserId end)
  local uid_text = tostring(uid)
  if uid_seen[uid_text] then dup_uid = dup_uid + 1 end
  uid_seen[uid_text] = true

  local character = read_character(player)
  if character ~= nil then character_set[character] = true end

  local save_key, key_source, session = compute_save_key(SaveHost, GameCfg, uid)
  if save_key == nil then
    save_key_missing = save_key_missing + 1
  else
    if key_holders[save_key] == nil then
      key_holders[save_key] = {}
      key_order[#key_order + 1] = save_key
    end
    table.insert(key_holders[save_key], uid_text)
  end

  local data = PlayerDataHost and type(PlayerDataHost.get_data_inst) == 'function'
    and safe(PlayerDataHost.get_data_inst, PlayerDataHost, player) or nil
  local inner = type(data) == 'table' and type(data.data) == 'table' and data.data or nil

  local party = nil
  local party_of = squad and safe(function() return squad.party_of end)
  if type(party_of) == 'table' then party = party_of[uid] end
  local online = squad and safe(function() return squad.online end)

  local row = {
    idx = idx,
    uid = uid_text,
    name = safe(function() return player.Name end),
    char = character ~= nil,
    pos = read_position(character),
    save_key = save_key,
    save_key_source = key_source,
    save_state = type(session) == 'table' and session.State or nil,
    pd_ready = data ~= nil,
    coins = inner and inner.FishCoin or nil,
    zone = inner and inner.Zone or nil,
    party = party ~= nil and tostring(party) or 'none',
    squad_online = type(online) == 'table' and online[uid] ~= nil or nil,
    phase = safe(function() return player:GetAttribute('SurvivalPhase') end),
    in_runtime = env and type(env.current_players) == 'table' and env.current_players[uid] ~= nil or nil,
    active = env and type(env.active_players) == 'table' and env.active_players[uid] ~= nil or nil,
    tree = env and type(env.player_trees) == 'table' and env.player_trees[uid] ~= nil or nil,
  }
  report.players[#report.players + 1] = row
end

local save_key_conflicts = 0
for _, key in ipairs(key_order) do
  local holders = key_holders[key]
  if #holders > 1 then
    save_key_conflicts = save_key_conflicts + 1
    report.conflicts[#report.conflicts + 1] = { key = key, uids = table.concat(holders, ',') }
  end
end

-- 场景 EggyUnit 统计：判别「添加AI」是进了 Players 还是只以非 Player 的 EggyUnit 存在。
local eggy_scan, eggy_total, eggy_player_chars = 'unavailable', nil, nil
local descendants = WorldService and safe(function() return WorldService:GetDescendants() end)
if type(descendants) == 'table' then
  eggy_scan, eggy_total, eggy_player_chars = 'ok', 0, 0
  for _, unit in ipairs(descendants) do
    if is_eggy_unit(unit) then
      eggy_total = eggy_total + 1
      if character_set[unit] then
        eggy_player_chars = eggy_player_chars + 1
      elseif #report.eggy_samples < MAX_EGGY_SAMPLES then
        report.eggy_samples[#report.eggy_samples + 1] = {
          name = safe(function() return unit.Name end),
          unit_id = safe(function() return unit.UnitId end),
          pos = read_position(unit),
        }
      end
    end
  end
end

local rt_current = env and count_keys(env.current_players) or nil
report.summary = {
  players = #players,
  runtime = rt ~= nil,
  rt_current = rt_current,
  rt_active = env and count_keys(env.active_players) or nil,
  rt_trees = env and count_keys(env.player_trees) or nil,
  rt_leaving = env and count_keys(env.leaving_players) or nil,
  runtime_consistent = rt_current ~= nil and rt_current == #players or nil,
  dup_uid = dup_uid,
  save_host = SaveHost ~= nil,
  player_data = PlayerDataHost ~= nil,
  save_keys = #key_order,
  save_key_missing = save_key_missing,
  save_key_conflicts = save_key_conflicts,
  eggy_scan = eggy_scan,
  eggy_total = eggy_total,
  eggy_player_chars = eggy_player_chars,
  eggy_non_player = eggy_total and (eggy_total - eggy_player_chars) or nil,
}

-- ===== 输出 =====
local s = report.summary
render(tag, 'SUMMARY', {
  { 'players', s.players }, { 'runtime', s.runtime }, { 'rt_current', s.rt_current },
  { 'rt_active', s.rt_active }, { 'rt_trees', s.rt_trees }, { 'rt_leaving', s.rt_leaving },
  { 'runtime_consistent', s.runtime_consistent }, { 'dup_uid', s.dup_uid },
  { 'save_host', s.save_host }, { 'player_data', s.player_data }, { 'save_keys', s.save_keys },
  { 'save_key_missing', s.save_key_missing }, { 'save_key_conflicts', s.save_key_conflicts },
  { 'eggy_scan', s.eggy_scan }, { 'eggy_total', s.eggy_total },
  { 'eggy_player_chars', s.eggy_player_chars }, { 'eggy_non_player', s.eggy_non_player },
})
for _, row in ipairs(report.players) do
  render(tag, 'PLAYER', {
    { 'idx', row.idx }, { 'uid', row.uid }, { 'name', row.name }, { 'char', row.char }, { 'pos', row.pos },
    { 'save_key', row.save_key }, { 'save_key_source', row.save_key_source }, { 'save_state', row.save_state },
    { 'pd_ready', row.pd_ready }, { 'coins', row.coins }, { 'zone', row.zone }, { 'party', row.party },
    { 'squad_online', row.squad_online }, { 'phase', row.phase }, { 'in_runtime', row.in_runtime },
    { 'active', row.active }, { 'tree', row.tree },
  })
end
for _, c in ipairs(report.conflicts) do
  render(tag, 'CONFLICT', { { 'key', c.key }, { 'uids', c.uids } })
end
for idx, e in ipairs(report.eggy_samples) do
  render(tag, 'EGGY', { { 'idx', idx }, { 'name', e.name }, { 'unit_id', e.unit_id }, { 'pos', e.pos } })
end
render(tag, 'END', { { 'players', #report.players }, { 'conflicts', #report.conflicts } })

return report
