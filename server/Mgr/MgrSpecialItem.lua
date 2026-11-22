local GameCfg = require('common.GameCfg')
local SpecialItem = require('common.SpecialItem')
local FlightPath = require('common.FlightPath')

local Mgr = { States = {}, PendingCleanup = {}, CleanupFailures = {} }
local CLEANUP_HISTORY_LIMIT = 16
local CLEANUP_RETRIES = 5

local function cfg()
    return GameCfg.Ability.SpecialItem
end

local function breathCfg()
    return cfg().Godzilla.Breath
end

local function zoneScene(zoneId)
    for _, zone in ipairs(GameCfg.Zones or {}) do
        if zone.Id == zoneId then return zone.Scene end
    end
end

local function inCorridor(origin, forward, pos, bc)
    local dx, dz = pos.x - origin.x, pos.z - origin.z
    local along = dx * forward.x + dz * forward.z
    if along < 0 or along > bc.Range then return false end
    local perp = math.abs(dx * forward.z - dz * forward.x)
    if perp > bc.Width then return false end
    if math.abs(pos.y - origin.y) > bc.Width then return false end
    return true
end

local function flatForward(rotation)
    local f = rotation and rotation.GetForward and rotation:GetForward() or nil
    local fx, fz = (f and f.x) or 0, (f and f.z) or 1
    local len = math.sqrt(fx * fx + fz * fz)
    if len < 1e-6 then return { x = 0, z = 1 } end
    return { x = fx / len, z = fz / len }
end

local function setGravity(character, enabled)
    local controller = character and character.Controller
    if not controller then return false, "no-controller" end
    return pcall(function() controller.GravityEnabled = enabled end)
end

function Mgr:Now()
    return game:GetService('World'):GetServerTime()
end

function Mgr:OnlinePlayers()
    return game:GetService('Players'):GetPlayers()
end

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('SpecialItemResult'):FireClient(player, payload)
end

function Mgr:Fail(player, action, reason)
    print('[MgrSpecialItem] 请求拒绝', player.UserId, action, tostring(reason))
    self:Reply(player, { ok = false, action = action, reason = reason })
    return false
end

function Mgr:SendState(player)
    local state = self.States[player.UserId]
    if not state then return end
    _G.REUtil:GetRE('SpecialItemState'):FireClient(player, {
        effect = not state.restoring and state.effect or nil,
        airborne = state.airborne,
        breathRemaining = SpecialItem.CooldownRemaining(state.lastBreathAt, self:Now(), breathCfg().CooldownSec),
    })
end

function Mgr:GetState(player)
    local state = self.States[player.UserId]
    if not state then
        state = { player = player, effect = nil, holding = false, airborne = false,
            gravityOff = false, flightY = nil, wingBindId = nil, skinApplied = false,
            lastBreathAt = nil, breath = nil }
        self.States[player.UserId] = state
    end
    return state
end

function Mgr:CanAct(player)
    return self.Vitals and self.Vitals:CanAct(player) == true or false
end

local function selectedItemId(data)
    local slot = data and data.Data and data.Data.SelectedSlot
    if type(slot) ~= 'number' then return nil end
    local bar = data.Data.Containers and data.Data.Containers[GameCfg.Items.ContainerId.ItemBar]
    local entry = bar and bar[slot]
    return entry and entry.itemId or nil
end


function Mgr:EngineCall(state, key, object, fn)
    state.failures = state.failures or {}
    local failure = state.failures[key]
    if failure and self:Now() < failure.nextAt then return false end
    local ok, result = pcall(fn)
    if ok and result ~= false then
        state.failures[key] = nil
        return true, result
    end
    if not failure then print('[MgrSpecialItem] 引擎操作失败', key, tostring(object), tostring(result)) end
    state.failures[key] = { object = object, error = result, nextAt = self:Now() + 1 }
    return false
end

function Mgr:Apply(player, state, effect)
    local character = player.Character
    local appearance = character and character.EggyAppearance
    if effect == 'wings' and cfg().Wings.AppearanceAssetId then
        local wings = cfg().Wings
        local ok, id = self:EngineCall(state, 'bind', appearance, function()
            return appearance:BindAppearance(wings.AppearanceAssetId, Enums.SkeletalSocketType[wings.Socket],
                Vector3.New(wings.Offset.x, wings.Offset.y, wings.Offset.z),
                Quaternion.Identity(), Vector3.New(1, 1, 1))
        end)
        if not ok or type(id) ~= 'number' then return false end
        state.wingBindId, state.appearance = id, appearance
    elseif effect == 'godzilla' and cfg().Godzilla.AppearanceAssetId then
        if not self:EngineCall(state, 'skin', appearance, function()
            appearance:SetAppearanceByAssetId(cfg().Godzilla.AppearanceAssetId)
        end) then return false end
        state.skinApplied, state.appearance = true, appearance
    else
        local visual = GameCfg.PlaceholderAssets.Special[effect]
        if visual then
            local world = game:GetService('World')
            local ok, mount = self:EngineCall(state, 'placeholderMount', character, function()
                return world:CreateUnit('SkeletalSocketMount', {
                    Name = 'SpecialPlaceholderMount_' .. tostring(player.UserId), Parent = character,
                    SocketName = visual.Socket,
                    SocketOffset = Vector3.New(visual.Offset.x, visual.Offset.y, visual.Offset.z),
                })
            end)
            if not ok or not mount then return false end
            local modelOk, model = self:EngineCall(state, 'placeholderModel', mount, function()
                return world:CreateUnit('WorldUnit', {
                    Name = 'SpecialPlaceholder_' .. effect, Parent = mount, RenderMeshId = visual.Mesh,
                    Scale = Vector3.New(visual.Scale.x, visual.Scale.y, visual.Scale.z),
                    PhysicsActive = false, CanCollide = false, CanTouch = false,
                    CanTrigger = false, CanQuery = false,
                })
            end)
            if not modelOk or not model then
                if self:EngineCall(state, 'placeholderUnmount', mount, function() mount:Destroy() end) then
                    state.placeholderMount = nil
                else
                    state.placeholderMount = mount
                end
                return false
            end
            state.placeholderMount = mount
            state.placeholderModel = model
        end
    end
    state.effect = effect
    return true
end

function Mgr:Gravity(player, state, enabled)
    local character = state.gravityCharacter or state.cleanupCharacter or player.Character
    local ok = self:EngineCall(state, 'gravity', character, function()
        local success, err = setGravity(character, enabled)
        if not success then error(err) end
    end)
    if ok then
        state.gravityOff = not enabled
        state.gravityCharacter = not enabled and character or nil
    end
    return ok
end

function Mgr:Restore(player, state)
    state.holding, state.airborne, state.flightY, state.breath = false, false, nil, nil
    state.flightGroundY = nil
    local character = state.cleanupCharacter or player.Character
    local appearance = state.appearance or (character and character.EggyAppearance)
    if state.placeholderModel then
        if self:EngineCall(state, 'placeholderDestroy', state.placeholderModel, function()
            state.placeholderModel:Destroy()
        end) then state.placeholderModel = nil end
    end
    if state.placeholderMount and not state.placeholderModel then
        if self:EngineCall(state, 'placeholderUnmount', state.placeholderMount, function()
            state.placeholderMount:Destroy()
        end) then state.placeholderMount = nil end
    end
    if state.wingBindId then
        if self:EngineCall(state, 'unbind', appearance, function()
            return appearance:UnbindAppearance(state.wingBindId)
        end) then state.wingBindId = nil end
    end
    if state.skinApplied then
        if self:EngineCall(state, 'reset', appearance, function() appearance:ResetAppearance() end) then
            state.skinApplied = false
        end
    end
    if state.gravityOff then self:Gravity(player, state, true) end
    if state.wingBindId or state.skinApplied or state.gravityOff or state.placeholderMount or state.placeholderModel then
        state.restoring = true
        return false
    end
    state.restoring, state.effect, state.appearance = false, nil, nil
    return true
end

function Mgr:Reconcile(player, state)
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local selected = selectedItemId(data)
    if state.suspendedItem and selected ~= state.suspendedItem then state.suspendedItem = nil end
    local desired = data and self:CanAct(player) and not state.suspendedItem and SpecialItem.Desired(selected) or nil
    if desired == state.effect and not state.restoring then return end
    if not self:Restore(player, state) then return end
    if desired and player.Character then self:Apply(player, state, desired) end
    self:SendState(player)
end


function Mgr:UpdateFlight(player, state, dt)
    local character = player.Character
    if not character or not character.Position then return end
    local wings = cfg().Wings
    if state.airborne and not state.holding and state.flightY
        and character.Position.y > state.flightY + wings.LandEpsilon then
        state.airborne = false
    end
    if not state.holding and not state.airborne then
        if state.gravityOff then self:Gravity(player, state, true) end
        state.flightY, state.flightGroundY = nil, nil
        return
    end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local scene = data and zoneScene(GameCfg.ResolveZoneId(data.Data.Zone))
    local bounds = scene and FlightPath.BoundsOf(scene, GameCfg.Ability.Flight)
    if not bounds then return end
    if not state.flightGroundY then state.flightGroundY = character.Position.y end
    bounds.GroundY = state.flightGroundY
    bounds.CeilingY = math.min(bounds.CeilingY, state.flightGroundY + bounds.MaxHeight)

    if not self:Gravity(player, state, false) then return end
    local y, airborne = SpecialItem.StepFlightY(wings,
        { Y = state.flightY or character.Position.y, Airborne = state.airborne },
        state.holding, dt, bounds)
    local cx, cz = SpecialItem.ClampXZ(bounds, character.Position.x, character.Position.z)
    pcall(function() character.Position = Vector3.New(cx, y, cz) end)
    state.flightY = y
    state.airborne = airborne
    if not airborne then
        self:Gravity(player, state, true)
        state.flightY, state.flightGroundY = nil, nil
    end
end


function Mgr:CastBreath(player)
    local state = self:GetState(player)
    if state.restoring or state.effect ~= 'godzilla' then return self:Fail(player, 'breath', 'not-godzilla') end
    if not self:CanAct(player) then return self:Fail(player, 'breath', 'not-alive') end
    local character = player.Character
    local pos = character and character.Position
    if not pos then return self:Fail(player, 'breath', 'no-character') end
    if not self.Vitals then return self:Fail(player, 'breath', 'no-vitals') end
    local now = self:Now()
    local bc = breathCfg()
    if SpecialItem.CooldownRemaining(state.lastBreathAt, now, bc.CooldownSec) > 0 then
        return self:Fail(player, 'breath', 'cooldown')
    end
    state.lastBreathAt = now
    self:MirrorCooldown(state, now)
    state.breath = {
        castAt = now, tick = 1,
        ledger = SpecialItem.NewBreathLedger(bc),
        origin = { x = pos.x, y = pos.y, z = pos.z },
        forward = flatForward(character.Rotation),
    }
    self:Reply(player, { ok = true, action = 'breath', endsAt = now + bc.DurationSec })
    self:SendState(player)
    return true
end

function Mgr:BreathTick(player, breath, tick)
    local bc = breathCfg()
    local hit = self.Vitals:NewHit(player, 'specialBreath')
    local function settle(target, key, pos)
        if pos and inCorridor(breath.origin, breath.forward, pos, bc) then
            local amount = SpecialItem.BreathHit(breath.ledger, key, tick)
            if amount then self.Vitals:ApplyHit(hit, target, amount) end
        end
    end
    for _, p in ipairs(self:OnlinePlayers() or {}) do
        if p ~= player and p.Character and p.Character.Position then
            settle(p, 'player:' .. tostring(p.UserId), p.Character.Position)
        end
    end
    if self.FishUnit then
        for _, fish in pairs(self.FishUnit.Fish or {}) do
            local carrier = fish.Carrier
            local body = carrier and carrier.Body
            if carrier and not carrier.Dead and body and body.Position then
                settle(carrier, 'fish:' .. tostring(fish.Id), body.Position)
            end
        end
    end
end

function Mgr:UpdateBreath(player, state, now)
    local breath = state.breath
    local bc = breathCfg()
    local plan = breath.ledger.Plan
    while breath.tick <= #plan and now >= breath.castAt + (breath.tick - 1) * bc.TickSec do
        self:BreathTick(player, breath, breath.tick)
        breath.tick = breath.tick + 1
    end
    if now >= breath.castAt + bc.DurationSec then
        state.breath = nil
        self:SendState(player)
    end
end

function Mgr:MirrorCooldown(state, now)
    if not state.lastBreathAt then return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(state.player)
    local mark = data and data.Extra and data.Extra.cooldowns
    if type(mark) ~= 'table' then return end
    mark.godzillaBreath = SpecialItem.CooldownRemaining(state.lastBreathAt, now, breathCfg().CooldownSec)
end


function Mgr:Update(dt)
    local now = self:Now()
    for state, job in pairs(self.PendingCleanup) do
        if now >= job.nextAt then
            job.attempts = job.attempts + 1
            if self:Restore(state.player, state) then
                self.PendingCleanup[state] = nil
            elseif job.attempts >= CLEANUP_RETRIES then
                self.PendingCleanup[state] = nil
                local errors = {}
                for key, failure in pairs(state.failures or {}) do
                    errors[#errors + 1] = key .. ': ' .. tostring(failure.error)
                end
                self.CleanupFailures[#self.CleanupFailures + 1] = {
                    userId = tostring(state.player.UserId), at = now, attempts = job.attempts,
                    errors = table.concat(errors, '; '),
                }
                if #self.CleanupFailures > CLEANUP_HISTORY_LIMIT then table.remove(self.CleanupFailures, 1) end
            else
                job.nextAt = now + 1
            end
        end
    end
    for _, state in pairs(self.States) do
        local player = state.player
        if player then
            self:Reconcile(player, state)
            if not state.restoring and state.effect == 'wings' then self:UpdateFlight(player, state, dt) end
            if state.breath then self:UpdateBreath(player, state, now) end
            self:MirrorCooldown(state, now)
        end
    end
end

function Mgr:Handle(player, payload)
    if type(payload) ~= 'table' or not player then return false end
    -- 引擎 Player 并非 Lua table；校验登记身份对象，既兼容引擎也拒绝伪造 / 尚未载入存档的请求
    local ok, userId = pcall(function() return player.UserId end)
    local state = ok and self.States[userId]
    if not state or state.player ~= player then return false end
    self:Reconcile(player, state)
    if payload.action == 'fly' then
        if state.restoring or state.effect ~= 'wings' or not self:CanAct(player) then
            state.holding = false
            return self:Fail(player, 'fly', 'not-wings')
        end
        state.holding = payload.holding == true
        return true
    end
    if payload.action == 'breath' then
        return self:CastBreath(player)
    end
    return false
end

function Mgr:Query(player)
    if not player then return false end
    local ok, id = pcall(function() return player.UserId end)
    local state = ok and self.States[id]
    if not state or state.player ~= player or state.leaving then return false end
    if _G.REUtil:CheckRECD(player, 'SpecialItemStateRequest', cfg().ReLimitSec) then return false end
    self:SendState(player)
    return true
end

function Mgr:Start()
    _G.REUtil:GetRE('SpecialItemStateRequest').OnServerEvent:Connect(function(player) self:Query(player) end)
    _G.REUtil:GetRE('SpecialItemAction').OnServerEvent:Connect(function(player, payload)
        local release = type(payload) == 'table' and payload.action == 'fly' and payload.holding ~= true
        if not release and _G.REUtil:CheckRECD(player, 'SpecialItemAction', cfg().ReLimitSec) then return end
        self:Handle(player, payload)
    end)
end

function Mgr:OnPlayerAdded(player)
    local state = self:GetState(player)
    state.player = player
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    local mark = data and data.Extra and data.Extra.cooldowns
    local remaining = mark and mark.godzillaBreath
    if type(remaining) == 'number' and remaining > 0 then
        state.lastBreathAt = self:Now() - (breathCfg().CooldownSec - remaining)
    end
    self:SendState(player)
end

function Mgr:BeforeLeave(player)
    local state = self.States[player.UserId]
    if state and state.player == player then self:MirrorCooldown(state, self:Now()) end
end

function Mgr:OnTeleport(player)
    local state = self.States[player.UserId]
    if not state then return end
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    state.suspendedItem = selectedItemId(data)
    self:Restore(player, state)
    self:SendState(player)
end

function Mgr:OnPlayerRemoving(player)
    local state = self.States[player.UserId]
    if not state or state.player ~= player then return end
    self:MirrorCooldown(state, self:Now())
    state.cleanupCharacter = player.Character
    if self.States[player.UserId] == state then self.States[player.UserId] = nil end
    if not self:Restore(player, state) then
        self.PendingCleanup[state] = { attempts = 0, nextAt = self:Now() + 1 }
    end
end

return Mgr
