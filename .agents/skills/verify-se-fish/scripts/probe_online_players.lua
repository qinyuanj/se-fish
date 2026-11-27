-- 试玩服务端只读探针：枚举当前在线真实 Player、坐标、存活/存档状态与小队归属。
-- 用法（试玩就绪后执行）：
--   "$CLI" exec --platform server --file D:/dev/github/se-fish/.agents/skills/verify-se-fish/scripts/probe_online_players.lua --json
-- 取证：
--   "$CLI" log grep "VERIFY_PLAYERS" --play-session <session> --max-matches 100
-- 严格只读：不修改任何玩家、鱼、库存或世界状态。

local Players = game:GetService("Players")
local WorldService = game:GetService("World")

local ok_rt, ServerRuntime = pcall(require, "server.world_host.server_runtime")
local ok_pd, PlayerDataHost = pcall(require, "server.player_data_host")

local ok_t, now = pcall(function() return WorldService:GetServerTime() end)
local stamp = ok_t and string.format("%.3f", tonumber(now) or 0) or tostring(os.clock())
local tag = "VERIFY_PLAYERS_" .. stamp

local list = Players:GetPlayers() or {}
local count = #list
local mode = count == 0 and "empty" or (count == 1 and "solo" or "multiplayer")

local rt = ok_rt and type(ServerRuntime.current) == "function" and ServerRuntime.current() or nil
local world = rt and type(rt.get_world) == "function" and rt:get_world() or nil
local squad = world and world.squad or nil

print(string.format("%s SUMMARY count=%d mode=%s runtime=%s", tag, count, mode, tostring(rt ~= nil)))

for idx, player in ipairs(list) do
  local uid = tostring(player.UserId)
  local name = tostring(player.Name or "")
  local pos_str = "nil"
  local ok_pos, pos = pcall(function()
    local ch = player.Character
    return ch and ch.Position
  end)
  if ok_pos and pos then
    pos_str = string.format("%.2f,%.2f,%.2f", pos.x or 0, pos.y or 0, pos.z or 0)
  end

  local save_state = "unknown"
  local coins = "-"
  local zone = "-"
  if ok_pd and type(PlayerDataHost.get_data_inst) == "function" then
    local ok_d, data = pcall(PlayerDataHost.get_data_inst, PlayerDataHost, player)
    if ok_d and data then
      save_state = tostring(data.load_state or "ready")
      local inner = type(data.data) == "table" and data.data or data
      coins = tostring(inner.FishCoin or inner.coin or "-")
      zone = tostring(inner.Zone or inner.zone or "-")
    else
      save_state = "not_ready"
    end
  end

  local party_id = "none"
  if squad and type(squad.party_of) == "table" then
    local pid = squad.party_of[player.UserId]
    if pid ~= nil then party_id = tostring(pid) end
  end

  local phase = "-"
  local ok_ph, ph = pcall(function() return player:GetAttribute("SurvivalPhase") end)
  if ok_ph and ph ~= nil then phase = tostring(ph) end

  print(string.format(
    "%s PLAYER #%d uid=%s name=%s pos=(%s) save=%s coins=%s zone=%s phase=%s party=%s",
    tag, idx, uid, name, pos_str, save_state, coins, zone, phase, party_id
  ))
end
