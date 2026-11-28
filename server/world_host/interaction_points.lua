local BodyScale = require("common.body_scale")
local Number = require("common.number")
local ZoneMarkers = require("common.zone_markers")

local InteractionPoints = {}

-- 运行期唯一锚点来源是编辑态导出的只读几何表（ADR-0013 / #410）：
-- 场景标记已开启静态优化，游戏内不再创建完整 Unit，不能再用 World 服务按名查单位。
function InteractionPoints.find_anchor(_, name)
  local position = ZoneMarkers.anchor_position(name)
  if not position then
    print("[InteractionPoints] 导出几何缺少锚点", name)
    return nil
  end
  return { Name = name, Position = position }
end

function InteractionPoints:in_range(player, point)
  local character = player and player.Character
  local position = character and character.Position
  if not position then return nil end
  local names = point.AnchorNames or { point.AnchorName }
  for _, name in ipairs(names) do
    local anchor = self:find_anchor(name)
    local center = anchor and anchor.Position
    if center and Number.flat_distance(position, center)
        <= BodyScale.interaction_radius(character, point.Radius) + (point.Slack or 0) then
      return anchor
    end
  end
  return nil
end

return InteractionPoints
