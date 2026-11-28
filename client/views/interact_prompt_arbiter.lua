-- 跨设施交互气泡互斥仲裁（ADR-0013 / #410）：
-- 在全图 5 类设施（商店/渔民/抽奖/烧烤/摆渡）的只读导出坐标中选出距离当前角色最近的唯一激活锚点，
-- 防止相邻设施或 BodyScale 放大交互半径后出现多个气泡叠字误触。
local BodyScale = require("common.body_scale")
local GameCfg = require("common.game_cfg")
local ZoneMarkers = require("common.zone_markers")
local ViewUtil = require("client.views.view_util")

local InteractPromptArbiter = {}

--- 在全图 5 类交互设施中选出距离当前角色最近的唯一激活锚点名。
--- 按各设施基础半径乘 BodyScale 判入圈，平距按 shop < fisherman < lottery < grill < ferry 决胜。
---@param position any
---@param character any
---@return string|nil
function InteractPromptArbiter.nearest_anchor(position, character)
  if position == nil or not ZoneMarkers.ready then
    return nil
  end
  local best_name, best_dist_sq, best_rank = nil, math.huge, 99
  local function consider(name, base_radius, rank)
    if type(name) ~= "string" or name == "" then return end
    local center = ZoneMarkers.anchor_position(name)
    if not center then return end
    local dist_sq = ViewUtil.distance_sq_xz(position, center)
    if dist_sq == nil then return end
    local radius = BodyScale.interaction_radius(character, base_radius)
    if dist_sq > radius * radius then return end
    if dist_sq < best_dist_sq - 1e-9
        or (math.abs(dist_sq - best_dist_sq) <= 1e-9
          and (rank < best_rank or (rank == best_rank and name < tostring(best_name)))) then
      best_name, best_dist_sq, best_rank = name, dist_sq, rank
    end
  end
  for _, stand in ipairs((GameCfg.Shop and GameCfg.Shop.Stands) or {}) do
    consider(stand.AnchorName, GameCfg.Shop.Radius, 1)
  end
  for _, npc in ipairs((GameCfg.Interact and GameCfg.Interact.Fishermen) or {}) do
    for _, name in ipairs(npc.AnchorNames or {}) do
      consider(name, GameCfg.Interact.Fisherman.Radius, 2)
    end
  end
  for _, name in ipairs((GameCfg.Lottery and GameCfg.Lottery.machine_anchors and GameCfg.Lottery.machine_anchors()) or {}) do
    consider(name, GameCfg.Lottery.Radius, 3)
  end
  for _, point in ipairs((GameCfg.Grill and GameCfg.Grill.Points) or {}) do
    consider(point.AnchorName, GameCfg.Grill.Radius, 4)
  end
  for _, route in ipairs((GameCfg.Ferry and GameCfg.Ferry.Routes) or {}) do
    if route.Outbound then consider(route.Outbound.AnchorName, route.Outbound.Radius, 5) end
    if route.Return then consider(route.Return.AnchorName, route.Return.Radius, 5) end
  end
  return best_name
end

--- 判断目标锚点是否拥有当前跨设施互斥提示权；非导出名或离线自定义测试坐标直接放行。
---@param position any
---@param character any
---@param anchor_name string|nil
---@param target_pos any
---@return boolean
function InteractPromptArbiter.is_exclusive(position, character, anchor_name, target_pos)
  if type(anchor_name) ~= "string" or anchor_name == "" then
    return true
  end
  if not ZoneMarkers.ready then
    return true
  end
  local baked = ZoneMarkers.anchor_position(anchor_name)
  if baked == nil then
    return true
  end
  if target_pos ~= nil then
    local drift_sq = ViewUtil.distance_sq_xz(baked, target_pos)
    if drift_sq ~= nil and drift_sq > 1e-4 then
      return true
    end
  end
  return InteractPromptArbiter.nearest_anchor(position, character) == anchor_name
end

return InteractPromptArbiter
