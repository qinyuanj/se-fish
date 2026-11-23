-- 场景交互点公开查询（#311）：供新 Spoke 会话与尚未迁移的旧管理器共用。
-- 只负责锚点查找和体型修正后的水平距离，不持有玩法结算状态。
local BodyScale = require("common.BodyScale")

local InteractionPoints = { Anchors = {} }

local function flat_distance(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function InteractionPoints:FindAnchor(name)
  local cached = self.Anchors[name]
  if cached then return cached end
  local world = game:GetService("World")
  local ok, unit = pcall(world.FindFirstChild, world, name, true)
  if not ok then
    print("[InteractionPoints] 查找场景锚点失败", name, tostring(unit))
    return nil
  end
  if unit then self.Anchors[name] = unit end
  return unit
end

function InteractionPoints:InRange(player, point)
  local character = player and player.Character
  local position = character and character.Position
  if not position then return nil end
  local names = point.AnchorNames or { point.AnchorName }
  for _, name in ipairs(names) do
    local anchor = self:FindAnchor(name)
    local center = anchor and anchor.Position
    if center and flat_distance(position, center)
        <= BodyScale.InteractionRadius(character, point.Radius) + (point.Slack or 0) then
      return anchor
    end
  end
  return nil
end

return InteractionPoints
