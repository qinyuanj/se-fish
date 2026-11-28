-- 跨设施交互气泡互斥仲裁（ADR-0013 / #410）：
-- 在全图 5 类设施（商店/渔民/抽奖/烧烤/摆渡）的只读导出坐标中选出距离当前角色最近的唯一激活锚点，
-- 防止相邻设施或 BodyScale 放大交互半径后出现多个气泡叠字误触。
local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local ZoneMarkers = require("common.zone_markers")
local ViewUtil = require("client.views.view_util")

local InteractPromptArbiter = {}

---@type { name: string, base_radius: number, rank: integer }[]|nil
local cached_facilities = nil

--- 构建全图 5 类设施的扁平配置清单并缓存，避免心跳热路径重复遍历配置与分配临时表。
---@return { name: string, base_radius: number, rank: integer }[]
local function facility_list()
  if cached_facilities then return cached_facilities end
  local list = {}
  local function add(name, base_radius, rank)
    if type(name) == "string" and name ~= "" and type(base_radius) == "number" then
      list[#list + 1] = { name = name, base_radius = base_radius, rank = rank }
    end
  end
  for _, stand in ipairs((GameCfg.Shop and GameCfg.Shop.Stands) or {}) do
    add(stand.AnchorName, GameCfg.Shop.Radius, 1)
  end
  for _, npc in ipairs((GameCfg.Interact and GameCfg.Interact.Fishermen) or {}) do
    for _, name in ipairs(npc.AnchorNames or {}) do
      add(name, GameCfg.Interact.Fisherman.Radius, 2)
    end
  end
  for _, name in ipairs((GameCfg.Lottery and GameCfg.Lottery.machine_anchors and GameCfg.Lottery.machine_anchors()) or {}) do
    add(name, GameCfg.Lottery.Radius, 3)
  end
  for _, point in ipairs((GameCfg.Grill and GameCfg.Grill.Points) or {}) do
    add(point.AnchorName, GameCfg.Grill.Radius, 4)
  end
  for _, route in ipairs((GameCfg.Ferry and GameCfg.Ferry.Routes) or {}) do
    if route.Outbound then add(route.Outbound.AnchorName, route.Outbound.Radius, 5) end
    if route.Return then add(route.Return.AnchorName, route.Return.Radius, 5) end
  end
  cached_facilities = list
  return list
end

--- 在全图 5 类交互设施中选出距离当前角色最近的唯一激活锚点名。
--- 按各设施基础半径乘当前角色 BodyScale 交互半径倍率判入圈，平距按 shop < fisherman < lottery < grill < ferry 决胜。
---@param position any
---@param character any
---@return string|nil
function InteractPromptArbiter.nearest_anchor(position, character)
  if position == nil or not ZoneMarkers.ready then
    return nil
  end
  local positions = ZoneMarkers.anchor_positions
  if type(positions) ~= "table" then
    return nil
  end
  local scale_factor = BodyScale.interaction_radius(character, 1)
  local best_name, best_dist_sq, best_rank = nil, math.huge, 99
  for _, entry in ipairs(facility_list()) do
    local center = positions[entry.name]
    if center ~= nil then
      local dist_sq = ViewUtil.distance_sq_xz(position, center)
      if dist_sq ~= nil then
        local radius = entry.base_radius * scale_factor
        if dist_sq <= radius * radius then
          if dist_sq < best_dist_sq - 1e-9
              or (math.abs(dist_sq - best_dist_sq) <= 1e-9
                and (entry.rank < best_rank or (entry.rank == best_rank and entry.name < tostring(best_name)))) then
            best_name, best_dist_sq, best_rank = entry.name, dist_sq, entry.rank
          end
        end
      end
    end
  end
  return best_name
end

--- 判断目标锚点是否拥有当前跨设施互斥提示权；未就绪、名称非法或导出表缺锚点一律拒绝。
---@param position any
---@param character any
---@param anchor_name string|nil
---@return boolean
function InteractPromptArbiter.is_exclusive(position, character, anchor_name)
  if type(anchor_name) ~= "string" or anchor_name == "" then
    return false
  end
  if not ZoneMarkers.ready then
    return false
  end
  local positions = ZoneMarkers.anchor_positions
  if type(positions) ~= "table" or positions[anchor_name] == nil then
    return false
  end
  return InteractPromptArbiter.nearest_anchor(position, character) == anchor_name
end

return InteractPromptArbiter
