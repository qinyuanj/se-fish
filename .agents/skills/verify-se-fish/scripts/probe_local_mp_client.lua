-- ADR-0044 试玩客户端只读语义探针：核对当前客户端窗口视角的 LocalPlayer 与 ClientStore 摘要。
-- 用法（试玩就绪后执行；一键调度见 probe_local_mp_run.lua）：
--   '$CLI' exec --platform client [--player <UserId>] --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_local_mp_client.lua --json
--   '$CLI' log grep 'PROBE_MP_CLI_' --play-session <session> --max-matches 500
-- 用途：
--   - 配合 `--player <uid>` 实测客户端定向路由是否命中目标窗口（LocalPlayer.UserId 是否等于 <uid>）；
--   - 在 **切换AI** 前后各跑一次，比较 LocalPlayer 与 ClientStore 摘要是否随之切换。
-- 输出：每行 `PROBE_MP_CLI_<nonce> <KIND> k=v ...`，值做百分号转义；KIND 依次为 CLIENT / VISIBLE / END。
-- 严格只读：只读 Players 与 _G.ClientSpoke.Store 的只读信号（:now()），全部包 pcall，缺失时记 nil。
-- nonce：调度脚本会在文件头注入 `local PROBE_MP_NONCE = '<nonce>'`；直接执行时回退为时间戳。
-- 全文字符串只用单引号（客户端 exec 约束，见 verify-se-fish/features/README.md）。

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

local function render(tag, kind, fields)
  local parts = { tag, kind }
  for _, pair in ipairs(fields) do
    local value = pair[2]
    if value == nil then value = 'nil' end
    parts[#parts + 1] = pair[1] .. '=' .. encode(value)
  end
  print(table.concat(parts, ' '))
end

local function format_pos(pos)
  if pos == nil then return nil end
  local x = safe(function() return pos.x or pos.X end)
  local y = safe(function() return pos.y or pos.Y end)
  local z = safe(function() return pos.z or pos.Z end)
  if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
  return string.format('%.2f,%.2f,%.2f', x, y, z)
end

local function read_signal(store, name)
  local signal = store and safe(function() return store[name] end)
  if signal == nil then return nil end
  return safe(function() return signal:now() end)
end

local Players = safe(function() return game:GetService('Players') end)
local WorldService = safe(function() return game:GetService('World') end)

local nonce = safe(function() return PROBE_MP_NONCE end)
if nonce == nil then
  local now = WorldService and safe(function() return WorldService:GetServerTime() end)
  nonce = string.format('%d', math.floor((tonumber(now) or os.time()) * 1000))
end
local tag = 'PROBE_MP_CLI_' .. tostring(nonce)

local local_player = Players and safe(function() return Players.LocalPlayer end)
local local_uid = local_player and safe(function() return local_player.UserId end)
local character = local_player and safe(function() return local_player.Character end)
local pos = character and (safe(function() return character.Position end)
  or safe(function() return character:GetPosition() end))
local visible = (Players and safe(function() return Players:GetPlayers() end)) or {}

local client_spoke = safe(function() return rawget(_G, 'ClientSpoke') end)
local store = type(client_spoke) == 'table' and safe(function() return client_spoke.Store end) or nil

local survival = read_signal(store, 'survival')
local store_pos = format_pos(read_signal(store, 'position'))
local char_pos = format_pos(pos)
local party = read_signal(store, 'party')
local party_state = type(party) == 'table' and safe(function() return party.state end) or nil
local party_members, party_self_uid = nil, nil
local members = type(party) == 'table' and safe(function() return party.members end) or nil
if members ~= nil then
  party_members = 0
  for _, row in ipairs(members) do
    party_members = party_members + 1
    if safe(function() return row.self end) == true then party_self_uid = safe(function() return row.userId end) end
  end
end

local report = {
  tag = tag,
  client = {
    local_uid = local_uid ~= nil and tostring(local_uid) or nil,
    local_name = local_player and safe(function() return local_player.Name end) or nil,
    players_visible = #visible,
    char = character ~= nil,
    pos = char_pos,
    store = store ~= nil,
    store_pos = store_pos,
    connected = read_signal(store, 'connected'),
    zone_id = read_signal(store, 'zone_id'),
    zone_name = read_signal(store, 'zone_name'),
    coin = read_signal(store, 'coin'),
    survival_phase = type(survival) == 'table' and safe(function() return survival.phase end) or nil,
    party_state = party_state,
    party_members = party_members,
    party_self_uid = party_self_uid ~= nil and tostring(party_self_uid) or nil,
    store_character = store ~= nil and read_signal(store, 'local_character') ~= nil or nil,
  },
  visible = {},
}

for idx, player in ipairs(visible) do
  local uid = safe(function() return player.UserId end)
  report.visible[#report.visible + 1] = {
    idx = idx,
    uid = uid ~= nil and tostring(uid) or nil,
    name = safe(function() return player.Name end),
    is_local = local_player ~= nil and player == local_player,
  }
end

local c = report.client
render(tag, 'CLIENT', {
  { 'local_uid', c.local_uid }, { 'local_name', c.local_name }, { 'players_visible', c.players_visible },
  { 'char', c.char }, { 'pos', c.pos }, { 'store', c.store }, { 'store_pos', c.store_pos }, { 'connected', c.connected },
  { 'zone_id', c.zone_id }, { 'zone_name', c.zone_name }, { 'coin', c.coin },
  { 'survival_phase', c.survival_phase }, { 'party_state', c.party_state },
  { 'party_members', c.party_members }, { 'party_self_uid', c.party_self_uid },
  { 'store_character', c.store_character },
})
for _, v in ipairs(report.visible) do
  render(tag, 'VISIBLE', { { 'idx', v.idx }, { 'uid', v.uid }, { 'name', v.name }, { 'is_local', v.is_local } })
end
render(tag, 'END', { { 'visible', #report.visible } })

return report
