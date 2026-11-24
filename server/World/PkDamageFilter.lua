-- PK 与安全区伤害过滤（#300）：只看本次命中的来源、目标位置与当前队伍。
-- 同队免伤沿用今天的 Party.SameParty 口径，不新建小队系统。鱼等非玩家来源不拦。

local GameCfg = require("common.GameCfg")

local PkDamageFilter = {}

local function position_of(player)
  local character = player and player.Character
  if not character then return nil end
  local ok, value = pcall(function() return character.Position end) -- 兼容引擎 userdata 位置
  if not ok or (type(value) ~= "table" and type(value) ~= "userdata") then return nil end
  local x, z = tonumber(value.x), tonumber(value.z)
  if not x or not z then return nil end
  return { x = x, z = z }
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
    if party and type(party.SameParty) == "function" then
      local ok, same = pcall(party.SameParty, party, source, target)
      if ok and same then return false end
    end
    local markers = (context and context.ZoneMarkers) or opts.zone_markers
    local snapshot = markers and markers.Zones
    local zones = opts.zones or GameCfg.Zones or {}
    for _, config in ipairs(zones) do
      if config.Id == "fishPond" then
        local zone = snapshot and snapshot[config.Id] or config.Scene
        if not (zone and zone.Boundary) then
          if target.UserId == nil then return true end
          print("[PkDamageFilter] 鱼塘区域未解析，非同队玩家伤害按鱼塘外处理",
            tostring(source.UserId), tostring(target.UserId))
          return true
        end
        if inside(position_of(source), zone) and inside(position_of(target), zone) then
          return false
        end
        break
      end
    end
    return true
  end
end

return PkDamageFilter
