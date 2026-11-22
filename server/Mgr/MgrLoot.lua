local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local MathWaterJudge = require('common.MathWaterJudge')
local MgrFishCarrier = require('server.Mgr.MgrFishCarrier')

local Mgr = { Loots = {}, NextId = 0, Spots = {}, ZoneQueues = {}, PendingQueues = {}, Recycling = {},
    ZoneStats = {}, Reserved = {} }

local function cfg()
    return GameCfg.Loot
end

local function isWeapon(definition)
    return definition ~= nil and (definition.Type == '近战武器' or definition.Type == '远程武器')
end

function Mgr:Broadcast()
    _G.REUtil:GetRE('LootState'):FireAllClients(self:Snapshot())
end

function Mgr:Reply(player, payload)
    _G.REUtil:GetRE('LootResult'):FireClient(player, payload)
end

function Mgr:Snapshot()
    local list = {}
    for _, loot in pairs(self.Loots) do
        local row = { id = loot.Id, kind = loot.Kind, fishId = loot.FishId, itemId = loot.ItemId,
            x = loot.Position.x, y = loot.Position.y, z = loot.Position.z }
        if self.Recycling[loot.Id] then row.warn = true end
        list[#list + 1] = row
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

local function destroyUnit(unit, why, id)
    local ok, err = pcall(function() unit:Destroy() end)
    if not ok then print('[MgrLoot] 实例销毁失败', why, tostring(id), tostring(err)) end
    return ok
end

function Mgr:Ground(pos)
    local c = cfg()
    local physics = game:GetService('PhysicsService')
    if physics and RaycastParams then
        local params = RaycastParams.New()
        params.FilterDescendantsInstances = self.FishUnit and self.FishUnit:RayExclusions() or {}
        local ok, hit = pcall(physics.Raycast, physics, Vector3.New(pos.x, pos.y + c.GroundRayUp, pos.z),
            Vector3.New(0, -c.GroundRayDown, 0), params)
        if ok and hit and hit.Position then return hit.Position.y, hit end
    end
    return pos.y
end

function Mgr:OnCarrierDied(carrier)
    local fish = self.FishUnit and self.FishUnit:FindByCarrier(carrier)
    local killed = fish and self.FishUnit:TakeKilled(fish)
    if not killed or not killed.position then return end
    local species = GameCfg.Fish[killed.fishId]
    if species.Drops then
        local total = 0
        for _, drop in ipairs(species.Drops) do total = total + drop.Count end
        local index = 0
        for _, drop in ipairs(species.Drops) do
            for _ = 1, drop.Count do
                index = index + 1
                local p = killed.position
                local pos = Vector3.New(p.x + (index - (total + 1) / 2) * cfg().DropSpacing, p.y, p.z)
                self:Spawn(killed.fishId, killed.mult, pos, drop.ItemId)
            end
        end
    else
        self:Spawn(killed.fishId, killed.mult, killed.position)
    end
end

function Mgr:RegionAt(pos)
    for _, zone in ipairs(GameCfg.Zones) do
        local bounds = zone.Scene and zone.Scene.Boundary
        if bounds and pos.x >= bounds.MinX and pos.x <= bounds.MaxX
            and pos.z >= bounds.MinZ and pos.z <= bounds.MaxZ then
            return zone.Id
        end
    end
    local best, bestDist
    for _, zone in ipairs(GameCfg.Water.Zones) do
        local dx, dz = pos.x - zone.Center.x, pos.z - zone.Center.z
        local dist = dx * dx + dz * dz
        if not bestDist or dist < bestDist then best, bestDist = zone, dist end
    end
    return best and (best.ZoneId or best.Id) or nil
end

function Mgr:Stats(zoneId)
    local stat = self.ZoneStats[zoneId]
    if not stat then
        stat = { Active = 0, Pending = 0, PeakActive = 0, PeakPending = 0, Recycled = 0, RecycledEarly = 0 }
        self.ZoneStats[zoneId] = stat
    end
    return stat
end

function Mgr:NotePeak(zoneId)
    local stat = self:Stats(zoneId)
    local active, pending = #(self.ZoneQueues[zoneId] or {}), #(self.PendingQueues[zoneId] or {})
    stat.Active, stat.Pending = active, pending
    if active > stat.PeakActive or pending > stat.PeakPending then
        stat.PeakActive, stat.PeakPending = math.max(stat.PeakActive, active), math.max(stat.PeakPending, pending)
        print('[MgrLoot] 区峰值 zone=' .. tostring(zoneId), 'active=' .. active, 'pending=' .. pending,
            'cap=' .. tostring(cfg().PerZoneCap), 'pendingCap=' .. tostring(cfg().PendingCap))
    end
end

function Mgr:Track(loot)
    local zoneId = self:RegionAt(loot.Position)
    if not zoneId then return end
    loot.ZoneId = zoneId
    local queue = self.ZoneQueues[zoneId]
    if not queue then
        queue = {}
        self.ZoneQueues[zoneId] = queue
    end
    queue[#queue + 1] = loot.Id
    self:EnforceCap(zoneId)
end

function Mgr:Untrack(loot)
    local zoneId = loot.ZoneId
    self.Recycling[loot.Id] = nil
    local lists = { zoneId and self.PendingQueues[zoneId], zoneId and self.ZoneQueues[zoneId] }
    for index = 1, 2 do
        local list = lists[index]
        if list then
            for i, id in ipairs(list) do
                if id == loot.Id then table.remove(list, i) break end
            end
        end
    end
    if zoneId then self:NotePeak(zoneId) end
end

function Mgr:EnforceCap(zoneId)
    local queue = self.ZoneQueues[zoneId]
    local cap = cfg().PerZoneCap
    while queue and cap and #queue > cap do
        local id = table.remove(queue, 1)
        local loot = self.Loots[id]
        if loot then self:MarkRecycling(loot) end
        self:EnforcePending(zoneId)
    end
    self:NotePeak(zoneId)
end

function Mgr:MarkRecycling(loot)
    local now = self:Now()
    self.Recycling[loot.Id] = { At = now + cfg().FlashBeforeRecycleSec, NextFlash = now, Visible = true }
    local pending = self.PendingQueues[loot.ZoneId]
    if not pending then
        pending = {}
        self.PendingQueues[loot.ZoneId] = pending
    end
    pending[#pending + 1] = loot.Id
    print('[MgrLoot] 待回收', loot.ItemId, 'loot=' .. tostring(loot.Id), 'zone=' .. tostring(loot.ZoneId),
        'after=' .. tostring(cfg().FlashBeforeRecycleSec) .. 's')
end

function Mgr:EnforcePending(zoneId)
    local pending = self.PendingQueues[zoneId]
    local cap = cfg().PendingCap
    while pending and cap and #pending > cap do
        local id = table.remove(pending, 1)
        if self.Recycling[id] then
            local stat = self:Stats(zoneId)
            stat.RecycledEarly = stat.RecycledEarly + 1
            self:Recycle(id, '预警超限即回收')
        end
    end
end

function Mgr:Recycle(id, why)
    local loot = self.Loots[id]
    if not loot then
        self.Recycling[id] = nil
        return false
    end
    local ok, err = pcall(function() loot.Unit:Destroy() end)
    if not ok then
        print('[MgrLoot] 回收销毁失败', id, tostring(err))
        local entry = self.Recycling[id]
        if entry then entry.At = self:Now() + cfg().RecycleRetrySec end
        return false
    end
    self.Loots[id] = nil
    self.Recycling[id] = nil
    local pending = self.PendingQueues[loot.ZoneId]
    if pending then
        for i, value in ipairs(pending) do
            if value == id then table.remove(pending, i) break end
        end
    end
    local stat = self:Stats(loot.ZoneId or 'unknown')
    stat.Recycled = stat.Recycled + 1
    self:NotePeak(loot.ZoneId or 'unknown')
    print('[MgrLoot] 回收', loot.ItemId, 'loot=' .. tostring(id), 'zone=' .. tostring(loot.ZoneId), why or '',
        'active=' .. #(self.ZoneQueues[loot.ZoneId] or {}), 'pending=' .. #(self.PendingQueues[loot.ZoneId] or {}),
        'recycled=' .. stat.Recycled)
    return true
end

function Mgr:Spawn(fishId, mult, pos, itemId)
    local species = GameCfg.Fish[fishId]
    if not species then return nil end
    local position = Vector3.New(pos.x, self:Ground(pos) + cfg().Height, pos.z)
    self.NextId = self.NextId + 1
    local id = self.NextId
    local world = game:GetService('World')
    local ok, unit = pcall(world.CreateUnit, world, 'WorldUnit', {
        Name = 'FishLoot_' .. tostring(id),
        Position = position,
        RenderMeshId = 'official://mesh/' .. tostring(species.Model),
        ModelColor1 = Color.New(species.VisualColor[1], species.VisualColor[2], species.VisualColor[3], species.VisualColor[4]),
        BodyType = 1,
        PhysicsActive = false,
        GravityEnabled = false,
        CanCollide = false,
        Liftable = false,
    })
    if not ok or not unit then
        print('[MgrLoot] 鱼获实体创建失败', fishId, tostring(unit))
        return nil
    end
    local loot = { Id = id, Kind = 'fish', ItemId = itemId or fishId, FishId = fishId, Mult = mult, Position = position, Unit = unit }
    self.Loots[id] = loot
    self:Track(loot)
    print('[MgrLoot] 生成鱼获', loot.ItemId, mult, 'loot=' .. tostring(id))
    self:Broadcast()
    return loot
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Mgr:MeshOf(itemId)
    local species = GameCfg.Fish[itemId]
    if species and species.Model then return 'official://mesh/' .. tostring(species.Model) end
    local item = GameCfg.Items.Definitions[itemId]
    local visual = item and item.Visual
    if visual then
        local scale = visual.Scale
        return visual.Mesh, Vector3.New(scale.x, scale.y, scale.z)
    end
    local scale = cfg().ItemScale
    return cfg().ItemMesh, Vector3.New(scale, scale, scale)
end

local function createLoot(self, itemId, mult, cooked, position)
    self.NextId = self.NextId + 1
    local id = self.NextId
    local mesh, scale = self:MeshOf(itemId)
    local world = game:GetService('World')
    local values = {
        Name = 'ItemDrop_' .. tostring(id),
        Position = position,
        RenderMeshId = mesh,
        BodyType = 1,
        PhysicsActive = false,
        GravityEnabled = false,
        CanCollide = false,
        Liftable = false,
        ModelVisible = false,
    }
    if scale then values.Scale = scale end
    local item = GameCfg.Items.Definitions[itemId]
    local tint = item and item.IconColor
    if tint then values.ModelColor1 = Color.New(tint[1], tint[2], tint[3], tint[4]) end
    local ok, unit = pcall(world.CreateUnit, world, 'WorldUnit', values)
    if not ok or not unit then
        print('[MgrLoot] 掉落实例创建失败', itemId, tostring(unit))
        return nil, 'spawn-failed'
    end
    return { Id = id, Kind = 'item', ItemId = itemId, Mult = mult, Cooked = cooked, Position = position, Unit = unit }
end

function Mgr:Live(loot)
    self.Loots[loot.Id] = loot
    local ok, err = pcall(function() loot.Unit.ModelVisible = true end)
    if not ok then print('[MgrLoot] 掉落实例显示失败', loot.Id, tostring(err)) end
    self:Track(loot)
    print('[MgrLoot] 生成掉落', loot.ItemId, loot.Mult, 'loot=' .. tostring(loot.Id), 'zone=' .. tostring(loot.ZoneId))
    self:Broadcast()
    return loot
end

function Mgr:SpawnItem(itemId, mult, cooked, pos)
    if type(itemId) ~= 'string' or not GameCfg.Items.Definitions[itemId] then return nil, 'bad-item' end
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' or type(pos.z) ~= 'number' then return nil, 'bad-position' end
    local position = Vector3.New(pos.x, self:Ground(pos) + cfg().Height, pos.z)
    local loot, reason = createLoot(self, itemId, mult, cooked, position)
    if not loot then return nil, reason end
    return self:Live(loot)
end

function Mgr:SpawnDelivery(key, itemId, mult, cooked, pos)
    self.Deliveries = self.Deliveries or {}
    if self.Deliveries[key] then return self.Deliveries[key] end
    local loot, reason = self:SpawnItem(itemId, mult, cooked, pos)
    if loot then self.Deliveries[key] = { Id = loot.Id } end
    return loot, reason
end

local function validated(drop)
    if type(drop) ~= 'table' then return nil, 'bad-item' end
    local itemId = drop.itemId
    if type(itemId) ~= 'string' or not GameCfg.Items.Definitions[itemId] then return nil, 'bad-item' end
    local mult = drop.mult
    if mult ~= nil and (type(mult) ~= 'number' or mult < 1 or mult > 2) then return nil, 'bad-item' end
    local cooked = drop.cooked
    if cooked ~= nil and (type(cooked) ~= 'number' or cooked <= 0 or cooked ~= cooked or cooked >= math.huge) then
        return nil, 'bad-item'
    end
    return { itemId = itemId, mult = mult, cooked = cooked }
end

local function owns(data, drop)
    if type(drop.slot) == 'number' and drop.slot == math.floor(drop.slot) then
        local snapshot = data:GetItemBarSnapshot()
        local entry = snapshot and snapshot.slots[drop.slot]
        return entry ~= nil and entry.count > 0 and entry.itemId == drop.itemId
    end
    return data:ItemCount(drop.itemId) >= 1 or data:WeaponCount(drop.itemId) >= 1 or data:HasBait(drop.itemId)
end

local function forwardOf(character)
    local fx, fz
    pcall(function()
        local forward = character.Rotation:GetForward()
        local length = math.sqrt(forward.x * forward.x + forward.z * forward.z)
        if length >= 0.01 then fx, fz = forward.x / length, forward.z / length end
    end)
    return fx or 0, fz or 0
end

function Mgr:PrepareDrop(player, drop)
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data then return nil, 'not-ready' end
    local item, reason = validated(drop)
    if not item then return nil, reason end
    if not owns(data, drop) then return nil, 'not-owned' end
    local character = player.Character
    local origin = character and character.Position
    if not origin then return nil, 'no-character' end
    local previous = self.Reserved[player.UserId]
    if previous then
        print('[MgrLoot] 丢弃预留被顶替，释放旧的', player.UserId, previous.Loot.ItemId)
        self:CancelDrop(player, previous)
    end
    local fx, fz = forwardOf(character)
    local pos = Vector3.New(origin.x + fx * cfg().DropOffset, origin.y, origin.z + fz * cfg().DropOffset)
    local position = Vector3.New(pos.x, self:Ground(pos) + cfg().Height, pos.z)
    local loot, failure = createLoot(self, item.itemId, item.mult, item.cooked, position)
    if not loot then return nil, failure end
    local reservation = { Player = player, Loot = loot, Done = false,
        Id = loot.Id, ItemId = loot.ItemId, Position = loot.Position, Unit = loot.Unit }
    self.Reserved[player.UserId] = reservation
    return reservation
end

function Mgr:Give(data, itemId, mult, cooked, count)
    local definition = GameCfg.Items.Definitions[itemId]
    if not definition then return false end
    count = count or 1
    if definition.Container == GameCfg.Items.ContainerId.Bait then return data:AddBait(itemId, count) end
    if isWeapon(definition) then return data:GrantWeapon(itemId, count) end
    if count > 1 then return false end
    return data:AddItem(itemId, mult, cooked)
end

function Mgr:Refund(player, reservation)
    local loot = reservation.Loot
    local data = self.PlayerData and self.PlayerData:GetDataInst(player)
    if not data or not self:Give(data, loot.ItemId, loot.Mult, loot.Cooked) then
        print('[MgrLoot] 丢弃补偿失败，物品未退回', player.UserId, loot.ItemId, 'loot=' .. tostring(loot.Id))
        return false, 'spawn-failed'
    end
    destroyUnit(loot.Unit, '丢弃补偿', loot.Id)
    self.PlayerData:SendItemBar(player)
    print('[MgrLoot] 丢弃落物生成失败，已退回物品', player.UserId, loot.ItemId, 'loot=' .. tostring(loot.Id))
    return false, 'spawn-failed'
end

function Mgr:CommitDrop(player, reservation, drop)
    if type(reservation) ~= 'table' or reservation.Player ~= player or type(reservation.Loot) ~= 'table' then
        return false, 'bad-reservation'
    end
    if self.Reserved[player.UserId] == reservation then self.Reserved[player.UserId] = nil end
    if reservation.Done then return false, reservation.Outcome == 'refunded' and 'refunded' or 'committed' end
    reservation.Done, reservation.Outcome = true, 'committed'
    local unit = reservation.Loot.Unit
    local alive = unit ~= nil and not unit.Destroyed
    if alive then
        local ok, err = pcall(function() unit.ModelVisible = true end)
        if not ok then
            alive = false
            print('[MgrLoot] 掉落实例显示失败', reservation.Loot.Id, tostring(err))
        end
    end
    if not alive then
        reservation.Outcome = 'refunded'
        return self:Refund(player, reservation)
    end
    self:Live(reservation.Loot)
    return true
end

function Mgr:CancelDrop(player, reservation, drop)
    if type(reservation) ~= 'table' or reservation.Player ~= player or type(reservation.Loot) ~= 'table' then
        return false
    end
    if self.Reserved[player.UserId] == reservation then self.Reserved[player.UserId] = nil end
    if reservation.Done then return false end
    reservation.Done, reservation.Outcome = true, 'cancelled'
    destroyUnit(reservation.Loot.Unit, '取消预留', reservation.Loot.Id)
    print('[MgrLoot] 丢弃预留取消', player.UserId, reservation.Loot.ItemId, 'loot=' .. tostring(reservation.Loot.Id))
    return true
end

function Mgr:OnPlayerRemoving(player)
    local reservation = player and self.Reserved[player.UserId]
    if reservation then self:CancelDrop(player, reservation) end
end

function Mgr:Pickup(player, id)
    if type(id) ~= 'number' or id ~= math.floor(id) then return false end
    local loot = self.Loots[id]
    local data = loot and self.PlayerData and self.PlayerData:GetDataInst(player)
    local character = player and player.Character
    local pos = character and character.Position
    if not data or not pos then return false end
    if distance(pos, loot.Position) > BodyScale.InteractionRadius(character, cfg().PickupRadius) + cfg().PickupSlack then return false end
    self.Loots[id] = nil
    if loot.Kind == 'bait' then return self:GiveBait(player, data, loot) end
    if not self:Give(data, loot.ItemId, loot.Mult, loot.Cooked, loot.Count) then
        self.Loots[id] = loot
        self:Reply(player, { ok = false, reason = 'full', id = id })
        print('[MgrLoot] 背包已满，拒绝拾取', player.UserId, 'loot=' .. tostring(id))
        return false
    end
    self:Untrack(loot)
    destroyUnit(loot.Unit, '拾取', id)
    print('[MgrLoot] 拾取', player.UserId, loot.ItemId, loot.Mult, 'loot=' .. tostring(id))
    self.PlayerData:SendItemBar(player)
    self:Reply(player, { ok = true, id = id })
    self:Broadcast()
    return true
end

function Mgr:GiveBait(player, data, loot)
    if not data:AddBait(loot.ItemId, loot.Count) then
        self.Loots[loot.Id] = loot
        return false
    end
    self:Untrack(loot)
    destroyUnit(loot.Unit, '拾饵', loot.Id)
    local spot = self.Spots[loot.SpotId]
    if spot then
        spot.LootId = nil
        spot.RespawnAt = self:Now() + GameCfg.BaitSpots.RespawnSec
    end
    print('[MgrLoot] 拾饵', player.UserId, loot.ItemId, loot.Count, 'spot=' .. tostring(loot.SpotId), 'loot=' .. tostring(loot.Id))
    if self.Quest then
        self.Quest:Notify('PickBait', player, { itemId = loot.ItemId, count = loot.Count, eventId = 'loot:' .. tostring(loot.Id) })
    end
    self.PlayerData:SendItemBar(player)
    self:Reply(player, { ok = true, id = loot.Id })
    self:Broadcast()
    return true
end

function Mgr:Now()
    return game:GetService('World'):GetServerTime()
end

function Mgr:SpawnBait(spotCfg)
    local spot = self.Spots[spotCfg.Id]
    if not spot or spot.LootId then return nil end
    local c = GameCfg.BaitSpots
    local p = spotCfg.Position
    for _, zone in ipairs(GameCfg.Water.Zones) do
        if MathWaterJudge.InZone(zone, { x = p.x, y = zone.SurfaceY, z = p.z }) then
            print('[MgrLoot] 鱼饵点位在水区，跳过刷新', spotCfg.Id, zone.Id)
            return nil
        end
    end
    local groundY, hit = self:Ground(p)
    if not hit or hit.Normal and hit.Normal.y < 0.5 then
        print('[MgrLoot] 鱼饵点位未命中陆地，跳过刷新', spotCfg.Id)
        spot.RespawnAt = self:Now() + c.RespawnSec
        return nil
    end
    local position = Vector3.New(p.x, groundY + cfg().Height, p.z)
    self.NextId = self.NextId + 1
    local id = self.NextId
    local world = game:GetService('World')
    local ok, unit = pcall(world.CreateUnit, world, 'WorldUnit', {
        Name = 'BaitSpot_' .. tostring(spotCfg.Id) .. '_' .. tostring(id),
        Position = position,
        RenderMeshId = c.Mesh,
        Scale = Vector3.New(c.Scale, c.Scale, c.Scale),
        BodyType = 1,
        PhysicsActive = false,
        GravityEnabled = false,
        CanCollide = false,
        Liftable = false,
    })
    if not ok or not unit then
        print('[MgrLoot] 点位鱼饵创建失败', spotCfg.Id, tostring(unit))
        spot.RespawnAt = self:Now() + c.RespawnSec
        return nil
    end
    local loot = { Id = id, Kind = 'bait', ItemId = spotCfg.ItemId, Count = spotCfg.Count or 1,
        SpotId = spotCfg.Id, Position = position, Unit = unit }
    self.Loots[id] = loot
    spot.LootId = id
    spot.RespawnAt = nil
    print('[MgrLoot] 点位刷新鱼饵', spotCfg.Id, spotCfg.ItemId, 'loot=' .. tostring(id))
    self:Broadcast()
    return loot
end

function Mgr:StartSpots()
    for _, spotCfg in ipairs(GameCfg.BaitSpots.Spots) do
        self.Spots[spotCfg.Id] = { Cfg = spotCfg }
        self:SpawnBait(spotCfg)
    end
end

function Mgr:Start()
    self.DeliveryEpoch = self.DeliveryEpoch or tostring(game:GetService('World'):GetServerTime()) .. ':' .. tostring(math.random())
    MgrFishCarrier:SubscribeDied(function(carrier) self:OnCarrierDied(carrier) end)
    self:Listen()
    self:StartSpots()
end

function Mgr:Listen()
    _G.REUtil:GetRE('RequestLoot').OnServerEvent:Connect(function(player)
        _G.REUtil:GetRE('LootState'):FireClient(player, self:Snapshot())
    end)
end

function Mgr:Update()
    local now
    for _, spot in pairs(self.Spots) do
        if spot.RespawnAt then
            now = now or self:Now()
            if now >= spot.RespawnAt then self:SpawnBait(spot.Cfg) end
        end
    end
    local expired
    for id, entry in pairs(self.Recycling) do
        now = now or self:Now()
        if now >= entry.At then
            expired = expired or {}
            expired[#expired + 1] = id
        elseif now >= entry.NextFlash then
            local loot = self.Loots[id]
            if loot then
                entry.Visible = not entry.Visible
                local visible = entry.Visible
                local ok, err = pcall(function() loot.Unit.ModelVisible = visible end)
                if not ok and not entry.FlashFailed then
                    entry.FlashFailed = true
                    print('[MgrLoot] 闪烁失败', id, tostring(err))
                end
            end
            entry.NextFlash = now + (cfg().FlashIntervalSec or 0.5)
        end
    end
    if not expired then return end
    for _, id in ipairs(expired) do self:Recycle(id, '预警到期') end
    self:Broadcast()
end

return Mgr
