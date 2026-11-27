local PlayerData = require('server.data.player_data')
local GameCfg = require('common.game_cfg')
local Number = require('common.number')
local PlayerDataHost = { SpokeHost = true }
local DataMap = {}

function PlayerDataHost:get_data_inst(player)
    local data = player and DataMap[player.UserId]
    if data and data.Player == player and data.inited and data.load_state == 'ready' then return data end
end

function PlayerDataHost:send_item_bar(player, forcePush)
    local data = self:get_data_inst(player)
    if not data then return false end
    if self.Vitals and self.Vitals.RefreshHeldDamage then self.Vitals:RefreshHeldDamage(player, data) end
    local tree = self.runtime and self.runtime:get_player_tree(player.UserId)
    if tree then
        return forcePush and self:sync_player_tree(player, true) or false
    end
    print('[PlayerDataHost] 缺少 PlayerTree，无法同步 ItemBarState', player and player.UserId)
    return false
end

function PlayerDataHost:sync_player_tree(player, forcePush)
    local tree = self.runtime and self.runtime:get_player_tree(player.UserId)
    local data = self:get_data_inst(player)
    if not tree or not data then return false end
    return tree:sync_from_data(data, forcePush and { force_push = true } or nil)
end

function PlayerDataHost:on_player_added(player)
    local current = DataMap[player.UserId]
    if current and current.Player == player then return end
    if current then self:on_player_removing(current.Player) end
    local data = PlayerData.new(player, function(owner, source)
        if self:get_data_inst(owner) == source then self:send_item_bar(owner) end
    end)
    DataMap[player.UserId] = data
    data:Init(self.Save ~= nil)
    if self.Save then self.Save:load_into(player, data) end
    self:send_item_bar(player)
end

function PlayerDataHost:on_player_removing(player)
    local data = DataMap[player.UserId]
    if data and data.Player == player then
        DataMap[player.UserId] = nil
        if self.Save then self.Save:save_leaving(player, data) end
        data:destroy()
        if self.Save then self.Save:release_session(player.UserId, player) end
    end
end

local function isPositiveInt(value)
    return Number.is_finite_number(value) and value == math.floor(value) and value >= 1
end

local function validActionValue(action, value, data)
    if action == 'SelectSlot' or action == 'DiscardSlot' or action == 'EatSlot' then
        return isPositiveInt(value) and value <= data:ItemBarCapacity()
    end
    if action == 'MoveToItemBar' then
        return isPositiveInt(value) and value <= data:BackpackCapacity()
    end
    if action == 'SelectBait' and value == nil then return true end
    return type(value) == 'string' and data:HasBait(value)
end

local function eatBait(mgr, player, data, value)
    if mgr.Vitals and not mgr.Vitals:can_eat(player, value) then return end
    if data:EatBait(value) and mgr.Vitals then mgr.Vitals:eat(player, value) end
end

local function eatSlot(mgr, player, data, value)
    if not mgr.Vitals then return end
    local slot = data.data.selected_slot
    local entry = value == slot and data.data.containers[GameCfg.Items.ContainerId.ItemBar][slot]
    if not entry or entry.count <= 0 or not mgr.Vitals:can_eat(player, entry.itemId) then return end
    local cooked = GameCfg.Items.cook_rate(entry)
    local itemId = data:EatSlot(slot)
    if itemId then mgr.Vitals:eat(player, itemId, cooked) end
end

-- ===== 拆分前 PlayerDataHost:operate 体内的闭包：提到模块级，依赖经 ctx 显式传入 =====
-- ctx 承载一次操作的固定依赖（host/player/data/payload 与 op/weapon/slot）；
-- 拆分前 upvalue 捕获的 entry / dropApi / drop / willDrop 变成 ctx 的字段。
-- 对外方法名与签名不变，调用方仍走 host:operate(player, data, payload)。

local function operate_ctx(host, player, data, payload)
    return {
        host = host,
        player = player,
        data = data,
        payload = payload,
        op = payload.op,
        weapon = payload.weapon,
        slot = payload.slot,
    }
end

-- 回执：把结果按 ItemBarResult 推给该玩家（拆分前的 finish）。
local function finish(ctx, result, operation)
    if operation then result.operation = operation end
    _G.REUtil:get_re('ItemBarResult'):FireClient(ctx.player, result)
end

-- 拒绝回执：只带原因，op 由调用方在需要时补。
local function deny(ctx, reason)
    finish(ctx, { ok = false, reason = reason })
end

local function world_of(host)
    local runtime = host.runtime
    return runtime and runtime:get_world()
end

-- 是否还有丢弃额度（拆分前的 reserveDrop，保留接缝供后续按服务端库存判定）。
local function reserve_drop()
    return true, nil
end

-- 丢弃参数：世界是否能接住（drop_api）、日志用的落地条目（drop）、是否真会丢（will_drop）。
local function discard_context(ctx, entry)
    if ctx.op ~= 'discard' then return end
    local world = world_of(ctx.host)
    ctx.drop_api = world ~= nil and type(world.try_drop) == 'function'
    ctx.drop = entry and { itemId = entry.itemId, mult = entry.mult, cooked = entry.cooked, slot = ctx.slot } or nil
    local held = ctx.data.extra.inventory.selection.held
    ctx.will_drop = held.kind == 'slot' and held.slot == ctx.slot
end

-- 校验 op / 武器 / 格位，取好格位记录与丢弃参数（拆分前 operate 的前半段）。
local function prepare_operation(ctx)
    local data = ctx.data
    if ctx.op ~= 'eat' and ctx.op ~= 'discard' and ctx.op ~= 'attack' then
        deny(ctx, 'unknown-op')
        return false
    end
    if ctx.op == 'attack' then
        if type(ctx.weapon) ~= 'string' or data:WeaponCount(ctx.weapon) < 1 then
            deny(ctx, 'bad-weapon')
            return false
        end
        return true
    end
    if not isPositiveInt(ctx.slot) or ctx.slot > data:ItemBarCapacity() then
        deny(ctx, 'bad-slot')
        return false
    end
    ctx.entry = data.data.containers[GameCfg.Items.ContainerId.ItemBar][ctx.slot]
    discard_context(ctx, ctx.entry)
    return true
end

-- 操作前置：攻击只校验武器，其它操作要求格位有货，吃还要求 Vitals 允许。
local function precheck(ctx)
    if ctx.op == 'attack' then return true end
    local entry = ctx.entry
    if not entry or entry.count <= 0 then
        deny(ctx, 'empty')
        return false
    end
    if ctx.op == 'eat' and ctx.host.Vitals and not ctx.host.Vitals:can_eat(ctx.player, entry.itemId) then
        deny(ctx, 'cannot-eat')
        return false
    end
    return true
end

-- 落地丢弃：真会丢时要求世界能接住，失败只记录不阻断已落账的操作。
local function commit_drop(ctx)
    if ctx.op ~= 'discard' or not ctx.will_drop then return true end
    local world = world_of(ctx.host)
    if not world or type(world.try_drop) ~= 'function' then return false end
    local ok = world:try_drop(ctx.player, GameCfg.Items.ContainerId.ItemBar, ctx.slot)
    if not ok then
        print('[PlayerDataHost] 丢弃未落到地面', ctx.player.UserId, tostring(ctx.drop and ctx.drop.itemId))
    end
    return ok
end

-- 副作用：吃东西结算饥饿/熟度，属性道具应用成长。
local function settle_effects(ctx, result)
    local host, player = ctx.host, ctx.player
    if ctx.op == 'eat' and result.itemId and result.action ~= 'potion' and host.Vitals then
        host.Vitals:eat(player, result.itemId, result.cooked)
    end
    local apply = host.Ability and (host.Ability.apply_growth or host.Ability.apply_body_scale)
    if result.action == 'potion' and apply then
        local ok, applied = pcall(apply, host.Ability, player)
        if not ok or not applied.Ok then
            print('[PlayerDataHost] 成长应用失败', player.UserId, tostring(applied))
        end
    end
end

local function transform_attack(ctx, target, held)
    if held.kind == 'weapon' and held.id == ctx.weapon then return nil, 'combat-pending' end
    if not target:HoldWeapon(ctx.weapon) then return nil, 'bad-weapon' end
    return { ok = true, op = 'attack', held = true }
end

local function discard_held(ctx, entry)
    if not ctx.drop_api then return nil, 'drop-unavailable' end
    return { ok = true, op = 'discard', held = false, itemId = entry.itemId }
end

-- 属性道具：占用一次限购额度后从物品栏移除。
local function eat_potion(target, slot, entry)
    local limit = GameCfg.Items.PotionLimits[entry.itemId]
    local count = target.extra.growth.potions[entry.itemId] or 0
    if limit and count >= limit then return nil, 'potion-capped' end
    target.extra.growth.potions[entry.itemId] = count + 1
    target:SelectSlot(slot)
    target:UpdateData(function(d)
        d.containers[GameCfg.Items.ContainerId.ItemBar][slot] = nil
    end, true)
    return { ok = true, op = 'eat', held = false, itemId = entry.itemId, action = 'potion' }
end

local function eat_held(ctx, target, slot, entry)
    local definition = GameCfg.Items.Definitions[entry.itemId]
    if definition and definition.Type == '属性道具' then return eat_potion(target, slot, entry) end
    target:SelectSlot(slot)
    local itemId = target:EatSlot(slot)
    if not itemId then return nil, 'empty' end
    return { ok = true, op = 'eat', held = false, itemId = itemId, cooked = GameCfg.Items.cook_rate(entry) }
end

-- 已选中该格位时的三种走向：丢弃、吃属性道具、吃普通食物。
local function transform_held(ctx, target)
    local slot = ctx.slot
    local entry = target.data.containers[GameCfg.Items.ContainerId.ItemBar][slot]
    if not entry or entry.count <= 0 then return nil, 'empty' end
    if ctx.op == 'discard' then return discard_held(ctx, entry) end
    return eat_held(ctx, target, slot, entry)
end

-- 把一次操作应用到目标数据上：攻击换武器、换选格位、或对已选格位做动作。
local function transform(ctx, target)
    local held = target.extra.inventory.selection.held
    if ctx.op == 'attack' then return transform_attack(ctx, target, held) end
    if held.kind ~= 'slot' or held.slot ~= ctx.slot then
        if not target:HoldSlot(ctx.slot) then return nil, 'empty' end
        return { ok = true, op = ctx.op, held = true }
    end
    return transform_held(ctx, target)
end

-- 重放路径：请求已在存档里执行过，直接把记录的结果回给客户端。
local function run_replay(ctx, operation)
    ctx.host.Save:execute(ctx.player, ctx.data, operation, function() return nil, 'expired' end,
        function(written, result)
            if written then finish(ctx, result) else deny(ctx, tostring(result)) end
        end)
end

-- 落账路径：先写存档，再补丢弃与副作用，最后回执。
local function run_committed(ctx, operation)
    local accepted, failure = ctx.host.Save:execute(ctx.player, ctx.data, operation,
        function(target) return transform(ctx, target) end,
        function(written, result)
            if not written then return deny(ctx, tostring(result)) end
            if not commit_drop(ctx) then return finish(ctx, { ok = false, op = 'discard', reason = 'drop-rejected' }) end
            settle_effects(ctx, result)
            finish(ctx, result)
        end)
    if not accepted then deny(ctx, tostring(failure)) end
end

-- Save 路径：取请求号 → 解析请求 → 重放或落账（拆分前 operate 里的 Save 分支）。
local function run_with_save(ctx)
    local request_id = ctx.payload.operation
    if request_id ~= nil and type(request_id) ~= 'table' then return deny(ctx, 'bad-operation') end
    if request_id == nil then request_id = ctx.payload.seq end
    local operation, mode = ctx.host.Save:resolve_request(ctx.player, ctx.data, 'operate:' .. ctx.op, request_id)
    if not operation then return deny(ctx, tostring(mode)) end
    if mode ~= 'replay' and not precheck(ctx) then return end
    if mode == 'replay' then return run_replay(ctx, operation) end
    if not reserve_drop() then return end
    run_committed(ctx, operation)
end

-- 无 Save 路径：校验 → 预留 → 应用 → 丢弃/副作用 → 回执。
local function run_direct(ctx)
    if not precheck(ctx) then return end
    if not reserve_drop() then return end
    local result, reason = transform(ctx, ctx.data)
    if not result then return finish(ctx, { ok = false, op = ctx.op, reason = reason }) end
    if not commit_drop(ctx) then return finish(ctx, { ok = false, op = 'discard', reason = 'drop-rejected' }) end
    settle_effects(ctx, result)
    finish(ctx, result)
end

function PlayerDataHost:operate(player, data, payload)
    local ctx = operate_ctx(self, player, data, payload)
    if not prepare_operation(ctx) then return end
    if self.Save then
        run_with_save(ctx)
        return
    end
    run_direct(ctx)
end

local function notifyEquippedBait(mgr, player, method, value)
    if method ~= 'SelectBait' or value == nil or not mgr.Quest then return end
    mgr.next_fact_id = (mgr.next_fact_id or 0) + 1
    mgr.Quest:notify('EquipBait', player, { itemId = value,
        eventId = 'bait:' .. tostring(player.UserId) .. ':' .. tostring(mgr.next_fact_id) })
end

--- 物品栏动作表：请求动作名到数据方法的映射。
local ITEM_BAR_ACTIONS = {
    SelectSlot = 'SelectSlot',
    SelectBait = 'SelectBait',
    EatBait = 'EatBait',
    EatSlot = 'EatSlot',
    DiscardSlot = 'DiscardSlot',
    MoveToItemBar = 'MoveToItemBar',
}

--- 拾取/丢弃通道的限频检查。
---@param player table 玩家
---@return boolean 是否通过
local function item_bar_recd_ok(player)
    return not _G.REUtil:check_recd(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec)
end

--- 拾取/丢弃通道要用的世界。
---@param host table 玩家数据宿主
---@return table? 世界
local function item_bar_world(host)
    local runtime = host.runtime
    return runtime and runtime:get_world() or nil
end

--- 宿主没有统一入口时的拾取/丢弃兜底接口。
local WORLD_ITEM_FALLBACKS = {
    Pickup = { method = 'try_pickup', run = function(world, player, payload) world:try_pickup(player, payload.value) end },
    Drop = { method = 'try_drop', run = function(world, player, payload) world:try_drop(player, payload.container, payload.index) end },
}

--- 拾取/丢弃分发：宿主有统一入口时走入口，否则按动作走兜底接口。
---@param world table 世界
---@param action string 动作
---@param player table 玩家
---@param payload table 请求载荷
local function dispatch_world_item_action(world, action, player, payload)
    if type(world.handle_item_bar_action) == 'function' then
        world:handle_item_bar_action(player, payload, true)
        return
    end
    local fallback = WORLD_ITEM_FALLBACKS[action]
    if not fallback or type(world[fallback.method]) ~= 'function' then return end
    fallback.run(world, player, payload)
end

--- 物品栏请求：限频后经 PlayerTree 统一同步推送。
---@param host table 玩家数据宿主
local function bind_item_bar_request(host)
    _G.REUtil:get_re('RequestItemBar').OnServerEvent:Connect(function(player)
        if _G.REUtil:check_recd(player, 'RequestItemBar', GameCfg.Items.ActionCooldownSec) then return end
        -- 统一经 send_item_bar 走 PlayerTree 同步推送
        host:send_item_bar(player, true)
    end)
end

--- 移动物品栏槽位：校验两端容器与正整数槽位后落数据。
---@param host table 玩家数据宿主
---@param player table 玩家
---@param data table 玩家数据
---@param payload table 请求载荷
local function apply_item_bar_move_slot(host, player, data, payload)
    local ids = GameCfg.Items.ContainerId
    local from, index, target, slot = payload.from, payload.index, payload.target, payload.slot
    local valid = (from == ids.ItemBar or from == ids.Backpack)
        and (target == ids.ItemBar or target == ids.Backpack)
        and isPositiveInt(index)
        and isPositiveInt(slot)
    if not valid then return end
    if not item_bar_recd_ok(player) then return end
    if data:MoveSlot(from, index, target, slot) then host:send_item_bar(player) host:sync_player_tree(player) end
end

--- 打开操作面板：限频后交给 operate 结算。
---@param host table 玩家数据宿主
---@param player table 玩家
---@param data table 玩家数据
---@param payload table 请求载荷
local function apply_item_bar_operate(host, player, data, payload)
    if not item_bar_recd_ok(player) then return end
    host:operate(player, data, payload)
end

--- 动作表内的直接调用：限频、参数校验后落数据并同步。
---@param host table 玩家数据宿主
---@param player table 玩家
---@param data table 玩家数据
---@param action string 请求动作
---@param payload table 请求载荷
local function apply_item_bar_action(host, player, data, action, payload)
    local method = type(action) == 'string' and ITEM_BAR_ACTIONS[action]
    if not method then return end
    local value = payload.value
    if not validActionValue(action, value, data) then return end
    if not item_bar_recd_ok(player) then return end
    if method == 'EatBait' then
        eatBait(host, player, data, value)
        host:sync_player_tree(player)
        return
    end
    if method == 'EatSlot' then
        eatSlot(host, player, data, value)
        host:sync_player_tree(player)
        return
    end
    if data[method](data, value) then
        host:send_item_bar(player)
        host:sync_player_tree(player)
        notifyEquippedBait(host, player, method, value)
    end
end

function PlayerDataHost:start()
    bind_item_bar_request(self)
    _G.REUtil:get_re('ItemBarAction').OnServerEvent:Connect(function(player, payload)
        local data = self:get_data_inst(player)
        if not data or type(payload) ~= 'table' then return end
        local action = payload.action
        if action == 'Pickup' or action == 'Drop' then
            local world = item_bar_recd_ok(player) and item_bar_world(self)
            if world then dispatch_world_item_action(world, action, player, payload) end
            return
        end
        if action == 'MoveSlot' then
            apply_item_bar_move_slot(self, player, data, payload)
            return
        end
        if action == 'Operate' then
            apply_item_bar_operate(self, player, data, payload)
            return
        end
        apply_item_bar_action(self, player, data, action, payload)
    end)
end

return PlayerDataHost
