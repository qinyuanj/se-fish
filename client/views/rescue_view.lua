
local GameCfg = require("common.game_cfg")
local spoke = require("common.packages.spoke.api")
local ViewUtil = require("client.views.view_util")

local State = spoke.State

local RescueView = {}

local function rows_equals(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i].userId ~= b[i].userId then
      return false
    end
  end
  return true
end

local function is_downed_or_rescuing(phase)
  return phase == "downed" or phase == "rescuing"
end

local function read_player_user_id(player)
  if not ViewUtil.is_record(player) then
    return nil
  end
  local ok, user_id = pcall(function() return player.UserId end) -- 兼容 SE Player userdata 字段读取
  return ok and user_id or nil
end

local function read_player_phase(player)
  if not ViewUtil.is_record(player) then
    return nil
  end
  local ok, phase = pcall(function() return player.GetAttribute and player:GetAttribute("SurvivalPhase") or nil end) -- 兼容 SE Player userdata 属性读取
  return ok and phase or nil
end

local function read_player_position(player)
  if not ViewUtil.is_record(player) then
    return nil
  end
  local ok, pos = pcall(function() -- 兼容 SE Player/Character userdata 销毁瞬态坐标读取
    local character = player.Character
    return character and character.Position or nil
  end)
  return ok and pos or nil
end

function RescueView.create_state(label, options)
  options = options or {}
  return {
    rows = State.new(label, {}, rows_equals),
    get_players = options.get_players,
    get_local_player = options.get_local_player,
    is_squad_member = options.is_squad_member,
  }
end

local function collect_world_targets(shared, position)
  local list = {}
  local has_downed = false
  local me = type(shared.get_local_player) == "function" and shared.get_local_player() or nil
  local players = type(shared.get_players) == "function" and shared.get_players() or {}
  local range_sq = GameCfg.Rescue.Range * GameCfg.Rescue.Range
  for _, player in ipairs(players) do
    local user_id = read_player_user_id(player)
    local squad_owned = user_id ~= nil and type(shared.is_squad_member) == "function" and shared.is_squad_member(user_id)
    local phase = player ~= me and not squad_owned and read_player_phase(player) or nil
    if is_downed_or_rescuing(phase) then
      has_downed = true
      if position ~= nil then
        local target_pos = read_player_position(player)
        local dist_sq = target_pos ~= nil and ViewUtil.distance_sq_xz(position, target_pos) or nil
        if dist_sq ~= nil and dist_sq <= range_sq then
          list[#list + 1] = { userId = user_id, position = target_pos }
        end
      end
    end
  end
  return list, has_downed
end

local function collect_squad_targets(shared, party, position)
  local list = {}
  local has_downed = false
  if type(party) ~= "table" or party.state ~= "party" then
    return list, false
  end
  local me = type(shared.get_local_player) == "function" and shared.get_local_player() or nil
  local players = type(shared.get_players) == "function" and shared.get_players() or {}
  local by_id = {}
  for _, player in ipairs(players) do
    local user_id = read_player_user_id(player)
    if user_id ~= nil then
      by_id[user_id] = player
    end
  end
  local range_sq = GameCfg.Rescue.Range * GameCfg.Rescue.Range
  for _, row in ipairs(party.members or {}) do
    if not row.self and is_downed_or_rescuing(row.phase) then
      has_downed = true
      local target = by_id[row.userId]
      if target ~= nil and target ~= me and position ~= nil then
        local target_pos = read_player_position(target)
        local dist_sq = target_pos ~= nil and ViewUtil.distance_sq_xz(position, target_pos) or nil
        if dist_sq ~= nil and dist_sq <= range_sq then
          list[#list + 1] = { userId = row.userId, position = target_pos }
        end
      end
    end
  end
  return list, has_downed
end

function RescueView.driver_spec(shared, config)
  local mode = config.mode
  local driver_name = config.name
  return {
    name = driver_name,
    mount = function(scope, ctx)
      local watch_active = State.new(driver_name .. ".watch_active", false)

      local function refresh()
        local position = ctx.store.position:now()
        local list, has_downed
        if mode == "squad" then
          list, has_downed = collect_squad_targets(shared, ctx.store.party:now(), position)
        else
          list, has_downed = collect_world_targets(shared, position)
        end
        shared.rows:set(list)
        if watch_active:now() ~= has_downed then
          watch_active:set(has_downed)
        end
      end

      scope:effect(driver_name .. "Sync", function(es)
        if mode == "squad" then
          es:d(ctx.store.party)
        end
        es:d(ctx.store.position)
        es:d(ctx.clock.second)
        refresh()
      end)

      scope:phase(driver_name .. "WatchPhase", watch_active, function(ps)
        ps:subscribe(ctx.clock.on_frame, refresh)
      end)
    end,
  }
end

function RescueView.bubble_spec(shared, config)
  local key_prefix = config.key_prefix or ""
  local scene_kind = config.scene_kind
  local scene_prefix = config.scene_prefix
  local button_prefix = config.button_prefix
  local log_tag = config.log_tag
  local fail_label = config.fail_label or "抢救按钮创建失败"

  return {
    items = function(es)
      return es:d(shared.rows)
    end,
    key_of = function(row)
      return key_prefix .. tostring(row.userId)
    end,
    mount = function(scope, ctx, item_signal)
      local row = item_signal:now()
      local node = ViewUtil.create_anchor_scene_node(
        scope, ctx, row, GameCfg.Rescue.BubbleHeight, scene_kind, scene_prefix .. tostring(row.userId)
      )
      local ok, button = pcall(ctx.create_node, scope, "EUIButton", {
        Name = button_prefix .. tostring(row.userId),
        Parent = node,
        ButtonText = GameCfg.Rescue.PromptText,
        TouchEnabled = true,
      })
      if not ok then
        if node and type(node.Destroy) == "function" then
          node:Destroy()
        end
        print(log_tag .. " " .. fail_label, tostring(button))
        return
      end
      ctx.connect(scope, button.OnClicked, function()
        local latest = item_signal:now() or row
        local next_seq = ctx.services and ctx.services.next_seq
        local send = ctx.services and ctx.services.send_interact
        if type(send) == "function" then
          send({
            target = GameCfg.Rescue.Target,
            action = GameCfg.Rescue.Action,
            targetUserId = latest.userId,
            seq = type(next_seq) == "function" and next_seq() or 1,
          })
        end
      end)
    end,
  }
end

return RescueView
