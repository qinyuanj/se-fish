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

function PlayerDataHost:operate(player, data, payload)
    local function finish(result, operation)
        if operation then result.operation = operation end
        _G.REUtil:get_re('ItemBarResult'):FireClient(player, result)
    end
    local function worldOf()
        local runtime = self.runtime
        return runtime and runtime:get_world()
    end
    local op = payload.op
    local weapon = payload.weapon
    if op ~= 'eat' and op ~= 'discard' and op ~= 'attack' then
        finish({ ok = false, reason = 'unknown-op' })
        return
    end
    local slot = payload.slot
    local items = data.data.containers[GameCfg.Items.ContainerId.ItemBar]
    local entry
    if op == 'attack' then
        if type(weapon) ~= 'string' or data:WeaponCount(weapon) < 1 then
            finish({ ok = false, reason = 'bad-weapon' })
            return
        end
    else
        if not isPositiveInt(slot) or slot > data:ItemBarCapacity() then
            finish({ ok = false, reason = 'bad-slot' })
            return
        end
        entry = items[slot]
    end
    local dropApi = op == 'discard' and worldOf() and type(worldOf().try_drop) == 'function'
    local drop = op == 'discard' and entry
        and { itemId = entry.itemId, mult = entry.mult, cooked = entry.cooked, slot = slot } or nil
    local function precheck()
        if op == 'attack' then return true end
        if not entry or entry.count <= 0 then
            finish({ ok = false, reason = 'empty' })
            return false
        end
        if op == 'eat' and self.Vitals and not self.Vitals:can_eat(player, entry.itemId) then
            finish({ ok = false, reason = 'cannot-eat' })
            return false
        end
        return true
    end
    local heldNow = data.extra.inventory.selection.held
    local willDrop = op == 'discard' and heldNow.kind == 'slot' and heldNow.slot == slot
    local function reserveDrop()
        return true, nil
    end
    local function commitDrop()
        if op ~= 'discard' or not willDrop then return true end
        local world = worldOf()
        if not world or type(world.try_drop) ~= 'function' then return false end
        local ok = world:try_drop(player, GameCfg.Items.ContainerId.ItemBar, slot)
        if not ok then
            print('[PlayerDataHost] 丢弃未落到地面', player.UserId, tostring(drop and drop.itemId))
        end
        return ok
    end
    local function settleEffects(result)
        if op == 'eat' and result.itemId and result.action ~= 'potion' and self.Vitals then
            self.Vitals:eat(player, result.itemId, result.cooked)
        end
        local apply = self.Ability and (self.Ability.apply_growth or self.Ability.apply_body_scale)
        if result.action == 'potion' and apply then
            local ok, applied = pcall(apply, self.Ability, player)
            if not ok or not applied.Ok then
                print('[PlayerDataHost] 成长应用失败', player.UserId, tostring(applied))
            end
        end
    end
    local function transform(target)
        local held = target.extra.inventory.selection.held
        if op == 'attack' then
            if held.kind == 'weapon' and held.id == weapon then
                return nil, 'combat-pending'
            end
            if not target:HoldWeapon(weapon) then return nil, 'bad-weapon' end
            return { ok = true, op = 'attack', held = true }
        end
        if held.kind ~= 'slot' or held.slot ~= slot then
            if not target:HoldSlot(slot) then return nil, 'empty' end
            return { ok = true, op = op, held = true }
        end
        local heldEntry = target.data.containers[GameCfg.Items.ContainerId.ItemBar][slot]
        if not heldEntry or heldEntry.count <= 0 then return nil, 'empty' end
        if op == 'discard' then
            if not dropApi then return nil, 'drop-unavailable' end
            return { ok = true, op = 'discard', held = false, itemId = heldEntry.itemId }
        end
        local definition = GameCfg.Items.Definitions[heldEntry.itemId]
        if definition and definition.Type == '属性道具' then
            local limit = GameCfg.Items.PotionLimits[heldEntry.itemId]
            local count = target.extra.growth.potions[heldEntry.itemId] or 0
            if limit and count >= limit then return nil, 'potion-capped' end
            target.extra.growth.potions[heldEntry.itemId] = count + 1
            target:SelectSlot(slot)
            target:UpdateData(function(d)
                d.containers[GameCfg.Items.ContainerId.ItemBar][slot] = nil
            end, true)
            return { ok = true, op = 'eat', held = false, itemId = heldEntry.itemId, action = 'potion' }
        end
        target:SelectSlot(slot)
        local itemId = target:EatSlot(slot)
        if not itemId then return nil, 'empty' end
        return { ok = true, op = 'eat', held = false, itemId = itemId, cooked = GameCfg.Items.cook_rate(heldEntry) }
    end
    if self.Save then
        local requestId = payload.operation
        if requestId ~= nil and type(requestId) ~= 'table' then
            finish({ ok = false, reason = 'bad-operation' })
            return
        end
        if requestId == nil then requestId = payload.seq end
        local operation, mode = self.Save:resolve_request(player, data, 'operate:' .. op, requestId)
        if not operation then
            finish({ ok = false, reason = tostring(mode) })
            return
        end
        if mode ~= 'replay' and not precheck() then return end
        if mode == 'replay' then
            self.Save:execute(player, data, operation, function() return nil, 'expired' end,
                function(written, result)
                    if written then finish(result) else finish({ ok = false, reason = tostring(result) }) end
                end)
            return
        end
        local reserved, reservation = reserveDrop()
        if not reserved then return end
        local accepted, failure = self.Save:execute(player, data, operation, transform,
            function(written, result)
                if not written then
                    finish({ ok = false, reason = tostring(result) })
                    return
                end
                if not commitDrop() then
                    finish({ ok = false, op = 'discard', reason = 'drop-rejected' })
                    return
                end
                settleEffects(result)
                finish(result)
            end)
        if not accepted then
            finish({ ok = false, reason = tostring(failure) })
        end
        return
    end
    if not precheck() then return end
    local reserved, reservation = reserveDrop()
    if not reserved then return end
    local result, reason = transform(data)
    if not result then
        finish({ ok = false, op = op, reason = reason })
        return
    end
    if not commitDrop() then
        finish({ ok = false, op = 'discard', reason = 'drop-rejected' })
        return
    end
    settleEffects(result)
    finish(result)
end

local function notifyEquippedBait(mgr, player, method, value)
    if method ~= 'SelectBait' or value == nil or not mgr.Quest then return end
    mgr.next_fact_id = (mgr.next_fact_id or 0) + 1
    mgr.Quest:notify('EquipBait', player, { itemId = value,
        eventId = 'bait:' .. tostring(player.UserId) .. ':' .. tostring(mgr.next_fact_id) })
end

function PlayerDataHost:start()
    _G.REUtil:get_re('RequestItemBar').OnServerEvent:Connect(function(player)
        if _G.REUtil:check_recd(player, 'RequestItemBar', GameCfg.Items.ActionCooldownSec) then return end
        -- 统一经 send_item_bar 走 PlayerTree 同步推送
        self:send_item_bar(player, true)
    end)
    local actions = {
        SelectSlot = 'SelectSlot',
        SelectBait = 'SelectBait',
        EatBait = 'EatBait',
        EatSlot = 'EatSlot',
        DiscardSlot = 'DiscardSlot',
        MoveToItemBar = 'MoveToItemBar',
    }
    _G.REUtil:get_re('ItemBarAction').OnServerEvent:Connect(function(player, payload)
        local data = self:get_data_inst(player)
        if not data or type(payload) ~= 'table' then return end
        local action = payload.action
        if action == 'Pickup' or action == 'Drop' then
            if _G.REUtil:check_recd(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            local runtime = self.runtime
            local world = runtime and runtime:get_world()
            if not world then return end
            if type(world.handle_item_bar_action) == 'function' then
                world:handle_item_bar_action(player, payload, true)
            elseif action == 'Pickup' and type(world.try_pickup) == 'function' then
                world:try_pickup(player, payload.value)
            elseif action == 'Drop' and type(world.try_drop) == 'function' then
                world:try_drop(player, payload.container, payload.index)
            end
            return
        end
        if action == 'MoveSlot' then
            local ids = GameCfg.Items.ContainerId
            local from, index, target, slot = payload.from, payload.index, payload.target, payload.slot
            local valid = (from == ids.ItemBar or from == ids.Backpack)
                and (target == ids.ItemBar or target == ids.Backpack)
                and isPositiveInt(index)
                and isPositiveInt(slot)
            if not valid then return end
            if _G.REUtil:check_recd(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            if data:MoveSlot(from, index, target, slot) then self:send_item_bar(player) self:sync_player_tree(player) end
            return
        end
        if action == 'Operate' then
            if _G.REUtil:check_recd(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            self:operate(player, data, payload)
            return
        end
        local method = type(action) == 'string' and actions[action]
        if not method then return end
        local value = payload.value
        if not validActionValue(action, value, data) then return end
        if _G.REUtil:check_recd(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
        if method == 'EatBait' then
            eatBait(self, player, data, value)
            self:sync_player_tree(player)
            return
        end
        if method == 'EatSlot' then
            eatSlot(self, player, data, value)
            self:sync_player_tree(player)
            return
        end
        if data[method](data, value) then
            self:send_item_bar(player)
            self:sync_player_tree(player)
            notifyEquippedBait(self, player, method, value)
        end
    end)
end

return PlayerDataHost
