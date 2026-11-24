local body_scale = require("common.body_scale")

local interaction_points = { Anchors = {} }

local function flat_distance(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

function interaction_points:FindAnchor(name)
  local cached = self.Anchors[name]
  if cached then return cached end
  local world = game:GetService("World")
  local ok, unit = pcall(world.FindFirstChild, world, name, true)
  if not ok then
    print("[interaction_points] 查找场景锚点失败", name, tostring(unit))
    return nil
  end
  if unit then self.Anchors[name] = unit end
  return unit
end

function interaction_points:InRange(player, point)
  local character = player and player.Character
  local position = character and character.Position
  if not position then return nil end
  local names = point.AnchorNames or { point.AnchorName }
  for _, name in ipairs(names) do
    local anchor = self:FindAnchor(name)
    local center = anchor and anchor.Position
    if center and flat_distance(position, center)
        <= body_scale.InteractionRadius(character, point.Radius) + (point.Slack or 0) then
      return anchor
    end
  end
  return nil
end

return interaction_points
