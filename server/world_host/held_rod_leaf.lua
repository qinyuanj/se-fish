-- 服务端左手持竿 / 手持外观纯输出叶子投影（ADR-0032 §3、§4 / #297-A1a）：
-- 仅在树底消费 character 与 held_visual_item_id，经注入的 create_unit 单向创建挂点与视觉模型，

local GameCfg = require("common.game_cfg")

local HeldRodLeaf = {}

local function make_vec3(scale)
  return Vector3.New(scale.x, scale.y, scale.z)
end

local function make_color(rgba)
  return Color.New(rgba[1], rgba[2], rgba[3], rgba[4])
end

--- 解析当前应投影到左手的视觉物品 ID（鱼竿优先，其次手持带 Visual.Socket 的武器）。
---@param held table|nil
---@param selected_slot number|nil
---@param item_bar table|nil
---@return string|nil
function HeldRodLeaf.resolve_visual_item_id(held, selected_slot, item_bar)
  local slot = type(held) == "table" and held.kind == "slot" and held.slot or nil
  if type(held) ~= "table" or held.kind == nil then
    slot = selected_slot
  end
  local entry = slot and type(item_bar) == "table" and item_bar[slot] or nil
  local item_id = type(entry) == "table" and (entry.count or 0) > 0 and entry.itemId or nil
  local item = item_id and GameCfg.Items.Definitions[item_id] or nil
  if not item or item.Type ~= "鱼竿" then
    item_id = type(held) == "table" and held.kind == "weapon" and held.id or nil
    item = item_id and GameCfg.Items.Definitions[item_id] or nil
  end
  if item and item.Visual and item.Visual.Socket then
    return item_id
  end
  return nil
end

--- 单向创建左手挂点与视觉模型；失败时自动清理半成品并返回 nil, nil, err。
---@param create_unit fun(unit_type: string, props: table): any
---@param user_id any
---@param character any
---@param item_id string
---@return any mount, any model, string|nil err
function HeldRodLeaf.create_visual(create_unit, user_id, character, item_id)
  if type(create_unit) ~= "function" or character == nil or type(item_id) ~= "string" then
    return nil, nil, "invalid-args"
  end

  local item = GameCfg.Items.Definitions[item_id]
  if not item or not item.Visual or not item.Visual.Socket then
    return nil, nil, "no-visual"
  end

  local cfg = item.Type == "鱼竿" and GameCfg.Items.RodVisual or item.Visual
  local uid = tostring(user_id)

  local ok_mount, mount = pcall(create_unit, "SkeletalSocketMount", {
    Name = "HeldRodMount_" .. uid,
    Parent = character,
    SocketName = cfg.Socket,
  })
  if not ok_mount or not mount then
    return nil, nil, "mount-failed:" .. tostring(mount)
  end

  local ok_model, model = pcall(create_unit, "WorldUnit", {
    Name = "HeldRod_" .. uid,
    Parent = mount,
    RenderMeshId = cfg.Mesh,
    Scale = make_vec3(cfg.Scale),
    PhysicsActive = false,
    CanCollide = false,
    CanTouch = false,
    CanTrigger = false,
    CanQuery = false,
    ModelVisible = true,
    ModelColor1 = make_color(item.IconColor),
  })
  if not ok_model or not model then
    pcall(function() mount:Destroy() end) -- 创建模型失败后回收已创建的挂点，兼容挂点已失效
    return nil, nil, "model-failed:" .. tostring(model)
  end

  return mount, model, nil
end

---@param s table EffectBuilder
---@param player_tree table
---@param opts? table { create_unit?: function, on_error?: function }
function HeldRodLeaf.mount(s, player_tree, opts)
  opts = type(opts) == "table" and opts or {}

  return s:effect("Leaf:HeldRodProjection", function(es)
    local character_sig = player_tree.states and player_tree.states.character
    local item_sig = player_tree.memos and player_tree.memos.held_visual_item_id
    if not character_sig or not item_sig then
      return
    end

    local retry_sig = player_tree.states and player_tree.states.held_rod_retry
    if retry_sig then
      local _ = es:d(retry_sig)
    end

    local character = es:d(character_sig)
    local item_id = es:d(item_sig)
    player_tree._held_rod_failed = false
    if character == nil or type(item_id) ~= "string" then
      return
    end

    if type(opts.create_unit) ~= "function" then
      return
    end

    local mount, model, err = HeldRodLeaf.create_visual(opts.create_unit, player_tree.user_id, character, item_id)
    if not mount or not model then
      if err and err ~= "no-visual" and err ~= "invalid-args" then
        player_tree._held_rod_failed = true
        if type(opts.on_error) == "function" then
          opts.on_error("[HeldRodLeaf] 左手持竿投影失败: " .. tostring(err))
        else
          print("[HeldRodLeaf] 左手持竿投影失败", player_tree.user_id, tostring(err))
        end
      end
      return
    end

    es:on_cleanup(function()
      pcall(function() model:Destroy() end) -- 角色已销毁时引擎可能已连带回收子 Unit
      pcall(function() mount:Destroy() end) -- 角色已销毁时引擎可能已连带回收挂点
    end)
  end)
end

return HeldRodLeaf
