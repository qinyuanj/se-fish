-- 烧烤（烤肉架）行为的规则与回包共用件（L2 server.world_host）：从 player_grill.lua 原样搬出的纯函数，
-- 只读 common.game_cfg / common.grill_curve / common.body_scale 与 EngineRead.client_sender；
-- 函数体不调用 GrillBehavior、不改行为表，行为表用局部别名按原签名继续调用。
local BodyScale = require("common.body_scale")
local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local GrillCurve = require("common.grill_curve")
local ZoneMarkers = require("common.zone_markers")

local GrillRules = {}

local ITEM_BAR = GameCfg.Items.ContainerId.ItemBar
local BACKPACK = GameCfg.Items.ContainerId.Backpack

function GrillRules.cfg()
  return GameCfg.Grill
end

function GrillRules.flat_distance(a, b)
  if not a or not b then return math.huge end
  local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

function GrillRules.is_token(item_id)
  local exchanges = GameCfg.Content and GameCfg.Content.Exchanges or {}
  for _, chain in ipairs(exchanges) do
    if chain.EliteToken == item_id or chain.BossToken == item_id then return true end
  end
  return false
end

function GrillRules.grillable(entry)
  if type(entry) ~= "table" or (entry.count or 0) <= 0 then return false end
  local definition = GameCfg.Items.Definitions[entry.itemId]
  if not definition then return false end
  if definition.Type ~= "食物" and definition.Type ~= "极品食物" then return false end
  return GameCfg.Items.cook_rate(entry) == nil
end

function GrillRules.selected_entry(data)
  local items = data and data.data and data.data.containers and data.data.containers[ITEM_BAR]
  local slot = data and data.data and data.data.selected_slot
  local entry = slot and items and items[slot]
  if type(entry) == "table" and (entry.count or 0) > 0 then return slot, entry end
  return nil, nil
end

function GrillRules.place(data, item_id, mult, rate, select_slot)
  local pairs_ = {
    { ITEM_BAR, data:ItemBarCapacity() },
    { BACKPACK, data:BackpackCapacity() },
  }
  for _, pair in ipairs(pairs_) do
    local items = data.data.containers[pair[1]]
    for index = 1, pair[2] do
      local entry = items[index]
      if not entry or (entry.count or 0) <= 0 then
        items[index] = {
          itemId = item_id,
          count = 1,
          containerId = pair[1],
          mult = mult,
          cooked = rate,
          saved = rate and { k = rate } or nil,
        }
        if select_slot and pair[1] == ITEM_BAR then data.data.selected_slot = index end
        return true
      end
    end
  end
  return false
end

function GrillRules.ensure_recovery(data)
  if type(data.extra) ~= "table" then data.extra = {} end
  if type(data.extra.recovery) ~= "table" then data.extra.recovery = {} end
  return data.extra.recovery
end

-- 结果回包与状态推送只有频道与载荷字段不同，共用 EngineRead.client_sender 生成。
GrillRules.reply = EngineRead.client_sender({
  tag = "PlayerGrill", channel = "GrillResult", context = "PlayerGrill.reply", field = "action",
})

-- 推送当前烧烤状态到客户端，失败记录带上下文日志。
GrillRules.push_state = EngineRead.client_sender({
  tag = "PlayerGrill", channel = "GrillState", context = "PlayerGrill.push_state", field = "state", verb = "推送失败",
})

function GrillRules.fail(remote, player, reason, seq)
  return GrillRules.reply(remote, player, { seq = seq, ok = false, reason = reason })
end

-- 场景锚点缓存查找；只被 anchor_in_range 使用，留在模块内不导出。
-- 运行期唯一锚点来源是编辑态导出的只读几何表（ADR-0013 / #410）：
-- 烧烤点已开启静态优化，游戏内不再创建完整 Unit，不能再用 World 服务按名查单位。
local function find_anchor(name, cache)
  if cache[name] then return cache[name] end
  local position = ZoneMarkers.anchor_position(name)
  if not position then return nil end
  local anchor = { Name = name, Position = position }
  cache[name] = anchor
  return anchor
end

function GrillRules.anchor_in_range(player, cache)
  local character = player and player.Character
  local pos = character and character.Position
  if not pos then return nil, nil end
  for _, point in ipairs(GrillRules.cfg().Points or {}) do
    local anchor = find_anchor(point.AnchorName, cache)
    local center = anchor and anchor.Position
    local radius = BodyScale.interaction_radius(character, GrillRules.cfg().Radius) + (GrillRules.cfg().Slack or 0)
    if center and GrillRules.flat_distance(pos, center) <= radius then
      return point.AnchorName, anchor
    end
  end
  return nil, nil
end

function GrillRules.rate_of(session, now)
  if session.rate ~= nil then return session.rate end
  local elapsed = now - (session.startedAt or now)
  if GrillCurve.is_burnt(elapsed, GrillRules.cfg()) then return 0 end
  return GrillCurve.rate(elapsed, GrillRules.cfg())
end

function GrillRules.pending_rate(pending, now)
  if type(pending) ~= "table" then return nil end
  if pending.cooked ~= nil then return pending.cooked end
  if type(pending.at) ~= "number" then return nil end
  local elapsed = now - pending.at
  if GrillCurve.is_burnt(elapsed, GrillRules.cfg()) then return 0 end
  return GrillCurve.rate(elapsed, GrillRules.cfg())
end

return GrillRules
