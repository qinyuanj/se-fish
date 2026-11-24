-- 服务端 ability_system 官方包单向输出叶子投影层（ADR-0032 §3 / #297-A2）：
--   1. 角色就绪时单向创建并挂载能力管理器（ManagerPreset），装配 InitialAbilities
--      （CdTime / CastTime / 锚点预设与属性覆盖，经可选回调 attach_anchor 挂接）；
--   2. 将 player_tree 的 can_act 守卫以回调形式注入施法门控（零反向依赖 server.ability_api）；
--   3. 角色更换或树销毁时在 s:on_cleanup 中对称停止全部已装配技能并销毁能力管理器；
--   4. 若管理器脚本首帧尚未就绪，依托 spoke_clock.on_frame 托管重试（随 on_cleanup 自动退订，零协程泄漏）。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块，零新增 CreateUnit 建点。

local game_cfg = require("common.game_cfg")

local ability_leaf = {}

local DEFAULT_RETRY_INTERVAL = 0.1
local DEFAULT_RETRY_COUNT = 50

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function make_vec3(v)
  return Vector3.New(v.x or 0, v.y or 0, v.z or 0)
end

local function default_ability_api()
  return require("server.packages.ability_system.api")
end

local function default_create_asset(preset_key)
  local world = game:GetService("World")
  return world:CreateAsset(preset_key)
end

local function report_error(opts, user_id, msg)
  if type(opts.on_error) == "function" then
    opts.on_error(msg)
  else
    print("[ability_leaf]", user_id, msg)
  end
end

local function safe_destroy(unit)
  if unit == nil then
    return
  end
  pcall(function() unit:Destroy() end) -- 角色已销毁时引擎可能已连带回收能力管理器或锚点
end

local function character_readable(character)
  if not is_object(character) then
    return false
  end
  local ok = pcall(function() return character:GetChildren() end) -- 兼容引擎 userdata 角色销毁后不可读
  return ok
end

local function apply_anchor_attributes(anchor, attrs, preset_key, opts, user_id)
  if type(attrs) ~= "table" then
    return true
  end
  for key, value in pairs(attrs) do
    local written_val = value
    if type(value) == "table" then
      written_val = make_vec3(value)
    end
    local ok, err = pcall(anchor.SetAttribute, anchor, key, written_val)
    if not ok then
      report_error(opts, user_id, "锚点属性覆盖失败: " .. tostring(preset_key) .. " " .. tostring(key) .. " " .. tostring(err))
      return false
    end
  end
  return true
end

local function create_and_attach_anchor(ability_script, entry, create_asset, opts, user_id)
  local ok_create, assets = pcall(create_asset, entry.Anchor)
  local anchor = ok_create and type(assets) == "table" and assets[1] or nil
  if not anchor then
    report_error(opts, user_id, "锚点预设创建失败: " .. tostring(entry.Anchor))
    return nil
  end
  local ok_parent, parent_err = pcall(function() anchor.Parent = ability_script end)
  if not ok_parent then
    safe_destroy(anchor)
    report_error(opts, user_id, "锚点挂载失败: " .. tostring(parent_err))
    return nil
  end
  if not apply_anchor_attributes(anchor, entry.AnchorAttributes, entry.Anchor, opts, user_id) then
    safe_destroy(anchor)
    return nil
  end
  if type(opts.attach_anchor) == "function" then
    local ok_attach, attached = pcall(opts.attach_anchor, anchor, entry.AnchorBehavior)
    if not ok_attach or attached == false then
      safe_destroy(anchor)
      report_error(opts, user_id, "锚点行为挂接失败: " .. tostring(ok_attach and entry.AnchorBehavior or attached))
      return nil
    end
  end
  return anchor
end

local function try_equip_entry(ability_api, character, entry, create_asset, opts, user_id)
  if not character_readable(character) then
    return false, "character-unreadable"
  end
  local ok_add, ability_script = pcall(ability_api.AddAbility, character, entry.AssetId, entry.Index)
  if not ok_add or not ability_script then
    return false, "not-ready"
  end
  if entry.CdSec ~= nil then
    local ok_cd, err_cd = pcall(ability_script.SetAttribute, ability_script, "CdTime", entry.CdSec)
    if not ok_cd then
      report_error(opts, user_id, "设置 CdTime 失败: " .. tostring(err_cd))
    end
  end
  if entry.CastSec ~= nil then
    local ok_cast, err_cast = pcall(ability_script.SetAttribute, ability_script, "CastTime", entry.CastSec)
    if not ok_cast then
      report_error(opts, user_id, "设置 CastTime 失败: " .. tostring(err_cast))
    end
  end
  local anchor = nil
  if entry.Anchor and entry.Anchor ~= "" then
    anchor = create_and_attach_anchor(ability_script, entry, create_asset, opts, user_id)
  end
  return true, ability_script, anchor
end

--- 读取 player_tree 的 can_act 守卫结果（树已销毁时一律拒绝施法）。
---@param player_tree table
---@return boolean
function ability_leaf.can_act_for(player_tree)
  if type(player_tree) ~= "table" then
    return false
  end
  if type(player_tree.is_disposed) == "function" and player_tree:is_disposed() then
    return false
  end
  local can_act = player_tree.memos and player_tree.memos.can_act
  if can_act and type(can_act.now) == "function" then
    return can_act:now() == true
  end
  return true
end

local function unit_matches_player_tree(unit, player_tree)
  if not is_object(unit) or type(player_tree) ~= "table" then
    return false
  end
  if unit == player_tree.player then
    return true
  end
  local char_sig = player_tree.states and player_tree.states.character
  local cur_char = char_sig and char_sig:now() or nil
  if cur_char ~= nil and unit == cur_char then
    return true
  end
  local ok_uid, uid = pcall(function() return unit.UserId end) -- 兼容引擎 userdata 单位读取 UserId
  if ok_uid and uid ~= nil and uid == player_tree.user_id then
    return true
  end
  return false
end

--- 生成可注入外部施法门控的 can_act 守卫函数（仅拦截归属该玩家树的角色/玩家）。
---@param player_tree table
---@return fun(unit: any, ability_index?: number): boolean
function ability_leaf.make_cast_guard(player_tree)
  return function(unit, _ability_index)
    if unit == nil or unit_matches_player_tree(unit, player_tree) then
      return ability_leaf.can_act_for(player_tree)
    end
    return true
  end
end

--- 受 can_act 守卫门控的单向施法辅助入口。
---@param player_tree table
---@param ability_index number
---@param release_point? any
---@param release_dir? any
---@param release_target? any
---@param opts? { ability_api?: table }
---@return boolean ok, string|nil err
function ability_leaf.cast_ability(player_tree, ability_index, release_point, release_dir, release_target, opts)
  opts = type(opts) == "table" and opts or {}
  if not ability_leaf.can_act_for(player_tree) then
    return false, "cannot-act"
  end
  local char_sig = player_tree.states and player_tree.states.character
  local character = char_sig and char_sig:now() or nil
  if not is_object(character) then
    return false, "no-character"
  end
  local ability_api = opts.ability_api or default_ability_api()
  local ok, result, err = pcall(
    ability_api.CastAbility,
    character,
    ability_index,
    release_point,
    release_dir,
    release_target
  )
  if not ok then
    return false, tostring(result)
  end
  return result == true, err
end

--- 在 player_tree 树底挂载 ability_system 纯输出叶子投影。
---@param s table EffectBuilder
---@param player_tree table
---@param opts? { ability_api?: table, create_asset?: fun(preset: string): table, attach_anchor?: fun(anchor: any, behavior: string): boolean, register_cast_guard?: fun(guard: fun(unit: any, index?: number): boolean): (fun()|nil), unregister_cast_guard?: fun(guard: fun(unit: any, index?: number): boolean), manager_preset?: string, initial_abilities?: table[], retry_interval?: number, retry_count?: number, on_error?: fun(msg: string) }
function ability_leaf.mount(s, player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local ability_api = opts.ability_api or default_ability_api()
  local create_asset = type(opts.create_asset) == "function" and opts.create_asset or default_create_asset
  local manager_preset = opts.manager_preset or game_cfg.Ability.ManagerPreset
  local initial_abilities = opts.initial_abilities or game_cfg.Ability.InitialAbilities or {}
  local retry_interval = opts.retry_interval or DEFAULT_RETRY_INTERVAL
  local retry_count = opts.retry_count or DEFAULT_RETRY_COUNT
  local user_id = player_tree and player_tree.user_id

  local guard = ability_leaf.make_cast_guard(player_tree)

  return s:effect("Leaf:AbilityScope", function(as)
    -- 1. 注入 can_act 施法守卫，并在树销毁时对称反注册。
    if type(opts.register_cast_guard) == "function" then
      local unregister = opts.register_cast_guard(guard)
      as:on_cleanup(function()
        if type(unregister) == "function" then
          pcall(unregister) -- 外部守卫容器可能已随服关闭释放
        elseif type(opts.unregister_cast_guard) == "function" then
          pcall(opts.unregister_cast_guard, guard) -- 外部守卫容器可能已随服关闭释放
        end
      end)
    end

    -- 2. 角色作用域：挂载技能管理器 + 装配初始技能 + 角色更换/树销毁对称停止并销毁。
    as:effect("Leaf:AbilityManagerScope", function(cs)
      local char_sig = player_tree.states and player_tree.states.character
      if not char_sig then
        return
      end
      local character = cs:d(char_sig)
      if not is_object(character) then
        return
      end

      local ok_create, assets = pcall(create_asset, manager_preset)
      local manager = ok_create and type(assets) == "table" and assets[1] or nil
      if not manager then
        report_error(opts, user_id, "技能管理器预设创建失败: " .. tostring(manager_preset))
        return
      end

      local ok_parent, parent_err = pcall(function() manager.Parent = character end)
      if not ok_parent then
        safe_destroy(manager)
        report_error(opts, user_id, "技能管理器挂载失败: " .. tostring(parent_err))
        return
      end

      local equipped_indices = {}
      local pending = {}
      local cancelled = false

      for _, entry in ipairs(initial_abilities) do
        if type(entry) == "table" and type(entry.AssetId) == "string" and entry.AssetId ~= "" then
          local ok_eq = try_equip_entry(ability_api, character, entry, create_asset, opts, user_id)
          if ok_eq then
            if entry.Index ~= nil then
              equipped_indices[#equipped_indices + 1] = entry.Index
            end
          else
            pending[#pending + 1] = {
              entry = entry,
              attempts = 1,
              next_at = (player_tree.clock and player_tree.clock.now() or 0) + retry_interval,
            }
          end
        end
      end

      -- 首帧未就绪的技能：通过 spoke_clock.on_frame 托管重试，角色离开或树销毁时自动退订。
      if #pending > 0 and player_tree.clock and player_tree.clock.on_frame then
        cs:subscribe(player_tree.clock.on_frame, function(frame)
          if cancelled or #pending == 0 then
            return
          end
          local now = frame and frame.now or player_tree.clock.now()
          for i = #pending, 1, -1 do
            local item = pending[i]
            if now >= item.next_at - 1e-9 then
              item.attempts = item.attempts + 1
              local ok_eq = try_equip_entry(ability_api, character, item.entry, create_asset, opts, user_id)
              if ok_eq then
                if item.entry.Index ~= nil then
                  equipped_indices[#equipped_indices + 1] = item.entry.Index
                end
                table.remove(pending, i)
              elseif item.attempts >= retry_count then
                report_error(opts, user_id, "装备技能超时: " .. tostring(item.entry.AssetId))
                table.remove(pending, i)
              else
                item.next_at = now + retry_interval
              end
            end
          end
        end)
      end

      cs:on_cleanup(function()
        cancelled = true
        pending = {}
        for _, index in ipairs(equipped_indices) do
          if type(ability_api.StopAbility) == "function" then
            pcall(ability_api.StopAbility, character, index) -- 角色已销毁时官方包可能已先行反注册管理器
          end
        end
        safe_destroy(manager)
      end)
    end)
  end)
end

return ability_leaf
