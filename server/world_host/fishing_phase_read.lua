-- 钓竿阶段的只读辅助（L2 server.world_host）：从 fishing_phase.lua 原样搬出的环境读取与落点几何，
-- 行为不变，只依赖 common.game_cfg、common.number、common.math_water_judge；不持有阶段状态、不改任何登记表。
local GameCfg = require("common.game_cfg")
local MathWaterJudge = require("common.math_water_judge")
local Number = require("common.number")

local FishingPhaseRead = {}

-- 有限数判断：NaN / inf 直接视为无效坐标。
local function finite(value)
  return Number.is_finite_number(value)
end

-- 当前时钟：阶段的延迟、淡出与结算都以它为准。
function FishingPhaseRead.now_of(tree)
  return tree.clock.now()
end

-- 角色宿主对象：状态未就绪时读取会抛错，按「取不到」处理。
function FishingPhaseRead.character_of(tree)
  local ok, character = pcall(function()
    return tree.states.character:now() or tree.player.Character
  end)
  if ok then return character end
  return nil
end

-- 选中钓竿：槽位、道具数量与请求载荷三者一致才有效，返回槽位、条目与配置定义。
function FishingPhaseRead.selected_rod(tree, payload)
  local slot = tree.states.selected_slot:now()
  local items = tree.states.item_bar:now() or {}
  local entry = type(slot) == "number" and items[slot] or nil
  local definition = entry and (entry.count or 0) >= 1 and GameCfg.Items.Definitions[entry.itemId]
  if not definition or type(definition.Level) ~= "number" then return nil end
  if type(payload) ~= "table" or payload.slot ~= slot or payload.itemId ~= entry.itemId then
    return nil
  end
  return slot, entry, definition
end

-- 落点所在水域：取第一个命中的水域配置。
local function water_zone(x, z)
  local zones = GameCfg.Water and GameCfg.Water.Zones or {}
  for _, candidate in ipairs(zones) do
    if MathWaterJudge.in_zone(candidate, { x = x, y = candidate.SurfaceY, z = z }) then
      return candidate
    end
  end
  return nil
end

-- 抛竿落点：角色朝向水平单位向量外推施法距离，返回落点与所在水域。
function FishingPhaseRead.cast_landing(character)
  local origin = character and character.Position
  local rotation = character and character.Rotation
  if not origin or not rotation or type(rotation.GetForward) ~= "function" then return nil end
  local forward = rotation:GetForward()
  if not forward or not finite(forward.x) or not finite(forward.z) then return nil end
  local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
  if length < 0.01 then return nil end
  local x = origin.x + GameCfg.Casting.Distance * forward.x / length
  local z = origin.z + GameCfg.Casting.Distance * forward.z / length
  local zone = water_zone(x, z)
  return { x = x, y = zone and zone.SurfaceY or origin.y, z = z }, zone
end

-- 鱼钩位置：空中来源的鱼在落点上方抬高 AirSourceHeight。
function FishingPhaseRead.hook_position(session)
  local landing = session and session.landing
  if not landing then return nil end
  local species = session.fishId and GameCfg.Fish[session.fishId]
  local source = species and species.CatchSource or "water"
  local lift = source == "air" and GameCfg.Casting.AirSourceHeight or 0
  return { x = landing.x, y = landing.y + lift, z = landing.z }
end

-- 持鱼信息快照：非 table 一律视为没有。
function FishingPhaseRead.copy_holding(info)
  if type(info) ~= "table" then return nil end
  return info
end

return FishingPhaseRead
