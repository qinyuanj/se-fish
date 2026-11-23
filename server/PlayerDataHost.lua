local PlayerData = require('server.Data.PlayerData')
local GameCfg = require('common.GameCfg')
local PlayerDataHost = { SpokeHost = true }
local DataMap = {}

function PlayerDataHost:GetDataInst(player)
    local data = player and DataMap[player.UserId]
    if data and data.Player == player and data.Inited and data.LoadState == 'ready' then return data end
end

function PlayerDataHost:SendItemBar(player, forcePush)
    local data = self:GetDataInst(player)
    if not data then return end
    if self.Vitals and self.Vitals.RefreshHeldDamage then self.Vitals:RefreshHeldDamage(player, data) end
    local tree = self.Runtime and self.Runtime:get_player_tree(player.UserId)
    if tree then
        if forcePush then return self:SyncPlayerTree(player, true) end
        return false -- 普通变更由所属操作/事务同步，树底统一推送，禁止双通道。
    end
    _G.REUtil:GetRE('ItemBarState'):FireClient(player, data:GetItemBarSnapshot())
end

function PlayerDataHost:SyncPlayerTree(player, forcePush)
    local tree = self.Runtime and self.Runtime:get_player_tree(player.UserId)
    local data = self:GetDataInst(player)
    if not tree or not data then return false end
    return tree:sync_from_data(data, forcePush and { force_push = true } or nil)
end

function PlayerDataHost:OnPlayerAdded(player)
    local current = DataMap[player.UserId]
    if current and current.Player == player then return end
    if current then self:OnPlayerRemoving(current.Player) end
    local data = PlayerData.New(player, function(owner, source)
        if self:GetDataInst(owner) == source then self:SendItemBar(owner) end
    end)
    DataMap[player.UserId] = data
    data:Init(self.Save ~= nil)
    if self.Save then self.Save:LoadInto(player, data) end
    self:SendItemBar(player)
end

function PlayerDataHost:OnPlayerRemoving(player)
    local data = DataMap[player.UserId]
    if data and data.Player == player then
        DataMap[player.UserId] = nil
        if self.Save then self.Save:SaveLeaving(player, data) end
        data:Destroy()
        if self.Save then self.Save:ReleaseSession(player.UserId, player) end
    end
end

local function validActionValue(action, value, data)
    if action == 'SelectSlot' or action == 'DiscardSlot' or action == 'EatSlot' then
        return type(value) == 'number' and value == math.floor(value)
            and value >= 1 and value <= data:ItemBarCapacity()
    end
    if action == 'MoveToItemBar' then
        return type(value) == 'number' and value == math.floor(value)
            and value >= 1 and value <= data:BackpackCapacity()
    end
    if action == 'SelectBait' and value == nil then return true end
    return type(value) == 'string' and data:HasBait(value)
end

local function eatBait(mgr, player, data, value)
    if mgr.Vitals and not mgr.Vitals:CanEat(player, value) then return end
    if data:EatBait(value) and mgr.Vitals then mgr.Vitals:Eat(player, value) end
end

local function eatSlot(mgr, player, data, value)
    if not mgr.Vitals then return end
    local slot = data.Data.SelectedSlot
    local entry = value == slot and data.Data.Containers[GameCfg.Items.ContainerId.ItemBar][slot]
    if not entry or entry.count <= 0 or not mgr.Vitals:CanEat(player, entry.itemId) then return end
    local cooked = GameCfg.Items.CookRate(entry)
    local itemId = data:EatSlot(slot)
    if itemId then mgr.Vitals:Eat(player, itemId, cooked) end
end

function PlayerDataHost:Operate(player, data, payload)
    local function finish(result, operation)
        if operation then result.operation = operation end
        _G.REUtil:GetRE('ItemBarResult'):FireClient(player, result)
    end
    local function worldOf()
        local runtime = self.Runtime
        return runtime and runtime:get_world()
    end
    local op = payload.op
    local weapon = payload.weapon
    if op ~= 'eat' and op ~= 'discard' and op ~= 'attack' then
        finish({ ok = false, reason = 'unknown-op' })
        return
    end
    local slot = payload.slot
    local items = data.Data.Containers[GameCfg.Items.ContainerId.ItemBar]
    local entry
    if op == 'attack' then
        if type(weapon) ~= 'string' or data:WeaponCount(weapon) < 1 then
            finish({ ok = false, reason = 'bad-weapon' })
            return
        end
    else
        if type(slot) ~= 'number' or slot ~= math.floor(slot)
            or slot < 1 or slot > data:ItemBarCapacity() then
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
        if op == 'eat' and self.Vitals and not self.Vitals:CanEat(player, entry.itemId) then
            finish({ ok = false, reason = 'cannot-eat' })
            return false
        end
        return true
    end
    local heldNow = data.Extra.inventory.selection.held
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
            self.Vitals:Eat(player, result.itemId, result.cooked)
        end
        local apply = self.Ability and (self.Ability.ApplyGrowth or self.Ability.ApplyBodyScale)
        if result.action == 'potion' and apply then
            local ok, applied = pcall(apply, self.Ability, player)
            if not ok or not applied.Ok then
                print('[PlayerDataHost] 成长应用失败', player.UserId, tostring(applied))
            end
        end
    end
    local function transform(target)
        local held = target.Extra.inventory.selection.held
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
        local heldEntry = target.Data.Containers[GameCfg.Items.ContainerId.ItemBar][slot]
        if not heldEntry or heldEntry.count <= 0 then return nil, 'empty' end
        if op == 'discard' then
            if not dropApi then return nil, 'drop-unavailable' end
            return { ok = true, op = 'discard', held = false, itemId = heldEntry.itemId }
        end
        local definition = GameCfg.Items.Definitions[heldEntry.itemId]
        if definition and definition.Type == '属性道具' then
            local limit = GameCfg.Items.PotionLimits[heldEntry.itemId]
            local count = target.Extra.growth.potions[heldEntry.itemId] or 0
            if limit and count >= limit then return nil, 'potion-capped' end
            target.Extra.growth.potions[heldEntry.itemId] = count + 1
            target:SelectSlot(slot)
            target:UpdateData(function(d)
                d.Containers[GameCfg.Items.ContainerId.ItemBar][slot] = nil
            end, true)
            return { ok = true, op = 'eat', held = false, itemId = heldEntry.itemId, action = 'potion' }
        end
        target:SelectSlot(slot)
        local itemId = target:EatSlot(slot)
        if not itemId then return nil, 'empty' end
        return { ok = true, op = 'eat', held = false, itemId = itemId, cooked = GameCfg.Items.CookRate(heldEntry) }
    end
    if self.Save then
        local requestId = payload.operation
        if requestId ~= nil and type(requestId) ~= 'table' then
            finish({ ok = false, reason = 'bad-operation' })
            return
        end
        if requestId == nil then requestId = payload.seq end
        local operation, mode = self.Save:ResolveRequest(player, data, 'operate:' .. op, requestId)
        if not operation then
            finish({ ok = false, reason = tostring(mode) })
            return
        end
        if mode ~= 'replay' and not precheck() then return end
        if mode == 'replay' then
            self.Save:Execute(player, data, operation, function() return nil, 'expired' end,
                function(written, result)
                    if written then finish(result) else finish({ ok = false, reason = tostring(result) }) end
                end)
            return
        end
        local reserved, reservation = reserveDrop()
        if not reserved then return end
        local accepted, failure = self.Save:Execute(player, data, operation, transform,
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
    mgr.NextFactId = (mgr.NextFactId or 0) + 1
    mgr.Quest:Notify('EquipBait', player, { itemId = value,
        eventId = 'bait:' .. tostring(player.UserId) .. ':' .. tostring(mgr.NextFactId) })
end

function PlayerDataHost:Start()
    _G.REUtil:GetRE('RequestItemBar').OnServerEvent:Connect(function(player)
        local tree = self.Runtime and self.Runtime:get_player_tree(player.UserId)
        if tree then self:SyncPlayerTree(player, true) else self:SendItemBar(player, true) end
    end)
    local actions = {
        SelectSlot = 'SelectSlot',
        SelectBait = 'SelectBait',
        EatBait = 'EatBait',
        EatSlot = 'EatSlot',
        DiscardSlot = 'DiscardSlot',
        MoveToItemBar = 'MoveToItemBar',
    }
    _G.REUtil:GetRE('ItemBarAction').OnServerEvent:Connect(function(player, payload)
        local data = self:GetDataInst(player)
        if not data or type(payload) ~= 'table' then return end
        local action = payload.action
        if action == 'Pickup' or action == 'Drop' then
            if _G.REUtil:CheckRECD(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            local runtime = self.Runtime
            local world = runtime and runtime:get_world()
            if not world then return end
            if action == 'Pickup' and type(world.try_pickup) == 'function' then
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
                and type(index) == 'number' and index == math.floor(index) and index >= 1
                and type(slot) == 'number' and slot == math.floor(slot) and slot >= 1
            if not valid then return end
            if _G.REUtil:CheckRECD(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            if data:MoveSlot(from, index, target, slot) then self:SendItemBar(player) self:SyncPlayerTree(player) end
            return
        end
        if action == 'Operate' then
            if _G.REUtil:CheckRECD(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
            self:Operate(player, data, payload)
            return
        end
        local method = type(action) == 'string' and actions[action]
        if not method then return end
        local value = payload.value
        if not validActionValue(action, value, data) then return end
        if _G.REUtil:CheckRECD(player, 'ItemBarAction', GameCfg.Items.ActionCooldownSec) then return end
        if method == 'EatBait' then
            eatBait(self, player, data, value)
            self:SyncPlayerTree(player)
            return
        end
        if method == 'EatSlot' then
            eatSlot(self, player, data, value)
            self:SyncPlayerTree(player)
            return
        end
        if data[method](data, value) then
            self:SendItemBar(player)
            self:SyncPlayerTree(player)
            notifyEquippedBait(self, player, method, value)
        end
    end)
end

return PlayerDataHost
