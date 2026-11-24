local BodyScale = require("common.body_scale")

local InteractionPoints = { anchors = {} }

local function flat_distance(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function InteractionPoints:find_anchor(name)
  local cached = self.anchors[name]
  if cached then return cached end
  local world = game:GetService("World")
  local ok, unit = pcall(world.FindFirstChild, world, name, true)
  if not ok then
    print("[InteractionPoints] 查找场景锚点失败", name, tostring(unit))
    return nil
  end
  if unit then self.anchors[name] = unit end
  return unit
end

function InteractionPoints:in_range(player, point)
  local character = player and player.Character
  local position = character and character.Position
  if not position then return nil end
  local names = point.AnchorNames or { point.AnchorName }
  for _, name in ipairs(names) do
    local anchor = self:find_anchor(name)
    local center = anchor and anchor.Position
    if center and flat_distance(position, center)
        <= BodyScale.interaction_radius(character, point.Radius) + (point.Slack or 0) then
      return anchor
    end
  end
  return nil
end

return InteractionPoints
