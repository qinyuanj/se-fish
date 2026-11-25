local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")

local PkDamageFilter = {}

local function user_id_of(player)
  local ok, uid = EngineRead.read_user_id(player, "PkDamageFilter.user_id_of")
  if not ok then return nil end
  return uid
end

local function position_of(player)
  local ok, pos, reason = EngineRead.read_player_position(player, "PkDamageFilter.position_of")
  if not ok or pos == nil then
    return nil, reason or "missing"
  end
  return { x = pos.x, z = pos.z }, nil
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
