local GameCfg = require('common.game_cfg')
local SignalRouter = require('server.world_host.world_signal_router')

local Mgr = { AttackBonuses = {} }
local active_trees = {}
local isValidPlayer = SignalRouter.is_valid_player

local function syncTarget(self, target, data)
    local tree = isValidPlayer(target) and active_trees[target.UserId] or nil
    local hasLiveTree = tree ~= nil and tree.player == target and not tree:is_disposed()
    if self.PlayerData and type(self.PlayerData.send_item_bar) == 'function' then
        local synced = self.PlayerData:send_item_bar(target, true)
        if hasLiveTree and not self.PlayerData.Runtime and type(tree.sync_from_data) == 'function' then
            tree:sync_from_data(data, { force_push = true })
        end
        return synced
    elseif hasLiveTree and type(tree.sync_from_data) == 'function' then
        return tree:sync_from_data(data, { force_push = true })
    end
end

local AttackStep = 25
local BaseAttack = 0
for _, entry in ipairs(GameCfg.Ability.InitialAbilities) do
    if entry.AnchorBehavior == 'melee_hit' then
        BaseAttack = entry.AnchorAttributes.ABILITY_ANOSTATE_BULLET_DAMAGE
        break
    end
end

function Mgr:get_melee_damage(player, base)
    return base + (player and self.AttackBonuses[player.UserId] or 0)
end

function Mgr:add_attack(_, _, target)
    local previous = self.AttackBonuses[target.UserId] or 0
    if previous > math.maxinteger - AttackStep - BaseAttack then return false, '伤害数值已达到可表示范围' end
    self.AttackBonuses[target.UserId] = previous + AttackStep
    return true
end

function Mgr:on_player_removing(player)
    if not isValidPlayer(player) then return end
    self.AttackBonuses[player.UserId] = nil
end

local MaxItemCount = 99

local function isInt(n)
    return type(n) == 'number' and n == math.floor(n)
end

function Mgr:reply(player, payload)
    _G.REUtil:get_re('GMResult'):FireClient(player, payload)
end

function Mgr:resolve_target(player, target)
    if target == nil then return player end
    if not isInt(target) then return nil end
    for _, other in ipairs(game:GetService('Players'):GetPlayers()) do
        if other.UserId == target then return other end
    end
end

function Mgr:coin(data, payload)
    local amount = payload.amount
    if not isInt(amount) or amount == 0 then return false end
    if amount > 0 then return data:AddCoin(amount, nil, 'gm') end
    return data:SpendCoin(-amount, nil, 'gm')
end

function Mgr:Item(data, payload)
    local count = payload.count
    if type(payload.itemId) ~= 'string' or not GameCfg.Items.Definitions[payload.itemId] then
        return false, '物品 ID 不在白名单中'
    end
    if not isInt(count) or count < 1 or count > MaxItemCount then
        return false, '数量须为 1—99 的整数'
    end
    local ok, reason = data:GrantItem(payload.itemId, count)
    if not ok then return false, reason == 'full' and '空格不足，整批未发放' or '物品状态无效' end
    return true
end

function Mgr:set_health(_, payload, target)
    return self.Vitals ~= nil and self.Vitals:set_health(target, payload.value)
end

function Mgr:set_hunger(_, payload, target)
    return self.Vitals ~= nil and self.Vitals:set_hunger(target, payload.value)
end

function Mgr:next_fish(_, payload, target)
    local fishId = payload.fishId
    if type(fishId) ~= 'string' or not GameCfg.Fish[fishId] then
        return false, '鱼种 ID 不在白名单中'
    end
    if not self.cast then return false, '钓鱼管理器未就绪' end
    self.cast:SetNextFish(target, fishId)
    return true
end

local Actions = { Coin = 'coin', Item = 'Item', SetHealth = 'set_health', SetHunger = 'set_hunger',
    NextFish = 'next_fish', AddAttack = 'add_attack', GetAttack = 'get_attack',
    ApplyState = 'ApplyState', SaveState = 'SaveState', ReadState = 'ReadState',
    SelectSaveSlot = 'SelectSaveSlot', GetState = 'GetState' }

function Mgr:get_attack()
    return true
end

function Mgr:handle(player, payload)
    if not (GameCfg.Debug and GameCfg.Debug.Enabled) then
        print('[PlayerGM] 调试开关关闭，拒绝', player and player.UserId)
        self:reply(player, { ok = false, action = type(payload) == 'table' and payload.action or nil,
            reason = '调试开关已关闭' })
        return false
    end
    if type(payload) ~= 'table' then return false end
    local method = Actions[payload.action]
    local target = method and self:resolve_target(player, payload.target)
    local data = target and self.PlayerData and self.PlayerData:get_data_inst(target)
    if data and self.Save and (method == 'ApplyState' or method == 'SaveState'
        or method == 'ReadState' or method == 'SelectSaveSlot' or method == 'GetState') then
        local function finish(ok, reason)
            if ok and (method == 'ApplyState' or method == 'ReadState') then
                syncTarget(self, target, data)
            end
            self:reply(player, { ok = ok, action = payload.action, target = target.UserId,
                reason = reason, status = self.Save:status(target.UserId),
                snapshot = data:GetItemBarSnapshot() })
        end
        if method == 'GetState' then finish(true) return true end
        if method == 'ApplyState' then
            return self.Save:apply_temporary(target.UserId, data, payload, finish)
        end
        if method == 'SaveState' then
            local ok, reason = self.Save:save_explicit(target.UserId, data, finish)
            if not ok then finish(false, reason) end
            return ok
        end
        if method == 'ReadState' then
            local ok, reason = self.Save:read_explicit(target.UserId, data, finish)
            if not ok then finish(false, reason) end
            return ok
        end
        local ok, reason = self.Save:select_next_slot(target.UserId, payload.slot, finish)
        if not ok then finish(false, reason) end
        return ok
    end
    local ok, reason = false, '请求或目标无效'
    if data then ok, reason = self[method](self, data, payload, target) end
    print('[PlayerGM]', ok and '发放' or '拒绝', player and player.UserId, '->', target and target.UserId,
        tostring(payload.action), tostring(payload.amount or payload.itemId or payload.value or payload.scene or payload.fishId), tostring(payload.count or ''))
    if ok and method ~= 'next_fish' and method ~= 'add_attack' and method ~= 'get_attack' then
        syncTarget(self, target, data)
    end
    self:reply(player, { ok = ok, action = payload.action, target = target and target.UserId,
        damage = ok and (method == 'add_attack' or method == 'get_attack') and self:get_melee_damage(target, BaseAttack) or nil,
        reason = not ok and (reason or '请求未通过') or nil })
    return ok
end

function Mgr.configure(opts)
    Mgr.PlayerData, Mgr.Save, Mgr.cast, Mgr.Vitals = opts.player_data, opts.save, opts.cast, opts.vitals
end

function Mgr.mount(scope, player_tree, opts)
    local player = opts.player
    player_tree.gm = Mgr
    active_trees[player.UserId] = player_tree
    SignalRouter.bind_player(scope, _G.REUtil:get_re('GMAction').OnServerEvent, player, function(actor, payload)
        if _G.REUtil:check_recd(actor, 'GMAction', GameCfg.Items.ActionCooldownSec) then return end
        Mgr:handle(actor, payload)
    end)
    scope:on_cleanup(function()
        Mgr:on_player_removing(player)
        if active_trees[player.UserId] == player_tree then active_trees[player.UserId] = nil end
        if player_tree.gm == Mgr then player_tree.gm = nil end
    end)
end

return Mgr
