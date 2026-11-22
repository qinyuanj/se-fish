local GameCfg = require('common.GameCfg')
local REUtil = require('common.REUtil')

local Mgr = { States = {} }

local function cfg()
    return GameCfg.Survival
end

function Mgr:Now()
    self.World = self.World or game:GetService('World')
    return self.World:GetServerTime()
end

function Mgr:GetState(player)
    return player and self.States[player.UserId]
end

function Mgr:Phase(player)
    local state = self:GetState(player)
    return state and state.phase or nil
end

local function controllerOf(player)
    local character = player and player.Character
    return character and character.Controller
end

local function healthOf(player)
    local controller = controllerOf(player)
    local ok, health = pcall(function() return controller and controller.Health end)
    return ok and tonumber(health) or nil
end

function Mgr:SendState(state)
    local c = cfg()
    local payload = { phase = state.phase }
    if state.phase == 'downed' or state.phase == 'rescuing' then
        payload.endsAt = state.downedAt + c.DownedSec
    elseif state.phase == 'dead' then payload.endsAt = state.deadAt + c.DeadSec end
    if state.weakUntil then payload.weakUntil = state.weakUntil end
    if state.phase == 'rescuing' and state.rescue then
        payload.rescuerUserId = state.rescue.by.UserId
        payload.rescueEndsAt = state.rescue.endAt
    end
    if state.platform then payload.platformPending = state.platform.mode end
    local okAttr, attrErr = pcall(function() state.player:SetAttribute('SurvivalPhase', state.phase) end)
    if not okAttr then print('[MgrSurvival] 相位属性写入失败', state.player.UserId, tostring(attrErr)) end
    REUtil:GetRE('SurvivalState'):FireClient(state.player, payload)
    self:Mirror(state)
end

local function remaining(untilAt, now)
    return math.max(0, math.ceil(untilAt - now))
end

function Mgr:Mirror(state)
    local data = self.PlayerData and self.PlayerData:GetDataInst(state.player)
    local mark = data and data.Extra and data.Extra.survival
    if type(mark) ~= 'table' then return end
    local now, c = self:Now(), cfg()
    mark.dying = state.phase == 'downed'
    mark.dead = state.phase == 'dead'
    mark.dyingRemaining = mark.dying and remaining(state.downedAt + c.DownedSec, now) or 0
    mark.deadRemaining = mark.dead and remaining(state.deadAt + c.DeadSec, now) or 0
    mark.weakRemaining = math.ceil(self.Modifier:GetRemaining(state.player, 'weak'))
end

function Mgr:BeforeLeave(player)
    local state = self:GetState(player)
    if state and state.player == player then self:Mirror(state) end
end

function Mgr:EnterDowned(state, vitalState)
    state.phase = 'downed'
    self.Modifier:ClearTarget(state.player, true)
    state.episode = (state.episode or 0) + 1
    state.downedAt = self:Now()
    if self.Vitals then self.Vitals:SetControllerHealth(vitalState, 1) end
    if self.FishUnit and self.FishUnit.OnDied then
        local ok, err = pcall(self.FishUnit.OnDied, self.FishUnit, state.player)
        if not ok then print('[MgrSurvival] 濒死放鱼失败', state.player.UserId, tostring(err)) end
    end
    if self.ReelIn and self.ReelIn.Interrupt then
        local ok, err = pcall(self.ReelIn.Interrupt, self.ReelIn, state.player)
        if not ok then print('[MgrSurvival] 濒死断线失败', state.player.UserId, tostring(err)) end
    end
    print('[MgrSurvival] 濒死', state.player.UserId)
    self:SendState(state)
end

-- 同角色原地复活不会触发 CharacterAdded：通过唯一成长装配口重新套体型、上限与移速。
local function reapplyGrowth(self, state)
    if not self.SpeedWriter or not self.SpeedWriter.ApplyGrowth then return end
    local called, result = pcall(self.SpeedWriter.ApplyGrowth, self.SpeedWriter, state.player)
    if not called or not result or not result.Ok then
        print('[MgrSurvival] 复活成长重套失败', state.player.UserId,
            tostring(called and result and result.Error or result))
    end
end

function Mgr:RescueDowned(state, vitalState)
    if not state or state.phase ~= 'downed' or not self.Vitals then return false end
    state.rescue = nil
    local health = math.floor(self.Vitals:MaxHealthOf(state.player) * cfg().ReviveHealthPercent / 100)
    if not self.Vitals:ApplyRevive(vitalState, health) then return false end
    state.phase = 'alive'
    state.downedAt = nil
    reapplyGrowth(self, state)
    print('[MgrSurvival] 抢救', state.player.UserId, 'health=' .. tostring(health))
    self:SendState(state)
    return true
end

local function positionOf(player)
    local ok, pos = pcall(function() return player.Character and player.Character.Position end)
    if ok and pos then return pos end
end

local function horizontalDistance(a, b)
    if not a or not b then return math.huge end
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

function Mgr:PlayerByUserId(userId)
    local state = userId and self.States[userId]
    return state and state.player or nil
end

function Mgr:IsRescuing(player)
    local state = self:GetState(player)
    return state ~= nil and state.phase == 'rescuing'
end

function Mgr:CanRescue(target, rescuer)
    local state = self:GetState(target)
    if not state then return false, 'not-downed' end
    if state.phase == 'rescuing' or state.rescue then return false, 'busy' end
    if state.phase ~= 'downed' then return false, 'not-downed' end
    if state.platform then return false, 'platform-busy' end
    local rescuerState = self:GetState(rescuer)
    if not rescuerState then return false, 'no-rescuer' end
    if rescuerState.phase ~= 'alive' then return false, 'rescuer-downed' end
    local from, to = positionOf(rescuer), positionOf(target)
    if not from or not to then return false, 'no-position' end
    if horizontalDistance(from, to) > GameCfg.Rescue.Range then return false, 'too-far' end
    return true
end

function Mgr:BeginRescue(target, rescuer)
    local state = self:GetState(target)
    local can, reason = self:CanRescue(target, rescuer)
    if not can then return false, reason end
    local r = GameCfg.Rescue
    local from = positionOf(rescuer)
    local now = self:Now()
    state.rescue = { by = rescuer, startedAt = now, endAt = now + r.DurationSec,
        startPos = from, health = healthOf(rescuer) }
    state.phase = 'rescuing'
    print('[MgrSurvival] 抢救开始', target.UserId, rescuer.UserId)
    self:SendState(state)
    return true
end

function Mgr:CancelRescue(state, reason, silent)
    if not state or not state.rescue then return false end
    state.rescue = nil
    if state.phase == 'rescuing' then state.phase = 'downed' end
    print('[MgrSurvival] 抢救打断', state.player.UserId, tostring(reason))
    if not silent then self:SendState(state) end
    return true
end

function Mgr:FinishRescue(state)
    local rescue = state and state.rescue
    if not rescue or state.phase ~= 'rescuing' then return false end
    state.rescue = nil
    state.phase = 'downed'
    local vitalState = self.Vitals and self.Vitals:GetState(state.player)
    if not vitalState then self:SendState(state) return false end
    local ok = self.Vitals:Rescue(state.player, rescue.by) == true
    if not ok then self:SendState(state) end
    return ok
end

function Mgr:UpdateRescue(state, now)
    local rescue = state.rescue
    if not rescue then return false end
    local rescuer = rescue.by
    local rescuerState = self:GetState(rescuer)
    if not rescuerState or rescuerState.phase ~= 'alive' then return self:CancelRescue(state, 'rescuer-downed') end
    local r = GameCfg.Rescue
    local from, to = positionOf(rescuer), positionOf(state.player)
    if not from or not to then return self:CancelRescue(state, 'no-position') end
    if r.InterruptMoveMeters and r.InterruptMoveMeters > 0
        and horizontalDistance(from, rescue.startPos) > r.InterruptMoveMeters then
        return self:CancelRescue(state, 'moved')
    end
    if r.InterruptOnDamage then
        local health = healthOf(rescuer)
        if health and rescue.health and health < rescue.health then
            return self:CancelRescue(state, 'damaged')
        end
    end
    if now >= rescue.endAt then return self:FinishRescue(state) end
end

function Mgr:Hooks()
    return {
        LifeStatus = function(vitalState)
            local state = self.States[vitalState.player.UserId]
            return state and state.phase or nil
        end,
        CanTakeDamage = function(vitalState)
            local state = self.States[vitalState.player.UserId]
            if not state then return not vitalState.dead end
            return state.phase == 'alive'
        end,
        OnBeforeDamage = function(vitalState, amount)
            local state = self.States[vitalState.player.UserId]
            if not state or state.phase ~= 'alive' then return false end
            local health = healthOf(vitalState.player)
            if not health or health - amount > 0 then return false end
            self:EnterDowned(state, vitalState)
            return true
        end,
        Rescue = function(vitalState)
            local state = self.States[vitalState.player.UserId]
            if state and state.adrenalineFlying then return false end
            return self:RescueDowned(state, vitalState)
        end,
        OnDied = function(vitalState)
            local state = self.States[vitalState.player.UserId]
            if not state or state.phase == 'dead' then return end
            self.Modifier:ClearTarget(state.player, true)
            state.phase = 'dead'
            state.downedAt = nil
            state.deadAt = self:Now()
            state.engineDeath = true
            print('[MgrSurvival] 漏网死亡纳入状态机', state.player.UserId)
            self:SendState(state)
        end,
    }
end

local function refreshSpeed(self, state)
    local called, ok, err = pcall(self.SpeedWriter.RefreshMoveSpeed, self.SpeedWriter, state.player)
    if not called or ok == false then
        local reason = called and err or ok
        print('[MgrSurvival] 移速重算失败', state.player.UserId, tostring(reason))
        return false, tostring(reason)
    end
    return true
end

function Mgr:ApplyWeakSpeed(state)
    if self.SpeedWriter then return refreshSpeed(self, state) end
end

function Mgr:ApplyWeak(state, seconds)
    local ok, err = self.Modifier:Apply(nil, state.player, 'weak', seconds)
    if not ok then
        print('[MgrSurvival] 虚弱创建失败', state.player.UserId, tostring(err))
        state.pendingWeak = seconds
        return false, err
    end
    state.pendingWeak = nil
    state.weakUntil = self:Now() + self.Modifier:GetRemaining(state.player, 'weak')
    return true
end

function Mgr:ClearWeak(state)
    state.pendingWeak, state.weakUntil = nil, nil
    self.Modifier:Clear(state.player, 'weak')
    return self:ApplyWeakSpeed(state)
end

function Mgr:WeakRevive(state)
    if state.phase ~= 'dead' then return end
    local vitalState = self.Vitals and self.Vitals:GetState(state.player)
    if not vitalState then return end
    local c = cfg()
    local health = math.floor(self.Vitals:MaxHealthOf(state.player) * c.ReviveHealthPercent / 100)
    local minHunger = math.floor(GameCfg.Vitals.MaxHunger * c.ReviveHungerPercent / 100)
    if not self.Vitals:ApplyRevive(vitalState, health, minHunger) then return end
    state.phase = 'alive'
    state.deadAt = nil
    state.engineDeath = nil
    self:ApplyWeak(state, c.WeakSec)
    reapplyGrowth(self, state)
    print('[MgrSurvival] 虚弱复活', state.player.UserId, 'health=' .. tostring(health),
        'hunger=' .. tostring(vitalState.hunger))
    self:SendState(state)
end

function Mgr:TryRecover(state)
    if state.recoverFlying or not state.recovering then return end
    local player = state.player
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return end
    local operation, mode = self.Save:ResolveRequest(player, data, 'survival:recover', state.recoverId)
    if not operation then return end
    if mode == 'replay' then
        state.recovering = nil
        print('[MgrSurvival] 离线恢复重放命中', player.UserId)
        return
    end
    state.recoverFlying = true
    local accepted = self.Save:Execute(player, data, operation, function(draft)
        local mark = draft.Extra.survival
        mark.dying, mark.dead, mark.dyingRemaining, mark.deadRemaining = false, false, 0, 0
        mark.weakRemaining = cfg().WeakSec
        return { ok = true }
    end, function(written)
        if self.States[player.UserId] ~= state then return end
        state.recoverFlying = nil
        if not written then return end
        state.recovering = nil
        self:WeakRevive(state)
    end)
    if not accepted then state.recoverFlying = nil end
end

function Mgr:OnPlayerAdded(player)
    if not player or self.States[player.UserId] then return end
    local state = { player = player, phase = 'alive' }
    self.States[player.UserId] = state
    if player.CharacterAdded then
        state.added = player.CharacterAdded:Connect(function()
            if self.States[player.UserId] == state and state.weakUntil then self:ApplyWeakSpeed(state) end
        end)
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local mark = data and data.Extra and data.Extra.survival
    if type(mark) ~= 'table' then return end
    if mark.dying or mark.dead then
        self.RecoverSeq = (self.RecoverSeq or 0) + 1
        state.phase, state.deadAt, state.recovering = 'dead', self:Now(), true
        state.recoverId = self.RecoverSeq
        local vitalState = self.Vitals and self.Vitals:GetState(player)
        if vitalState then self.Vitals:SetControllerHealth(vitalState, 1) end
        print('[MgrSurvival] 离线时濒死 / 死亡，重进按虚弱复活', player.UserId)
        self:SendState(state)
        self:TryRecover(state)
    elseif type(mark.weakRemaining) == 'number' and mark.weakRemaining == mark.weakRemaining
        and mark.weakRemaining < math.huge and mark.weakRemaining > 0 then
        self:ApplyWeak(state, math.min(mark.weakRemaining, cfg().WeakSec))
        print('[MgrSurvival] 离线虚弱剩余', player.UserId, mark.weakRemaining)
        self:SendState(state)
    end
end

function Mgr:OnPlayerRemoving(player)
    local state = self:GetState(player)
    if not state or state.player ~= player then return end
    if state.added then state.added:Disconnect() end
    self.States[player.UserId] = nil
end

function Mgr:EnterDead(state, now)
    self:CancelRescue(state, 'timeout', true)
    self.Modifier:ClearTarget(state.player, true)
    state.phase = 'dead'
    state.downedAt = nil
    state.deadAt = now
    print('[MgrSurvival] 死亡', state.player.UserId)
    self:SendState(state)
end

function Mgr:Update()
    local now = self:Now()
    local c = cfg()
    for _, state in pairs(self.States) do
        if state.phase == 'rescuing' then
            if now - state.downedAt >= c.DownedSec then
                self:EnterDead(state, now)
            else
                self:UpdateRescue(state, now)
            end
        elseif state.phase == 'downed' and not state.adrenalineFlying and not state.platform
            and now - state.downedAt >= c.DownedSec then
            self:EnterDead(state, now)
        elseif state.phase == 'dead' and state.recovering then
            self:TryRecover(state)
        elseif state.phase == 'dead' and not state.platform then
            local due = now - state.deadAt >= c.DeadSec
            local engineRevived = false
            if state.engineDeath and self.Vitals then
                local vitalState = self.Vitals:GetState(state.player)
                local health = healthOf(state.player)
                engineRevived = vitalState ~= nil and vitalState.dead == false
                    or (health ~= nil and health > 1)
            end
            if due or engineRevived then self:WeakRevive(state) end
        elseif state.phase == 'alive' and state.pendingWeak then
            self:ApplyWeak(state, state.pendingWeak)
        elseif state.phase == 'alive' and state.weakUntil and self.Modifier:GetRemaining(state.player, 'weak') <= 0 then
            state.weakUntil = nil
            self:SendState(state)
        end
        if state.phase ~= 'alive' or state.weakUntil then self:Mirror(state) end
    end
end

function Mgr:Reply(player, payload)
    REUtil:GetRE('SurvivalResult'):FireClient(player, payload)
end

function Mgr:UseAdrenaline(player, payload)
    local seq = type(payload) == 'table' and payload.seq or nil
    local function fail(reason)
        self:Reply(player, { seq = seq, ok = false, reason = reason })
        return false
    end
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then
        return fail('invalid')
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self.Save then return fail('unavailable') end
    local operation, mode = self.Save:ResolveRequest(player, data, 'survival:adrenaline', seq)
    if mode == 'replay' then return fail('replay') end
    local state = self:GetState(player)
    if not state or state.phase ~= 'downed' then return fail('not-downed') end
    if state.adrenalineFlying then return fail('busy') end
    if state.platform then return fail('busy') end
    local itemId = cfg().AdrenalineItemId
    if data:ItemCount(itemId) < 1 then
        if self.Platform and self.Platform.OpenAdrenalineShop then
            local ok, err = pcall(self.Platform.OpenAdrenalineShop, self.Platform, player)
            if not ok then print('[MgrSurvival] 平台购买入口失败', player.UserId, tostring(err)) end
        end
        return fail('no-adrenaline')
    end
    if not operation then return fail(tostring(mode)) end
    local episode = state.episode
    state.adrenalineFlying = true
    local accepted, why = self.Save:Execute(player, data, operation, function(draft)
        if not draft:ConsumeItem(itemId) then return nil, 'no-adrenaline' end
        return { ok = true, seq = seq }
    end, function(written, result)
        if self.States[player.UserId] ~= state then return end
        state.adrenalineFlying = nil
        if not written then return fail(tostring(result)) end
        local vitalState = self.Vitals and self.Vitals:GetState(player)
        if state.phase ~= 'downed' or state.episode ~= episode or not vitalState
            or not self:RescueDowned(state, vitalState) then
            return fail('not-downed')
        end
        if self.PlayerData and self.PlayerData.SendItemBar then self.PlayerData:SendItemBar(player) end
        print('[MgrSurvival] 肾上腺素自救', player.UserId, operation.id)
        self:Reply(player, { seq = seq, ok = true })
    end)
    if not accepted then
        state.adrenalineFlying = nil
        return fail(why or 'pending')
    end
    return true
end

function Mgr:FullRevive(state, mode)
    if not state then return false end
    local fromDowned = state.phase == 'downed' or state.phase == 'rescuing'
    if not fromDowned and state.phase ~= 'dead' then return false end
    local vitalState = self.Vitals and self.Vitals:GetState(state.player)
    if not vitalState then return false end
    local minHunger = math.floor(GameCfg.Vitals.MaxHunger * cfg().ReviveHungerPercent / 100)
    if not self.Vitals:ApplyRevive(vitalState, self.Vitals:MaxHealthOf(state.player), minHunger) then return false end
    if fromDowned then
        state.rescue = nil
        state.downedAt = nil
    end
    state.phase = 'alive'
    state.deadAt = nil
    state.engineDeath = nil
    state.platform = nil
    if state.weakUntil then self:ClearWeak(state) end
    print('[MgrSurvival] 平台满血复活', state.player.UserId, tostring(mode))
    self:SendState(state)
    return true
end

function Mgr:ResumeCountdown(state, platform)
    local paused = math.max(0, self:Now() - platform.startedAt)
    if state.phase == 'dead' and state.deadAt then
        state.deadAt = state.deadAt + paused
    elseif (state.phase == 'downed' or state.phase == 'rescuing') and state.downedAt then
        state.downedAt = state.downedAt + paused
    end
    self:SendState(state)
end

function Mgr:PlatformRevive(player, payload)
    local seq = type(payload) == 'table' and payload.seq or nil
    local function fail(reason)
        self:Reply(player, { seq = seq, ok = false, action = 'FullRevive', reason = reason,
            text = reason == 'not_open' and GameCfg.Platform.NotOpenText or nil })
        return false
    end
    if type(payload) ~= 'table' then return false end
    if type(seq) ~= 'number' or seq ~= math.floor(seq) or seq < 1 or seq > 2147483647 then
        return fail('invalid')
    end
    local mode = payload.mode
    if mode ~= 'ad' and mode ~= 'goods' then return fail('invalid') end
    local state = self:GetState(player)
    if not state then return fail('not-revivable') end
    if state.phase ~= 'dead' and state.phase ~= 'downed' then return fail('not-revivable') end
    if state.phase == 'downed' and mode ~= 'ad' then return fail('not-dead') end
    if state.recovering then return fail('recovering') end
    if state.platform then return fail('busy') end
    if not self.Platform then return fail('unavailable') end
    local platform = { mode = mode, seq = seq, startedAt = self:Now(), episode = state.episode }
    local function onResult(outcome)
        if self.States[player.UserId] ~= state or state.platform ~= platform then return end
        state.platform = nil
        if outcome == 'success' and state.episode == platform.episode and self:FullRevive(state, mode) then
            self:Reply(player, { seq = seq, ok = true, action = 'FullRevive', mode = mode })
            return
        end
        if outcome == 'success' then
            print('[MgrSurvival] 平台复活成功回调未能结算（待 #148 对账）', player.UserId, mode)
        end
        self:ResumeCountdown(state, platform)
        self:Reply(player, { seq = seq, ok = false, action = 'FullRevive',
            reason = outcome == 'success' and 'not-revivable' or tostring(outcome) })
    end
    state.platform = platform
    local accepted, reason
    if mode == 'ad' then
        accepted, reason = self.Platform:ShowAd(player, 'revive', 'revive', onResult)
    else
        accepted, reason = self.Platform:Purchase(player, 'reviveFull', 'revive', onResult)
    end
    if not accepted then
        if state.platform == platform then state.platform = nil end
        return fail(reason or 'unavailable')
    end
    if state.platform == platform then
        print('[MgrSurvival] 平台复活流程开始，复活倒计时暂停（' .. state.phase .. '）', player.UserId, mode)
        self:SendState(state)
    end
    return true
end

local function distance(a, b)
    local ok, d = pcall(function()
        local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end)
    return ok and d or math.huge
end

function Mgr:CallHelp(player)
    local state = self:GetState(player)
    if not state or state.phase ~= 'downed' then return false end
    local c, now = cfg(), self:Now()
    if state.lastHelp and now - state.lastHelp < c.HelpCooldownSec then return false end
    state.lastHelp = now
    state.helpIndex = (state.helpIndex or 0) % #c.HelpCries + 1
    local origin = player.Character and player.Character.Position
    local re = REUtil:GetRE('SurvivalHelp')
    for _, other in pairs(self.States) do
        if other ~= state and other.player.Character
            and distance(origin, other.player.Character.Position) <= c.HelpRadius then
            re:FireClient(other.player, { userId = player.UserId, name = player.Name,
                text = c.HelpCries[state.helpIndex] })
        end
    end
    return true
end

function Mgr:OnAction(player, payload)
    if type(payload) ~= 'table' then return end
    if payload.action == 'UseAdrenaline' then
        if REUtil:CheckRECD(player, 'SurvivalAction', 0.2) then return end
        self:UseAdrenaline(player, payload)
    elseif payload.action == 'FullRevive' then
        if REUtil:CheckRECD(player, 'SurvivalAction', 0.2) then return end
        self:PlatformRevive(player, payload)
    elseif payload.action == 'CallHelp' then
        self:CallHelp(player)
    end
end

function Mgr:Start()
    local ok, world = pcall(function() return game:GetService('World') end)
    if ok then self.World = world end
    REUtil:GetRE('SurvivalAction').OnServerEvent:Connect(function(player, payload)
        self:OnAction(player, payload)
    end)
end

return Mgr
