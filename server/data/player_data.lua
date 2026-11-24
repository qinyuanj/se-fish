local game_cfg = require('common.game_cfg')
local records = require('common.records')

local player_data = {}
player_data.__index = player_data

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function integer(n, min, max)
    return type(n) == 'number' and n == n and n < math.huge
        and n == math.floor(n) and n >= min and n <= (max or math.maxinteger)
end

-- #123：平台在列表型 table 跨越引擎边界（DataStore 回读、引擎 API 返回）时附加 __count 长度键，
-- 真机证据见 tests/native/save_array_meta_test.lua 首部与 #123 评论：同一份回包里列表 bar/bp 带 __count、
-- 字典型 bait 不带。这个键不是玩家数据，必须在校验之前剥掉。
-- 只认「键名恰为 ARRAY_MARKER_KEY 且值为非负整数」的形态；其它同名形态原样保留，继续被严格校验当损坏拒绝。
local ARRAY_MARKER_KEY = '__count'

local function isArrayMarker(key, value)
    return key == ARRAY_MARKER_KEY and integer(value, 0)
end

local function stripArrayMeta(value, path, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true
    local out, declared, actual = {}, nil, 0
    for key, child in pairs(value) do
        if isArrayMarker(key, child) then
            declared = child
        else
            if integer(key, 1) then actual = actual + 1 end
            local childPath = path and path .. '.' .. tostring(key) or nil
            out[key] = stripArrayMeta(child, childPath, seen)
        end
    end
    if declared ~= nil and declared ~= actual then
        print('[player_data] 数组长度标记不一致，按实际条数继续', path or '?',
            '标记=' .. declared, '实际=' .. actual)
    end
    seen[value] = nil
    return out
end
player_data.StripArrayMeta = stripArrayMeta

local function zoneScene(zoneId)
    for _, zone in ipairs(game_cfg.Zones or {}) do
        if zone.Id == zoneId then return zone.Scene end
    end
end
local function finitePoint(point)
    return type(point) == 'table' and type(point.x) == 'number' and type(point.y) == 'number'
        and type(point.z) == 'number' and point.x == point.x and point.y == point.y and point.z == point.z
        and math.abs(point.x) < math.huge and math.abs(point.y) < math.huge and math.abs(point.z) < math.huge
end
local function insideBoundary(point, bounds)
    if not finitePoint(point) or type(bounds) ~= 'table' then return false end
    return point.x > bounds.MinX and point.x < bounds.MaxX
        and point.z > bounds.MinZ and point.z < bounds.MaxZ
end

function player_data:ResolveSafePoint()
    local scene = zoneScene(game_cfg.ResolveZoneId(self.data.Zone))
    if not scene or not scene.Boundary or not finitePoint(scene.SafePoint) then return nil, false end
    local mark = self.Extra.travel.safePoint
    if insideBoundary(mark, scene.Boundary) then
        return { x = mark.x, y = mark.y, z = mark.z }, false
    end
    local fallback = { x = scene.SafePoint.x, y = scene.SafePoint.y, z = scene.SafePoint.z }
    self.Extra.travel.safePoint = fallback
    return fallback, true
end

function player_data:NoteSafePoint()
    if not self.Inited then return end
    local scene = zoneScene(game_cfg.ResolveZoneId(self.data.Zone))
    if not scene or not scene.Boundary then return end
    self:ResolveSafePoint()
    local character = self.Player and self.Player.Character
    local position = character and character.Position
    if insideBoundary(position, scene.Boundary) then
        self.Extra.travel.safePoint = { x = position.x, y = position.y, z = position.z }
    end
end

local function defaults(zone)
    return {
        inventory = { weapons = {}, magazines = {}, selection = { slot = nil, bait = nil,
            weapon = nil, held = { kind = nil, id = nil, slot = nil } } },
        growth = { upgrades = {}, purchases = {}, potions = {} },
        survival = { health = game_cfg.vitals.MaxHealth, hunger = game_cfg.vitals.MaxHunger,
            weakRemaining = 0, dyingRemaining = 0, deadRemaining = 0, dying = false, dead = false },
        collection = { weights = {}, unlocked = {} }, quest = { step = 1, count = 0 },
        story = { read = {} }, travel = { arrived = {}, zone = game_cfg.ResolveZoneId(zone), safePoint = {} },
        lottery = { pity = 0 }, achievements = {}, recovery = {}, cooldowns = {},
        party = { id = 0 },
    }
end

local function serializable(value, seen, depth)
    local kind = type(value)
    if kind == 'number' then return value == value and math.abs(value) < math.huge end
    if kind == 'string' then return #value <= 16384 end
    if kind == 'boolean' or kind == 'nil' then return true end
    if kind ~= 'table' or depth > 12 or seen[value] then return false end
    seen[value] = true
    local count = 0
    for key, child in pairs(value) do
        count = count + 1
        if count > 4096 or (type(key) ~= 'string' and not integer(key, 1))
            or not serializable(child, seen, depth + 1) then return false end
    end
    seen[value] = nil
    return true
end

local function hasIndividualMult(itemId)
    if game_cfg.Fish[itemId] then return true end
    for _, fish in pairs(game_cfg.Fish) do
        for _, drop in ipairs(fish.Drops or {}) do
            if drop.ItemId == itemId then return true end
        end
    end
    return false
end

function player_data.New(player, onItemBarChanged)
    return setmetatable({ Player = player, Inited = false, OnItemBarChanged = onItemBarChanged }, player_data)
end

function player_data:Init(waitForLoad)
    if not self.Player or self.Inited then return end
    if waitForLoad then self.LoadState = 'pending' return end
    self.LoadState = 'ready'
    local items = {}
    local backpack = {}
    local bait = {}
    local debug = game_cfg.Debug
    for _, grant in ipairs(debug and debug.Enabled and debug.InitialGrants or {}) do
        if grant.containerId == game_cfg.Items.ContainerId.ItemBar then
            local target = #items < game_cfg.Items.InitialItemBarSlots and items or backpack
            target[#target + 1] = {
                itemId = grant.itemId,
                count = grant.count,
                containerId = target == items and game_cfg.Items.ContainerId.ItemBar or game_cfg.Items.ContainerId.Backpack,
            }
        elseif grant.containerId == game_cfg.Items.ContainerId.Bait then
            bait[grant.itemId] = (bait[grant.itemId] or 0) + grant.count
        end
    end
    self.data = {
        FishCoin = 0,
        Containers = { [game_cfg.Items.ContainerId.ItemBar] = items, [game_cfg.Items.ContainerId.Backpack] = backpack },
        UpgradeLevel = 0,
        Bait = bait,
        Weapons = {},
        SelectedSlot = nil,
        SelectedBait = nil,
        SelectedWeapon = nil,
        Progress = {},
        Zone = game_cfg.Ferry.HomeZone,
    }
    self.Extra = defaults(self.data.Zone)
    self.SaveMeta = { epoch = 0, revision = 0, sequence = 0, floor = 0, operations = {} }
    self.Inited = true
    self.Revision = 0
    self:Sync()
end

function player_data:CompleteLoad(snapshot)
    if not self.Player then return false end
    if snapshot ~= nil and not self:IsValidSave(snapshot) then
        self.LoadState = 'failed'
        return false
    end
    self:Init()
    if snapshot then self:ApplySave(snapshot) end
    self.LoadState = 'ready'
    return true
end

function player_data:Migrate(snapshot)
    if type(snapshot) ~= 'table' or (snapshot.v ~= 1 and snapshot.v ~= 2)
        or not serializable(snapshot, {}, 0) then return nil, '未知版本或不可序列化数据' end
    local saved = stripArrayMeta(snapshot, 'save')
    if not integer(saved.coin, 0) or not integer(saved.up, 0, #game_cfg.Items.UpgradePrices)
        or type(saved.zone) ~= 'string' or saved.zone == '' or type(saved.bait) ~= 'table' then
        return nil, '基础字段损坏'
    end
    local bait = {}
    for id, count in pairs(saved.bait) do
        local mapped = game_cfg.Items.LegacyIdMap[id] or id
        local def = game_cfg.Items.Definitions[mapped]
        if not def or def.Container ~= game_cfg.Items.ContainerId.Bait or not integer(count, 0) then
            return nil, '鱼饵字段损坏'
        end
        bait[mapped] = (bait[mapped] or 0) + count
    end
    saved.bait = bait
    local capacity = game_cfg.Items.InitialBackpackSlots + saved.up * game_cfg.Items.BackpackSlotsPerUpgrade
    if saved.up == #game_cfg.Items.UpgradePrices then capacity = game_cfg.Items.MaxBackpackSlots end
    for _, pair in ipairs({ { saved.bar, game_cfg.Items.InitialItemBarSlots + saved.up }, { saved.bp, capacity } }) do
        local packed, max = pair[1], pair[2]
        if type(packed) ~= 'table' then return nil, '库存缺失' end
        local seen, count = {}, 0
        for key, slot in pairs(packed) do
            count = count + 1
            if not integer(key, 1, max) or type(slot) ~= 'table' then return nil, '库存结构损坏' end
            slot.id = game_cfg.Items.LegacyIdMap[slot.id] or slot.id
            local def = game_cfg.Items.Definitions[slot.id]
            if not def or def.Container == game_cfg.Items.ContainerId.Bait
                or not integer(slot.i, 1, max) or seen[slot.i] or not integer(slot.n, 1, 1)
                or slot.m ~= nil and (type(slot.m) ~= 'number' or slot.m < 1 or slot.m > 2)
                or slot.k ~= nil and (type(slot.k) ~= 'number' or slot.k <= 0 or slot.k ~= slot.k
                    or slot.k >= math.huge) then
                return nil, '物品实例损坏'
            end
            seen[slot.i] = true
        end
        for i = 1, count do if packed[i] == nil then return nil, '库存序列不连续' end end
    end
    if saved.v == 1 then
        saved.extra = defaults(saved.zone)
        saved.meta = { epoch = 0, revision = 0, sequence = 0, floor = 0, operations = {} }
    else
        local meta, extra = saved.meta, saved.extra
        if type(meta) ~= 'table' or not integer(meta.epoch, 0) or not integer(meta.revision, 0)
            or not integer(meta.sequence, 0) or not integer(meta.floor, 0, meta.sequence)
            or type(meta.operations) ~= 'table' or #meta.operations > 64 or type(extra) ~= 'table' then
            return nil, '持久身份损坏'
        end
        if extra.party == nil then extra.party = defaults(saved.zone).party end
        for name in pairs(defaults(saved.zone)) do
            if type(extra[name]) ~= 'table' then return nil, '扩展字段缺失 ' .. name end
        end
        if not integer(extra.party.id, 0) then return nil, '队伍字段损坏' end
        if extra.party.epoch ~= nil and type(extra.party.epoch) ~= 'string' then
            return nil, '队伍纪元损坏'
        end
        if type(extra.inventory.selection) ~= 'table' or type(extra.travel.arrived) ~= 'table'
            or type(extra.travel.safePoint) ~= 'table' or type(extra.inventory.weapons) ~= 'table' then return nil, '扩展字段损坏' end
        local held = extra.inventory.selection.held
        if type(held) ~= 'table' or held.kind ~= nil and held.kind ~= 'slot' and held.kind ~= 'weapon'
            or held.id ~= nil and type(held.id) ~= 'string'
            or held.slot ~= nil and not integer(held.slot, 1, max) then return nil, '手持状态损坏' end
        for itemId, count in pairs(extra.inventory.weapons) do
            local def = game_cfg.Items.Definitions[itemId]
            if not def or def.Type ~= '近战武器' and def.Type ~= '远程武器'
                or not integer(count, 1) then return nil, '武器库存损坏' end
        end
        local growth = extra.growth
        if type(growth.upgrades) ~= 'table' or type(growth.purchases) ~= 'table' then
            return nil, '成长字段损坏'
        end
        for kind, level in pairs(growth.upgrades) do
            local spec = game_cfg.Shop.UpgradeKinds[kind]
            if not spec or not integer(level, 0, spec.MaxLevel) then return nil, '升级等级损坏' end
        end
        for key, count in pairs(growth.purchases) do
            if type(key) ~= 'string' or not integer(count, 0) then return nil, '购买次数损坏' end
        end
        local last = meta.floor
        for _, op in ipairs(meta.operations) do
            if type(op) ~= 'table' or not integer(op.sequence, last + 1, meta.sequence)
                or type(op.id) ~= 'string' or type(op.kind) ~= 'string' or type(op.result) ~= 'table'
                or op.requestKey ~= nil and type(op.requestKey) ~= 'string' then
                return nil, '操作日志损坏'
            end
            last = op.sequence
        end
    end
    saved.v = 2
    return saved
end

function player_data:IsValidSave(snapshot)
    return self:Migrate(snapshot) ~= nil
end

function player_data:Serialize()
    if not self.Inited then return nil end
    self:NoteSafePoint()
    local function pack(containerId)
        local out = {}
        for index, entry in pairs(self.data.Containers[containerId]) do
            if entry and entry.count > 0 then
                local slot = copy(entry.saved or {})
                slot.i, slot.id, slot.n, slot.m = index, entry.itemId, entry.count, entry.mult
                out[#out + 1] = slot
            end
        end
        table.sort(out, function(a, b) return a.i < b.i end)
        return out
    end
    local bait = {}
    for itemId, count in pairs(self.data.Bait) do bait[itemId] = count end
    self.Extra.inventory.selection.slot = self.data.SelectedSlot
    self.Extra.inventory.selection.bait = self.data.SelectedBait
    self.Extra.inventory.selection.weapon = self.data.SelectedWeapon
    self.Extra.inventory.weapons = copy(self.data.Weapons)
    self.Extra.travel.zone = game_cfg.ResolveZoneId(self.data.Zone)
    return {
        v = 2,
        extra = copy(self.Extra),
        meta = copy(self.SaveMeta),
        coin = self.data.FishCoin,
        bar = pack(game_cfg.Items.ContainerId.ItemBar),
        bp = pack(game_cfg.Items.ContainerId.Backpack),
        bait = bait,
        up = self.data.UpgradeLevel,
        zone = self.data.Zone,
    }
end

function player_data:ApplySave(snapshot)
    if not self.Inited then return false end
    local saved, reason = self:Migrate(snapshot)
    if not saved then
        print('[player_data] 拒绝存档', self.Player and self.Player.UserId, reason)
        return false
    end
    local function unpack(packed, containerId)
        local items = {}
        for _, slot in ipairs(packed) do
            items[slot.i] = { itemId = slot.id, count = slot.n, mult = slot.m, cooked = slot.k,
                containerId = containerId, saved = copy(slot) }
        end
        return items
    end
    self.data.FishCoin = saved.coin
    self.data.UpgradeLevel, self.data.Zone = saved.up, saved.zone
    self.data.Bait = saved.bait
    self.data.Containers = {
        [game_cfg.Items.ContainerId.ItemBar] = unpack(saved.bar, game_cfg.Items.ContainerId.ItemBar),
        [game_cfg.Items.ContainerId.Backpack] = unpack(saved.bp, game_cfg.Items.ContainerId.Backpack),
    }
    self.Extra, self.SaveMeta = saved.extra, saved.meta
    self.data.SelectedSlot = self.Extra.inventory.selection.slot
    self.data.SelectedBait = self.Extra.inventory.selection.bait
    self.data.SelectedWeapon = self.Extra.inventory.selection.weapon
    self.data.Weapons = copy(self.Extra.inventory.weapons)
    self:SanitizeHeld()
    self.Revision = (self.Revision or 0) + 1
    self:Sync()
    return true
end

function player_data:ItemBarCapacity()
    return game_cfg.Items.InitialItemBarSlots + self.data.UpgradeLevel
end

function player_data:BackpackCapacity()
    local level = self.data.UpgradeLevel
    local capacity = game_cfg.Items.InitialBackpackSlots + level * game_cfg.Items.BackpackSlotsPerUpgrade
    if level == #game_cfg.Items.UpgradePrices then capacity = game_cfg.Items.MaxBackpackSlots end
    return capacity
end

function player_data:ApplyGMPatch(patch)
    if not self.Inited or type(patch) ~= 'table' then return false, '状态尚未就绪' end
    local function int(n, min, max)
        return type(n) == 'number' and n == math.floor(n) and n >= min and n <= max
    end
    local coin = patch.coin == nil and self.data.FishCoin or patch.coin
    local level = patch.upgradeLevel == nil and self.data.UpgradeLevel or patch.upgradeLevel
    if not int(coin, 0, math.maxinteger) or not int(level, 0, #game_cfg.Items.UpgradePrices) then
        return false, '金币或扩容等级无效'
    end
    if patch.slots ~= nil and type(patch.slots) ~= 'table' then return false, '格位操作无效' end
    local ids = game_cfg.Items.ContainerId
    local containers = {}
    for _, id in ipairs({ ids.ItemBar, ids.Backpack }) do
        local copy = {}
        for index, entry in pairs(self.data.Containers[id]) do copy[index] = entry end
        containers[id] = copy
    end
    local barCount = game_cfg.Items.InitialItemBarSlots + level
    local backpackCount = game_cfg.Items.InitialBackpackSlots + level * game_cfg.Items.BackpackSlotsPerUpgrade
    if level == #game_cfg.Items.UpgradePrices then backpackCount = game_cfg.Items.MaxBackpackSlots end
    local seen = {}
    for key, edit in pairs(patch.slots or {}) do
        if type(key) ~= 'number' or not int(key, 1, 100) or type(edit) ~= 'table' then
            return false, '格位操作无效'
        end
        local id = edit.container
        local max = id == ids.ItemBar and barCount or id == ids.Backpack and backpackCount
        local oldMax = id == ids.ItemBar and self:ItemBarCapacity()
            or id == ids.Backpack and self:BackpackCapacity()
        if not max or not int(edit.index, 1, edit.clear == true and math.max(max, oldMax) or max) then
            return false, '格号无效'
        end
        local unique = id .. ':' .. edit.index
        if seen[unique] then return false, '格号重复' end
        seen[unique] = true
        if edit.clear == true and edit.itemId == nil and edit.count == nil and edit.mult == nil then
            containers[id][edit.index] = nil
        else
            local definition = type(edit.itemId) == 'string' and game_cfg.Items.Definitions[edit.itemId]
            if edit.clear ~= nil or not definition or definition.Container == ids.Bait
                or not int(edit.count, 1, 1) then return false, '格位物品或件数无效' end
            local mult = edit.mult
            if mult ~= nil and (type(mult) ~= 'number' or mult < 1 or mult > 2
                or math.abs(mult * 100 - math.floor(mult * 100 + 0.5)) > 1e-7
                or not hasIndividualMult(edit.itemId)) then return false, '个体倍率无效' end
            containers[id][edit.index] = { itemId = edit.itemId, count = 1, containerId = id, mult = mult }
        end
    end
    for _, pair in ipairs({ { ids.ItemBar, barCount }, { ids.Backpack, backpackCount } }) do
        for index, entry in pairs(containers[pair[1]]) do
            if entry and (type(index) ~= 'number' or index > pair[2]) then
                return false, '缩容将挤掉已有物品'
            end
        end
    end
    self:ChangeCoin(coin - self.data.FishCoin, function(data)
        data.UpgradeLevel = level
        data.Containers = containers
    end, 'gm-state')
    return true
end

local function copySlots(items, capacity)
    local slots = {}
    for index = 1, capacity do
        local entry = items[index]
        if entry and entry.count > 0 then
            slots[index] = { itemId = entry.itemId, count = entry.count,
                containerId = entry.containerId, mult = entry.mult, cooked = entry.cooked }
        end
    end
    return slots
end

function player_data:GetItemBarSnapshot()
    if not self.Inited then return nil end
    local bait = {}
    for itemId, count in pairs(self.data.Bait) do
        bait[itemId] = count
    end
    local bosses = {}
    for itemId in pairs(game_cfg.Casting.BossBait or {}) do bosses[#bosses + 1] = itemId end
    table.sort(bosses)
    for _, itemId in ipairs(bosses) do
        local count = self:ItemBarItemCount(itemId)
        if count >= 1 then bait[itemId] = count end
    end
    return {
        slots = copySlots(self.data.Containers[game_cfg.Items.ContainerId.ItemBar], self:ItemBarCapacity()),
        slotCount = self:ItemBarCapacity(),
        backpack = copySlots(self.data.Containers[game_cfg.Items.ContainerId.Backpack], self:BackpackCapacity()),
        backpackCount = self:BackpackCapacity(),
        upgradeLevel = self.data.UpgradeLevel,
        bait = bait,
        coin = self.data.FishCoin,
        selectedSlot = self.data.SelectedSlot,
        selectedBait = self.data.SelectedBait,
        weapons = copy(self.data.Weapons),
        selectedWeapon = self.data.SelectedWeapon,
        held = copy(self.Extra.inventory.selection.held),
    }
end

function player_data:SelectSlot(index)
    if not self.Inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local entry = self.data.Containers[game_cfg.Items.ContainerId.ItemBar][index]
    self.data.SelectedSlot = self.data.SelectedSlot ~= index and entry and entry.count > 0 and index or nil
    return true
end

function player_data:HoldSlot(index)
    if not self.Inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local held = self.Extra.inventory.selection.held
    if held.kind == 'slot' and held.slot == index then
        held.kind, held.id, held.slot = nil, nil, nil
        return true
    end
    local entry = self.data.Containers[game_cfg.Items.ContainerId.ItemBar][index]
    if not entry or entry.count <= 0 then return false end
    held.kind, held.id, held.slot = 'slot', entry.itemId, index
    return true
end

function player_data:SanitizeHeld()
    local held = self.Extra.inventory.selection.held
    if held.kind == 'slot' then
        local entry = held.slot and self.data.Containers[game_cfg.Items.ContainerId.ItemBar][held.slot]
        if not entry or entry.count <= 0 or entry.itemId ~= held.id then
            held.kind, held.id, held.slot = nil, nil, nil
        end
    elseif held.kind == 'weapon' then
        if self:WeaponCount(held.id) < 1 then
            held.kind, held.id, held.slot = nil, nil, nil
        end
    elseif held.kind ~= nil then
        held.kind, held.id, held.slot = nil, nil, nil
    end
end

local function isWeapon(itemId)
    local definition = type(itemId) == 'string' and game_cfg.Items.Definitions[itemId]
    return definition ~= nil and (definition.Type == '近战武器' or definition.Type == '远程武器')
end

function player_data:ShopUpgradeLevel(kind)
    if kind == 'backpack' then
        return self.Inited and self.data.UpgradeLevel or 0
    end
    if not self.Inited then return 0 end
    local level = self.Extra.growth.upgrades[kind]
    return integer(level, 0) and level or 0
end

function player_data:PurchaseCount(number)
    if not self.Inited or not integer(number, 1) then return 0 end
    return self.Extra.growth.purchases[tostring(number)] or 0
end

function player_data:NotePurchase(number)
    if not self.Inited or not integer(number, 1) then return false end
    local key = tostring(number)
    self.Extra.growth.purchases[key] = (self.Extra.growth.purchases[key] or 0) + 1
    return true
end

function player_data:CanShopUpgrade(upgrade)
    if type(upgrade) ~= 'table' or type(upgrade.kind) ~= 'string' then return false, 'bad' end
    local spec = game_cfg.Shop.UpgradeKinds[upgrade.kind]
    if not spec or not integer(upgrade.level, 1, spec.MaxLevel) then return false, 'bad' end
    local current = self:ShopUpgradeLevel(upgrade.kind)
    if current >= spec.MaxLevel then return false, 'max' end
    if upgrade.level ~= current + 1 then return false, 'level' end
    return true
end

function player_data:ApplyShopUpgrade(upgrade)
    local ok = self:CanShopUpgrade(upgrade)
    if not ok then return false end
    if upgrade.kind == 'backpack' then
        self.data.UpgradeLevel = upgrade.level
    else
        self.Extra.growth.upgrades[upgrade.kind] = upgrade.level
    end
    return true
end

function player_data:WeaponDamageScale(kind)
    if not self.Inited then return 1 end
    return game_cfg.Shop.DamageScale(kind, self:ShopUpgradeLevel(kind)) or 1
end

function player_data:MagazineSize(base)
    if not self.Inited or type(base) ~= 'number' then return base end
    return game_cfg.Shop.MagazineSize(base, self:ShopUpgradeLevel('magazine'))
end

function player_data:GrantWeapon(itemId, count)
    if not self.Inited or not isWeapon(itemId)
        or not integer(count, 1) then return false end
    self:UpdateData(function(data)
        data.Weapons[itemId] = (data.Weapons[itemId] or 0) + count
    end, true)
    return true
end

function player_data:WeaponCount(itemId)
    return self.Inited and self.data.Weapons[itemId] or 0
end

function player_data:PotionCount(itemId)
    return self.Inited and self.Extra.growth.potions[itemId] or 0
end

function player_data:ConsumeWeapon(itemId, count)
    if not self.Inited or not integer(count, 1) or self:WeaponCount(itemId) < count then return false end
    self:UpdateData(function(data)
        data.Weapons[itemId] = data.Weapons[itemId] - count
        if data.Weapons[itemId] == 0 then data.Weapons[itemId] = nil end
        if data.SelectedWeapon == itemId and data.Weapons[itemId] == nil then data.SelectedWeapon = nil end
    end, true)
    return true
end

function player_data:SelectWeapon(itemId)
    if not self.Inited then return false end
    if itemId == nil then
        self.data.SelectedWeapon = nil
        self:PublishItemBar()
        return true
    end
    if not isWeapon(itemId) or self:WeaponCount(itemId) < 1 then return false end
    self.data.SelectedWeapon = self.data.SelectedWeapon ~= itemId and itemId or nil
    self:PublishItemBar()
    return true
end

function player_data:HoldWeapon(itemId)
    if not self.Inited then return false end
    local held = self.Extra.inventory.selection.held
    if held.kind == 'weapon' and held.id == itemId then
        held.kind, held.id, held.slot = nil, nil, nil
        return true
    end
    if not isWeapon(itemId) or self:WeaponCount(itemId) < 1 then return false end
    held.kind, held.id, held.slot = 'weapon', itemId, nil
    return true
end

function player_data:RestoreSlot(index)
    if not self.Inited or type(index) ~= 'number' then return false end
    local entry = self.data.Containers[game_cfg.Items.ContainerId.ItemBar][index]
    if not entry or entry.count < 1 or entry.itemId ~= game_cfg.Items.Id.StarterRod then return false end
    self.data.SelectedSlot = index
    return true
end

local function hasBait(data, itemId)
    local count = data.Bait[itemId]
    return type(count) == 'number' and count >= 1
end

function player_data:SetZone(zone)
    if not self.Inited or type(zone) ~= 'string' or zone == '' then return false end
    self:UpdateData(function(data) data.Zone = zone end, false)
    return true
end

function player_data:ItemBarItemCount(itemId)
    if not self.Inited then return 0 end
    local total = 0
    for _, entry in pairs(self.data.Containers[game_cfg.Items.ContainerId.ItemBar]) do
        if entry.itemId == itemId and entry.count > 0 then total = total + entry.count end
    end
    return total
end

function player_data:ItemCount(itemId)
    if not self.Inited then return 0 end
    local total = 0
    for _, container in pairs(self.data.Containers) do
        for _, entry in pairs(container) do
            if entry.itemId == itemId and entry.count > 0 then total = total + entry.count end
        end
    end
    return total
end

function player_data:ConsumeItemBarItem(itemId)
    if not self.Inited then return false end
    local items = self.data.Containers[game_cfg.Items.ContainerId.ItemBar]
    for index = 1, self:ItemBarCapacity() do
        local entry = items[index]
        if entry and entry.itemId == itemId and entry.count > 0 then
            self:UpdateData(function()
                items[index] = nil
            end, true)
            return true
        end
    end
    return false
end

function player_data:ConsumeItem(itemId)
    if not self.Inited then return false end
    for _, container in ipairs({
        { game_cfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { game_cfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        local items = self.data.Containers[container[1]]
        for index = 1, container[2] do
            local entry = items[index]
            if entry and entry.itemId == itemId and entry.count > 0 then
                self:UpdateData(function()
                    items[index] = nil
                end, true)
                return true
            end
        end
    end
    return false
end

function player_data:HasBait(itemId)
    if not self.Inited or type(itemId) ~= 'string' then return false end
    if hasBait(self.data, itemId) then return true end
    local bossBait = game_cfg.Casting.BossBait
    return bossBait ~= nil and bossBait[itemId] ~= nil and self:ItemBarItemCount(itemId) >= 1
end

function player_data:SelectBait(itemId)
    if not self.Inited then return false end
    if itemId == nil then
        self.data.SelectedBait = nil
        return true
    end
    if type(itemId) ~= 'string' or not self:HasBait(itemId) then return false end
    self.data.SelectedBait = itemId
    return true
end

function player_data:EatBait(itemId)
    if not self.Inited or type(itemId) ~= 'string' or not hasBait(self.data, itemId) then return false end
    self:UpdateData(function(data)
        data.Bait[itemId] = data.Bait[itemId] - 1
    end, true)
    return true
end

function player_data:EatSlot(index)
    if not self.Inited or type(index) ~= 'number' or index ~= self.data.SelectedSlot then return nil end
    local items = self.data.Containers[game_cfg.Items.ContainerId.ItemBar]
    local entry = items[index]
    local definition = entry and entry.count > 0 and game_cfg.Items.Definitions[entry.itemId]
    if not definition or type(definition.EatPercent) ~= 'number' then return nil end
    self:UpdateData(function(data)
        data.Containers[game_cfg.Items.ContainerId.ItemBar][index] = nil
    end, true)
    return entry.itemId
end

function player_data:ConsumeSelectedBait()
    if not self.Inited then return false, nil end
    local itemId = self.data.SelectedBait
    if not itemId then return true, nil end
    local bossBait = game_cfg.Casting.BossBait
    if bossBait and bossBait[itemId] then
        if self:ConsumeItemBarItem(itemId) then return true, itemId end
        self.data.SelectedBait = nil
        self:PublishItemBar()
        return false, nil
    end
    if not hasBait(self.data, itemId) then
        self.data.SelectedBait = nil
        self:PublishItemBar()
        return false, nil
    end
    self:UpdateData(function(data)
        data.Bait[itemId] = data.Bait[itemId] - 1
    end, true)
    return true, itemId
end

function player_data:AddItem(itemId, mult, cooked)
    if not self.Inited or type(itemId) ~= 'string' then return false end
    for _, container in ipairs({
        { game_cfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { game_cfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        local items = self.data.Containers[container[1]]
        for index = 1, container[2] do
            local entry = items[index]
            if not entry or entry.count <= 0 then
                self:UpdateData(function()
                    items[index] = { itemId = itemId, count = 1, containerId = container[1], mult = mult,
                        cooked = cooked, saved = cooked and { k = cooked } or nil }
                end, true)
                return true
            end
        end
    end
    return false
end

function player_data:AddBait(itemId, count)
    local definition = type(itemId) == 'string' and game_cfg.Items.Definitions[itemId]
    if not self.Inited or not definition or definition.Container ~= game_cfg.Items.ContainerId.Bait
        or type(count) ~= 'number' or count < 1 or count ~= math.floor(count) then return false end
    self:UpdateData(function(data)
        data.Bait[itemId] = (data.Bait[itemId] or 0) + count
    end, true)
    return true
end

function player_data:CanGrant(itemId, count)
    local definition = type(itemId) == 'string' and game_cfg.Items.Definitions[itemId]
    if not self.Inited or not definition or type(count) ~= 'number' or count < 1
        or count ~= math.floor(count) then return false, 'bad' end
    if definition.Container == game_cfg.Items.ContainerId.Bait then return true end
    if isWeapon(itemId) then return true end
    local free = 0
    for _, container in ipairs({
        { game_cfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { game_cfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        local items = self.data.Containers[container[1]]
        for index = 1, container[2] do
            if not items[index] or items[index].count <= 0 then free = free + 1 end
        end
    end
    if free < count then return false, 'full' end
    return true
end

function player_data:GrantItem(itemId, count)
    if isWeapon(itemId) then return self:GrantWeapon(itemId, count) end
    local ok, reason = self:CanGrant(itemId, count)
    if not ok then return false, reason end
    if game_cfg.Items.Definitions[itemId].Container == game_cfg.Items.ContainerId.Bait then
        return self:AddBait(itemId, count)
    end
    for _ = 1, count do self:AddItem(itemId) end
    return true
end

local function isPositiveInt(n)
    return type(n) == 'number' and n >= 1 and n == math.floor(n)
end

function player_data:ChangeCoin(delta, apply, reason)
    if not self.Inited then return false end
    local balance = self.data.FishCoin + delta
    if balance < 0 then
        print('[player_data] 金币不足', self.Player and self.Player.UserId, reason, delta, 'FishCoin=' .. tostring(self.data.FishCoin))
        return false
    end
    self:UpdateData(function(data)
        if apply then apply(data) end
        data.FishCoin = balance
    end, true)
    print('[player_data] 金币' .. (delta >= 0 and '收入' or '支出'), self.Player and self.Player.UserId, reason,
        (delta >= 0 and '+' or '') .. tostring(delta), 'FishCoin=' .. tostring(balance))
    return true
end

function player_data:AddCoin(amount, apply, reason)
    if not isPositiveInt(amount) then return false end
    return self:ChangeCoin(amount, apply, reason)
end

function player_data:SpendCoin(amount, apply, reason)
    if not isPositiveInt(amount) then return false end
    return self:ChangeCoin(-amount, apply, reason)
end

function player_data:ExchangeSlot(slot, product)
    local items = self.Inited and self.data.Containers[game_cfg.Items.ContainerId.ItemBar]
    local kept = type(slot) == 'number' and items and items[slot]
    if not kept or kept.count <= 0 or type(product) ~= 'string' then return false, 'bad' end
    if not self:CanGrant(product, 1) then return false, 'full' end
    self:UpdateData(function(d)
        d.Containers[game_cfg.Items.ContainerId.ItemBar][slot] = nil
    end, false)
    if not self:AddItem(product) then
        self:UpdateData(function(d)
            d.Containers[game_cfg.Items.ContainerId.ItemBar][slot] = kept
        end, true)
        print('[player_data] 兑换发放失败，已退回原物品', self.Player and self.Player.UserId, kept.itemId, product)
        return false, 'full'
    end
    return true
end

function player_data:MoveSlot(from, index, target, slot)
    if not self.Inited then return false end
    local ids = game_cfg.Items.ContainerId
    local function capacity(id)
        return id == ids.ItemBar and self:ItemBarCapacity() or id == ids.Backpack and self:BackpackCapacity()
    end
    local sourceMax, targetMax = capacity(from), capacity(target)
    if not sourceMax or not targetMax or not integer(index, 1, sourceMax)
        or not integer(slot, 1, targetMax) or from == target and index == slot then return false end
    local source, destination = self.data.Containers[from], self.data.Containers[target]
    if not source[index] then return false end
    self:UpdateData(function()
        source[index], destination[slot] = destination[slot], source[index]
        if source[index] then source[index].containerId = from end
        destination[slot].containerId = target
        if from == ids.ItemBar and self.data.SelectedSlot == index
            or target == ids.ItemBar and self.data.SelectedSlot == slot then
            self.data.SelectedSlot = nil
        end
    end, true)
    return true
end

function player_data:MoveToItemBar(index)
    if not self.Inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:BackpackCapacity() then return false end
    local backpack = self.data.Containers[game_cfg.Items.ContainerId.Backpack]
    local entry = backpack[index]
    if not entry then return false end
    local bar = self.data.Containers[game_cfg.Items.ContainerId.ItemBar]
    for slot = 1, self:ItemBarCapacity() do
        if not bar[slot] or bar[slot].count <= 0 then
            self:UpdateData(function()
                backpack[index] = nil
                bar[slot] = entry
                entry.containerId = game_cfg.Items.ContainerId.ItemBar
            end, true)
            return true
        end
    end
    return false
end

function player_data:UpgradeStorage()
    local price = game_cfg.Items.UpgradePrices[self.data.UpgradeLevel + 1]
    if not self.Inited or not price then return false, 'max' end
    if not self:SpendCoin(price, function(data)
        data.UpgradeLevel = data.UpgradeLevel + 1
    end, 'storage-upgrade') then return false, 'coin' end
    return true, price
end

function player_data:DiscardSlot(index)
    if not self.Inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local items = self.data.Containers[game_cfg.Items.ContainerId.ItemBar]
    if not items[index] then return false end
    self:UpdateData(function()
        items[index] = nil
    end, false)
    return true
end

function player_data:PublishItemBar()
    if self.OnItemBarChanged then
        self.OnItemBarChanged(self.Player, self)
    end
end

function player_data:UpdateData(updateCallBack, doSync)
    if not self.Inited or not updateCallBack then return end
    self.Touched = true
    updateCallBack(self.data)
    self.Revision = (self.Revision or 0) + 1
    local selected = self.data.SelectedSlot
    local entry = selected and self.data.Containers[game_cfg.Items.ContainerId.ItemBar][selected]
    if selected and (not entry or entry.count <= 0) then self.data.SelectedSlot = nil end
    local baitId = self.data.SelectedBait
    if baitId and not self:HasBait(baitId) then self.data.SelectedBait = nil end
    self:SanitizeHeld()
    if doSync then
        self:Sync()
        self:PublishItemBar()
    end
end

function player_data:Sync()
    if not self.Player or not self.Inited then return end
    self.Player:SetAttribute('FishCoin', self.data.FishCoin)
end

function player_data:Destroy()
    self.Player = nil
    self.data = nil
    self.OnItemBarChanged = nil
    self.Inited = false
    self.SaveMeta = nil
    self.Revision = nil
end

function player_data:PersonalBestScaled(fishId)
    if not self.Inited or type(fishId) ~= 'string' then return nil end
    local bag = self.Extra and self.Extra.collection
    local weight = bag and bag.weights and bag.weights[fishId]
    if type(weight) ~= 'number' then return nil end
    return records.Scale(weight)
end

return player_data
