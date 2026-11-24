-- 服务端 attr_rule 官方包单向输出叶子投影层（ADR-0032 §3 / #297-A2）：
-- 仅作为纯输出 Leaf Sink 挂载在 player_tree 树底：
--   1. 校验 GetAttrConfig，拒绝地图 Min/Max 钳制配置；
--   2. 角色作用域内 GetAttrUnit / EnsureAttrUnit，仅在新建（existing == nil）时于 on_cleanup 对称销毁；
--   3. 单向写入 PlayerBodyScale / PlayerMaxHealth / PlayerWalkSpeed / PlayerHunger
--      及 PlayerWeaponDamage_<melee|ranged|explosive> 四分量（Base/BaseExtra/Ratio/Bonus）；
--   4. 单向投影角色 SetScale、CameraDistance / InteractRange / BodyScaleCapped 与 character.Controller.WalkSpeed。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块。

local body_scale = require("common.body_scale")
local game_cfg = require("common.game_cfg")
local number = require("common.number")

local attr_leaf = {}

local COMPONENT_NAMES = { "Base", "BaseExtra", "Ratio", "Bonus" }
local WEAPON_KINDS = { "melee", "ranged", "explosive" }

local function is_object(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

local function make_vec3(x, y, z)
  return Vector3.New(x, y, z)
end

local function default_attr_api()
  return require("server.packages.attr_rule.api")
end

local function report_error(opts, user_id, msg)
  if type(opts.on_error) == "function" then
    opts.on_error(msg)
  else
    print("[attr_leaf]", user_id, msg)
  end
end

local function safe_destroy(unit)
  if unit == nil then
    return
  end
  pcall(function() unit:Destroy() end) -- 角色已销毁时引擎可能已连带回收属性单位
end

--- 校验属性键未被地图配置 Min/Max 钳制。
---@param attr_api table
---@param key string
---@return boolean ok, string|nil err
function attr_leaf.validate_config(attr_api, key)
  if type(attr_api) ~= "table" or type(attr_api.Funcs) ~= "table" then
    return false, "attr-api-invalid"
  end
  local get_cfg = attr_api.Funcs.GetAttrConfig
  if type(get_cfg) == "function" then
    local ok, config = pcall(get_cfg, key)
    if not ok then
      return false, "get-attr-config-failed:" .. tostring(config)
    end
    if config and (config.Min ~= nil or config.Max ~= nil) then
      return false, "业务属性键不允许地图钳制配置: " .. tostring(key)
    end
  end
  return true, nil
end

--- 单向写入单个业务属性键的四分量并返回投影后的最终值。
---@param attr_api table
---@param character any
---@param key string
---@param components table
---@return boolean ok, number|string value_or_err
function attr_leaf.project_components(attr_api, character, key, components)
  if not is_object(character) then
    return false, "no-character"
  end
  if type(components) ~= "table" then
    return false, "invalid-components:" .. tostring(key)
  end
  local cfg_ok, cfg_err = attr_leaf.validate_config(attr_api, key)
  if not cfg_ok then
    return false, cfg_err
  end
  local comp_types = attr_api.Enums and attr_api.Enums.AttrComponentType
  if type(comp_types) ~= "table" then
    return false, "attr-component-enum-missing"
  end
  for _, name in ipairs(COMPONENT_NAMES) do
    local ok_call, ok_set, err = pcall(
      attr_api.Funcs.SetAttrComponent,
      character,
      key,
      comp_types[name],
      components[name]
    )
    if not ok_call then
      return false, tostring(ok_set)
    end
    if not ok_set then
      return false, tostring(err)
    end
  end
  local ok_get, value = pcall(attr_api.Funcs.GetAttr, character, key)
  if not ok_get then
    return false, tostring(value)
  end
  return true, value
end

--- 单向投影角色体型缩放与派生属性（CameraDistance / InteractRange / BodyScaleCapped）。
---@param character any
---@param scale number
---@param capped boolean
---@return boolean ok, table|string derived_or_err
function attr_leaf.apply_body_presentation(character, scale, capped)
  if not is_object(character) then
    return false, "no-character"
  end
  local sanitized = body_scale.Sanitize(scale)
  local derived = body_scale.Derive(sanitized)
  local ok, err = pcall(function()
    character:SetScale(make_vec3(sanitized, sanitized, sanitized))
    character:SetAttribute("CameraDistance", derived.CameraDistance)
    character:SetAttribute("InteractRange", derived.InteractRange)
    character:SetAttribute("BodyScaleCapped", capped == true)
  end)
  if not ok then
    return false, tostring(err)
  end
  return true, derived
end

--- 单向投影角色控制器移速（character.Controller.WalkSpeed）。
---@param character any
---@param speed number
---@return boolean ok, string|nil err
function attr_leaf.apply_walk_speed(character, speed)
  if not is_object(character) then
    return false, "no-character"
  end
  local ok_ctrl, controller = pcall(function() return character.Controller end) -- 兼容引擎 userdata 角色未就绪时读取 Controller 异常
  if not ok_ctrl or not is_object(controller) then
    return false, "no-controller"
  end
  local clamped = number.IsFiniteNumber(speed) and math.max(0, speed) or 0
  local ok_write, err = pcall(function()
    controller.WalkSpeed = clamped
  end)
  if not ok_write then
    return false, tostring(err)
  end
  return true, nil
end

--- 在 player_tree 树底挂载 attr_rule 纯输出叶子投影。
---@param s table EffectBuilder
---@param player_tree table
---@param opts? { attr_api?: table, on_error?: fun(msg: string), on_projected?: fun(summary: table) }
function attr_leaf.mount(s, player_tree, opts)
  opts = type(opts) == "table" and opts or {}
  local attr_api = opts.attr_api or default_attr_api()
  local user_id = player_tree and player_tree.user_id

  return s:effect("Leaf:AttrUnitScope", function(cs)
    local char_sig = player_tree.states and player_tree.states.character
    if not char_sig then
      return
    end
    local character = cs:d(char_sig)
    if not is_object(character) then
      return
    end

    local ok_existing, existing = pcall(attr_api.Funcs.GetAttrUnit, character)
    if not ok_existing then
      report_error(opts, user_id, "GetAttrUnit 失败: " .. tostring(existing))
      return
    end

    local ok_ensure, unit, ensure_err = pcall(attr_api.Funcs.EnsureAttrUnit, character)
    if not ok_ensure or not unit then
      report_error(opts, user_id, "EnsureAttrUnit 失败: " .. tostring(ok_ensure and ensure_err or unit))
      return
    end

    local owned = (existing == nil)
    if owned then
      cs:on_cleanup(function()
        safe_destroy(unit)
      end)
    end

    cs:effect("Leaf:AttrProjection", function(ps)
      local memos = player_tree.memos or {}
      local attr_plan = memos.attr_plan and ps:d(memos.attr_plan)
      local weapon_comps = memos.weapon_damage_components and ps:d(memos.weapon_damage_components)
      if type(attr_plan) ~= "table" or type(attr_plan.Attributes) ~= "table" then
        return
      end

      local attrs = attr_plan.Attributes
      local summary = {
        ok = true,
        errors = {},
        values = {},
      }

      local function record_err(key, err)
        summary.ok = false
        local msg = tostring(key) .. ": " .. tostring(err)
        summary.errors[#summary.errors + 1] = msg
        report_error(opts, user_id, msg)
      end

      -- 1. 体型缩放（PlayerBodyScale）及角色视觉/交互范围投影
      if attrs.PlayerBodyScale then
        local ok, scale = attr_leaf.project_components(attr_api, character, "PlayerBodyScale", attrs.PlayerBodyScale)
        if not ok then
          record_err("PlayerBodyScale", scale)
        else
          local sanitized = body_scale.Sanitize(scale)
          summary.values.PlayerBodyScale = sanitized
          local capped = type(attr_plan.Body) == "table" and attr_plan.Body.Capped == true
          local ok_pres, derived_or_err = attr_leaf.apply_body_presentation(character, sanitized, capped)
          if not ok_pres then
            record_err("BodyPresentation", derived_or_err)
          else
            summary.body_derived = derived_or_err
          end
        end
      end

      -- 2. 血量上限（PlayerMaxHealth）
      if attrs.PlayerMaxHealth then
        local ok, max_hp = attr_leaf.project_components(attr_api, character, "PlayerMaxHealth", attrs.PlayerMaxHealth)
        if not ok then
          record_err("PlayerMaxHealth", max_hp)
        else
          summary.values.PlayerMaxHealth = math.max(1, math.min(game_cfg.Ability.body_scale.HealthMax, max_hp))
        end
      end

      -- 3. 移速（PlayerWalkSpeed）及 character.Controller.WalkSpeed 投影
      if attrs.PlayerWalkSpeed then
        local prior_speed
        local controller = character.Controller
        if controller then
          local ok_prior, current = pcall(function() return controller.WalkSpeed end)
          if ok_prior then prior_speed = current end
        end
        local ok, walk_speed = attr_leaf.project_components(attr_api, character, "PlayerWalkSpeed", attrs.PlayerWalkSpeed)
        if not ok then
          record_err("PlayerWalkSpeed", walk_speed)
          player_tree.walk_projection_rejected = true
          if controller and prior_speed ~= nil then
            pcall(function() controller.WalkSpeed = prior_speed end)
          end
        else
          player_tree.walk_projection_rejected = false
          local clamped_speed = number.IsFiniteNumber(walk_speed) and math.max(0, walk_speed) or 0
          summary.values.PlayerWalkSpeed = clamped_speed
          local ok_spd, spd_err = attr_leaf.apply_walk_speed(character, clamped_speed)
          if not ok_spd then
            record_err("WalkSpeed", spd_err)
          end
        end
      end

      -- 4. 饥饿度（PlayerHunger）
      if attrs.PlayerHunger then
        local ok, hunger = attr_leaf.project_components(attr_api, character, "PlayerHunger", attrs.PlayerHunger)
        if not ok then
          record_err("PlayerHunger", hunger)
        else
          summary.values.PlayerHunger = math.max(0, math.min(game_cfg.vitals.MaxHunger, math.floor(hunger)))
        end
      end

      -- 5. 三类武器伤害倍率（PlayerWeaponDamage_<kind>）
      if type(weapon_comps) == "table" then
        for _, kind in ipairs(WEAPON_KINDS) do
          local comp = weapon_comps[kind]
          if type(comp) == "table" then
            local key = "PlayerWeaponDamage_" .. kind
            local ok, value = attr_leaf.project_components(attr_api, character, key, comp)
            if not ok then
              record_err(key, value)
            else
              summary.values[key] = value
            end
          end
        end
      end

      if type(opts.on_projected) == "function" then
        opts.on_projected(summary)
      end
    end)
  end)
end

return attr_leaf
