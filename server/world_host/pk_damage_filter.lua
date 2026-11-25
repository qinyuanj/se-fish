
local GameCfg = require("common.game_cfg")

local PkDamageFilter = {}

local function is_finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function user_id_of(player)
  if not is_object(player) then return nil end
  local ok, uid = pcall(function() return player.UserId end) -- 兼容引擎 userdata 玩家
  if not ok then return nil end
  return uid
end

local function position_of(player)
  if not is_object(player) then return nil, "invalid-player" end
  local ok_char, character = pcall(function() return player.Character end) -- 兼容引擎 userdata 玩家
  if not ok_char then return nil, tostring(character) end
  if not is_object(character) then return nil, "no-character" end
  local ok_pos, value = pcall(function() return character.Position end) -- 兼容引擎 userdata 位置
  if not ok_pos then return nil, tostring(value) end
  if not is_object(value) then return nil, "invalid-position" end
  local ok_xz, coords = pcall(function() return { x = value.x, z = value.z } end) -- 兼容引擎 userdata 分量
  if not ok_xz then return nil, tostring(coords) end
  local x, z = tonumber(coords.x), tonumber(coords.z)
  if not is_finite(x) or not is_finite(z) then
    return nil, "non-finite-position"
  end
  return { x = x, z = z }, nil
end

local function inside(position, zone)
  local boundary = zone and zone.Boundary
  if not boundary or not position then return false end
  return position.x > boundary.MinX and position.x < boundary.MaxX
    and position.z > boundary.MinZ and position.z < boundary.MaxZ
end

function PkDamageFilter.make(opts)
  opts = type(opts) == "table" and opts or {}
  return function(hit, target, context)
    local source = hit and hit.sourcePlayer
    if not source or not target or source == target then return true end
    local party = (context and context.Party) or opts.party
    if party and type(party.same_party) == "function" then
      local ok, same = pcall(party.same_party, party, source, target)
      if ok and same then return false end
    end
    local target_uid = user_id_of(target)
    if target_uid == nil then return true end
    local source_uid = user_id_of(source)
    local markers = (context and context.ZoneMarkers) or opts.zone_markers
    local snapshot = markers and markers.Zones
    local zones = opts.zones or GameCfg.Zones or {}
    for _, config in ipairs(zones) do
      if config.Id == "fishPond" then
        local zone = snapshot and snapshot[config.Id] or config.Scene
        if not (zone and zone.Boundary) then
          print("[PkDamageFilter] 鱼塘区域未解析，非同队玩家伤害按鱼塘外处理",
            tostring(source_uid), tostring(target_uid))
          return true
        end
        local source_pos, source_err = position_of(source)
        if not source_pos then
          print("[PkDamageFilter] 攻击者位置读取失败，保守拦截玩家间伤害",
            tostring(source_uid), tostring(target_uid), tostring(source_err))
          return false
        end
        local target_pos, target_err = position_of(target)
        if not target_pos then
          print("[PkDamageFilter] 目标位置读取失败，保守拦截玩家间伤害",
            tostring(source_uid), tostring(target_uid), tostring(target_err))
          return false
        end
        if inside(source_pos, zone) and inside(target_pos, zone) then
          return false
        end
        break
      end
    end
    return true
  end
end

return PkDamageFilter
