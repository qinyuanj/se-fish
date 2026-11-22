local GameCfg = require('common.GameCfg')
local MathWaterJudge = require('common.MathWaterJudge')
local FishCatch = require('common.FishCatch')
local MgrPlayerData = require('server.Mgr.MgrPlayerData')
local REUtil = require('common.REUtil')
local MgrFishUnit = require('server.Mgr.MgrFishUnit')

local Mgr = { Sessions = {}, NextFish = {}, NextFishSerial = 0, FishUnit = MgrFishUnit }
MathWaterJudge.Build(GameCfg.Water.Zones)

local function selectedRod(data, payload)
    local selected = data.Data.SelectedSlot
    local entry = selected and data.Data.Containers[GameCfg.Items.ContainerId.ItemBar][selected]
    local definition = entry and entry.count >= 1 and GameCfg.Items.Definitions[entry.itemId]
    if not definition or type(definition.Level) ~= 'number'
        or payload.slot ~= selected or payload.itemId ~= entry.itemId then return end
    return selected, entry
end

local function waterZone(x, z)
    for _, candidate in ipairs(GameCfg.Water.Zones) do
        if MathWaterJudge.InZone(candidate, { x = x, y = candidate.SurfaceY, z = z }) then
            return candidate
        end
    end
end

local function castLanding(character)
    local origin, rotation = character.Position, character.Rotation
    if not origin or not rotation then return end
    local forward = rotation:GetForward()
    local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
    if length < 0.01 then return end
    local x = origin.x + GameCfg.Casting.Distance * forward.x / length
    local z = origin.z + GameCfg.Casting.Distance * forward.z / length
    local zone = waterZone(x, z)
    return { x = x, y = zone and zone.SurfaceY or origin.y, z = z }, zone
end

function Mgr:SendState(player, session, snapshot)
    local holding = self.FishUnit and self.FishUnit:HeldInfo(player) or nil
    local species = session and session.fishId and GameCfg.Fish[session.fishId]
    local source = species and species.CatchSource or 'water'
    local landing = session and session.landing
    local hookPosition = landing and { x=landing.x,
        y=landing.y+(source=='air' and GameCfg.Casting.AirSourceHeight or 0), z=landing.z }
    REUtil:GetRE('CastState'):FireClient(player, session and {
        phase = session.phase,
        snapshot = snapshot == true,
        castId = session.castId,
        landing = session.landing,
        zoneId = session.zoneId,
        fishId = session.fishId,
        catchSource = source,
        hookPosition = hookPosition,
        mult = session.mult,
        reelSession = session.reelSession,
        holding = holding,
    } or { phase = 'idle', holding = holding })
end

function Mgr:PushState(player)
    local current = self.Sessions[player.UserId]
    self:SendState(player, current and current.player == player and current.session or nil, true)
end

function Mgr:SendFailure(player, reason, landing, active)
    local result = { reason = reason, landing = landing }
    REUtil:GetRE('CastState'):FireClient(player, active and { result = result }
        or { phase = 'idle', result = result })
end

function Mgr:Cast(player, payload)
    local current = self.Sessions[player.UserId]
    if current then
        self:SendFailure(player, 'alreadyCasting', nil, true)
        return
    end
    local data = MgrPlayerData:GetDataInst(player)
    local character = player.Character
    if not data or not character then
        self:SendFailure(player, 'unavailable')
        return
    end
    if self.Vitals and not self.Vitals:CanAct(player) then
        self:SendFailure(player, 'cannotAct')
        return
    end
    if self.FishUnit and not self.FishUnit:CanCast(player) then
        self:SendFailure(player, 'holding')
        return
    end
    local selected, entry = selectedRod(data, payload)
    if not entry then
        self:SendFailure(player, 'invalidRod')
        return
    end
    local ok, landing, zone = pcall(castLanding, character)
    if not ok then
        print('[MgrCast] 计算落点失败', player.UserId, tostring(landing))
        self:SendFailure(player, 'unavailable')
        return
    end
    if not landing or not zone then
        self:SendFailure(player, landing and 'invalidLanding' or 'unavailable', landing)
        return
    end
    if REUtil:CheckRECD(player, 'CastAction', GameCfg.Casting.ActionCooldownSec) then
        self:SendFailure(player, 'cooldown')
        return
    end
    local baitOk, baitId = data:ConsumeSelectedBait()
    if not baitOk then
        self:SendFailure(player, 'baitUnavailable')
        return
    end
    self.NextCastId = (self.NextCastId or 0) + 1
    local session = {
        castId = self.NextCastId,
        phase = 'cast',
        landing = landing,
        zoneId = zone.Id,
        baitId = baitId,
        slot = selected,
        rodLevel = GameCfg.Items.Definitions[entry.itemId].Level or 1,
        hookAt = self.World:GetServerTime() + GameCfg.Casting.HookDelaySec,
    }
    self.Sessions[player.UserId] = { player = player, session = session }
    self:SendState(player, session)
    print('[MgrCast] 抛竿', player.UserId, session.zoneId, baitId or 'none')
    if self.Quest then
        self.Quest:Notify('CastWater', player, { itemId = baitId,
            eventId = 'cast:' .. tostring(player.UserId) .. ':' .. tostring(session.castId) })
    end
end

function Mgr:SetNextFish(player, fishId)
    self.NextFishSerial = self.NextFishSerial + 1
    local entry = { fishId = fishId, serial = self.NextFishSerial }
    self.NextFish[player.UserId] = entry
    local current = self.Sessions[player.UserId]
    if current and current.player == player and current.session.phase == 'hooked' then
        current.session.fishId = fishId
        current.session.forcedFishSerial = entry.serial
        self:SendState(player, current.session)
    end
end

function Mgr:EndSession(player, current, notify, reason)
    if self.Sessions[player.UserId] ~= current then return end
    self.Sessions[player.UserId] = nil
    if notify == false then return end
    local slot = current.session.slot
    local data = slot and MgrPlayerData:GetDataInst(player)
    if data and data.Data.SelectedSlot ~= slot
        and data:RestoreSlot(slot) then
        MgrPlayerData:SendItemBar(player)
    end
    if reason then
        REUtil:GetRE('CastState'):FireClient(player, {
            phase = 'idle', castId = current.session.castId, result = { reason = reason },
            holding = self.FishUnit and self.FishUnit:HeldInfo(player) or nil,
        })
    else
        self:SendState(player)
    end
end

local function lineStillOut(phase)
    return phase == 'cast' or phase == 'unhooked'
end

function Mgr:Reel(player)
    local current = self.Sessions[player.UserId]
    if not current or current.player ~= player then return end
    if not lineStillOut(current.session.phase) then return end
    if REUtil:CheckRECD(player, 'CastAction', GameCfg.Casting.ActionCooldownSec) then return end
    self:EndSession(player, current)
    print('[MgrCast] 收竿', player.UserId)
end

function Mgr:Drop(player)
    if not self.FishUnit or not self.FishUnit:GetHeld(player) then return end
    if REUtil:CheckRECD(player, 'CastAction', GameCfg.Casting.ActionCooldownSec) then return end
    self.FishUnit:Drop(player)
end

function Mgr:Abort(player)
    local current = self.Sessions[player.UserId]
    if not current or current.player ~= player then return end
    if not lineStillOut(current.session.phase) then return end
    self:EndSession(player, current)
    print('[MgrCast] 死亡断线', player.UserId)
end

function Mgr:FinishReel(player, sessionId, outcome, notify, lineOut)
    local current = self.Sessions[player.UserId]
    if not current or current.player ~= player or current.session.reelSession ~= sessionId
        or current.session.phase ~= 'hooked' then return end
    if outcome == 'landed' then
        local session = current.session
        if session.forcedFishSerial and not GameCfg.Debug.Enabled then
            self.NextFish[player.UserId] = nil
            self:EndSession(player, current, notify)
            return
        end
        session.phase = 'landed'
        session.idleAt = self.World:GetServerTime() + GameCfg.Casting.LandedHoldSec
        self:Land(player, session)
        if notify ~= false then self:SendState(player, session) end
        if self.Quest then
            self.Quest:Notify('Land', player, { itemId = session.fishId, eventId = 'reel:' .. tostring(sessionId) })
        end
    elseif lineOut then
        current.session.phase = 'unhooked'
        if notify ~= false then self:SendState(player, current.session) end
    else
        self:EndSession(player, current, notify)
    end
end

function Mgr:Land(player, session)
    if self.Compendium then
        local recorded, reason = self.Compendium:RecordLanding(player, { fishId = session.fishId,
            mult = session.mult, reelSerial = session.reelSerial })
        if not recorded and reason ~= 'replay' then
            print('[MgrCast] 图鉴未入账', player.UserId, session.fishId, tostring(reason))
        end
    end
    local character = player.Character
    local origin, rotation = character and character.Position, character and character.Rotation
    if not origin or not rotation then
        print('[MgrCast] 上岸但角色不在，未生成活鱼', player.UserId, session.fishId)
        return
    end
    local forward = rotation:GetForward()
    local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
    local dx, dz = 0, 0
    if length >= 0.01 then
        dx = GameCfg.Casting.LandingOffset * forward.x / length
        dz = GameCfg.Casting.LandingOffset * forward.z / length
    end
    local position = Vector3.New(origin.x + dx, origin.y + GameCfg.Casting.LandingHeight, origin.z + dz)
    local fish, err = self.FishUnit:SpawnLanded(player, { fishId = session.fishId, mult = session.mult }, position)
    if fish then
        local forced = session.forcedFishSerial and self.NextFish[player.UserId]
        if forced and forced.serial == session.forcedFishSerial then self.NextFish[player.UserId] = nil end
        print('[MgrCast] 上岸', player.UserId, session.fishId, session.mult, 'fish=' .. tostring(fish.Id))
    else
        print('[MgrCast] 上岸生成活鱼失败', player.UserId, session.fishId, tostring(err))
    end
    local ok, playErr = pcall(function()
        character.Animator:LoadAnimation(GameCfg.Casting.LandedAnimation):Play()
    end)
    if not ok then print('[MgrCast] 上岸动作播放失败', player.UserId, tostring(playErr)) end
end

function Mgr:Stop()
    for _, connection in ipairs(self.Connections or {}) do connection:Disconnect() end
    self.Connections = nil
    self.Sessions = {}
    self.NextFish = {}
end

function Mgr:Start()
    self:Stop()
    self.World = game:GetService('World')
    self.Connections = {
        REUtil:GetRE('CastAction').OnServerEvent:Connect(function(player, payload)
            if type(payload) ~= 'table' or not player then return end
            if payload.action == 'Cast' then self:Cast(player, payload)
            elseif payload.action == 'Reel' then self:Reel(player)
            elseif payload.action == 'Drop' then self:Drop(player) end
        end),
        REUtil:GetRE('RequestCastState').OnServerEvent:Connect(function(player)
            self:PushState(player)
        end),
    }
end

function Mgr:OnPlayerRemoving(player)
    local current = self.Sessions[player.UserId]
    if current and current.player == player then
        self.Sessions[player.UserId] = nil
        self.NextFish[player.UserId] = nil
    elseif not current then
        self.NextFish[player.UserId] = nil
    end
end

function Mgr:Update()
    if not GameCfg.Debug.Enabled then self.NextFish = {} end
    local now = self.World:GetServerTime()
    for _, current in pairs(self.Sessions) do
        local session = current.session
        if session.phase == 'landed' and session.idleAt and now >= session.idleAt then
            self:EndSession(current.player, current)
        elseif session.phase == 'cast' and session.hookAt and now >= session.hookAt then
            local boss = session.baitId and GameCfg.Casting.BossBait
                and GameCfg.Casting.BossBait[session.baitId]
            local forced = GameCfg.Debug.Enabled and self.NextFish[current.player.UserId]
            local fishId = forced and forced.fishId or boss
            if not fishId then
                local rows = GameCfg.Casting.Zones[session.zoneId]
                fishId = FishCatch.Select(rows, session.rodLevel, session.baitId, math.random)
            end
            if fishId then
                session.phase = 'hooked'
                session.fishId = fishId
                session.forcedFishSerial = forced and forced.serial
                session.mult = FishCatch.Multiplier(math.random)
                self.NextReelId = (self.NextReelId or 0) + 1
                session.reelSerial = self.NextReelId
                session.reelSession = tostring(self.NextReelId) .. ':' .. tostring(current.player.UserId)
                if self.ReelIn:Begin(current.player, session.reelSession, now)
                    and self.Sessions[current.player.UserId] == current and session.phase == 'hooked' then
                    self:SendState(current.player, session)
                    print('[MgrCast] 上钩', current.player.UserId, fishId, session.mult)
                end
            else
                self:EndSession(current.player, current, true, 'noFish')
                print('[MgrCast] 空抽', current.player.UserId, session.zoneId)
            end
        end
    end
end

return Mgr
