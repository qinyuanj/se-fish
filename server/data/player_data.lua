local DeepCopy = require('common.deep_copy')
local GameCfg = require('common.game_cfg')
local Records = require('common.records')

local PlayerData = {}
PlayerData.__index = PlayerData

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
        print('[PlayerData] 数组长度标记不一致，按实际条数继续', path or '?',
            '标记=' .. declared, '实际=' .. actual)
    end
    seen[value] = nil
    return out
end
PlayerData.strip_array_meta = stripArrayMeta

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

function PlayerData:ResolveSafePoint()
    local scene = GameCfg.zone_scene(GameCfg.resolve_zone_id(self.data.Zone))
    if not scene or not scene.Boundary or not finitePoint(scene.SafePoint) then return nil, false end
    local mark = self.extra.travel.safePoint
    if insideBoundary(mark, scene.Boundary) then
        return { x = mark.x, y = mark.y, z = mark.z }, false
    end
    local fallback = { x = scene.SafePoint.x, y = scene.SafePoint.y, z = scene.SafePoint.z }
    self.extra.travel.safePoint = fallback
    return fallback, true
end

function PlayerData:NoteSafePoint()
    if not self.inited then return end
    local scene = GameCfg.zone_scene(GameCfg.resolve_zone_id(self.data.Zone))
    if not scene or not scene.Boundary then return end
    self:ResolveSafePoint()
    local character = self.Player and self.Player.Character
    local position = character and character.Position
    if position and insideBoundary(position, scene.Boundary) then
        self.extra.travel.safePoint = { x = position.x, y = position.y, z = position.z }
    end
end

local function defaults(zone)
    return {
        inventory = { weapons = {}, magazines = {}, selection = { slot = nil, bait = nil,
            weapon = nil, held = { kind = nil, id = nil, slot = nil } } },
        growth = { upgrades = {}, purchases = {}, potions = {} },
        survival = { health = GameCfg.Vitals.MaxHealth, hunger = GameCfg.Vitals.MaxHunger,
            weakRemaining = 0, dyingRemaining = 0, deadRemaining = 0, dying = false, dead = false },
        collection = { weights = {}, unlocked = {} }, quest = { step = 1, count = 0 },
        story = { read = {} }, travel = { arrived = {}, zone = GameCfg.resolve_zone_id(zone), safePoint = {} },
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
    if GameCfg.Fish[itemId] then return true end
    for _, fish in pairs(GameCfg.Fish) do
        for _, drop in ipairs(fish.Drops or {}) do
            if drop.ItemId == itemId then return true end
        end
    end
    return false
end

function PlayerData.new(player, onItemBarChanged)
    return setmetatable({ Player = player, inited = false, on_item_bar_changed = onItemBarChanged }, PlayerData)
end

function PlayerData:Init(waitForLoad)
    if not self.Player or self.inited then return end
    if waitForLoad then self.load_state = 'pending' return end
    self.load_state = 'ready'
    ---@type table[]
    local items = {}
    ---@type table[]
    local backpack = {}
    local bait = {}
    local debug = GameCfg.Debug
    for _, grant in ipairs(debug and debug.Enabled and debug.InitialGrants or {}) do
        if grant.containerId == GameCfg.Items.ContainerId.ItemBar then
            local target = #items < GameCfg.Items.InitialItemBarSlots and items or backpack
            target[#target + 1] = {
                itemId = grant.itemId,
                count = grant.count,
                containerId = target == items and GameCfg.Items.ContainerId.ItemBar or GameCfg.Items.ContainerId.Backpack,
            }
        elseif grant.containerId == GameCfg.Items.ContainerId.Bait then
            bait[grant.itemId] = (bait[grant.itemId] or 0) + grant.count
        end
    end
    self.data = {
        FishCoin = 0,
        containers = { [GameCfg.Items.ContainerId.ItemBar] = items, [GameCfg.Items.ContainerId.Backpack] = backpack },
        upgrade_level = 0,
        Bait = bait,
        weapons = {},
        selected_slot = nil,
        selected_bait = nil,
        selected_weapon = nil,
        Progress = {},
        Zone = GameCfg.Ferry.HomeZone,
    }
    self.extra = defaults(self.data.Zone)
    self.save_meta = { epoch = 0, revision = 0, sequence = 0, floor = 0, operations = {} }
    self.inited = true
    self.revision = 0
    self:Sync()
end

function PlayerData:CompleteLoad(snapshot)
    if not self.Player then return false end
    if snapshot ~= nil and not self:IsValidSave(snapshot) then
        self.load_state = 'failed'
        return false
    end
    self:Init()
    if snapshot then self:ApplySave(snapshot) end
    self.load_state = 'ready'
    return true
end

-- ===== 拆分前 PlayerData:Migrate 体内的分段：提到模块级，依赖显式传参 =====
-- 校验失败统一返回 false/nil, 原因；错误文案与拆分前逐字一致（ApplySave 会把原因打到日志）。
-- 分段只做一段校验：基础字段/库存/持久身份/扩展字段/成长/操作日志。

-- 版本与可序列化预检。
local function migratable(snapshot)
    return type(snapshot) == 'table' and (snapshot.v == 1 or snapshot.v == 2) and serializable(snapshot, {}, 0)
end

-- 个体倍率：可选字段，出现时须在 1..2 之间。
local function bad_mult(mult)
    return mult ~= nil and (type(mult) ~= 'number' or mult < 1 or mult > 2)
end

-- 熟度：可选字段，出现时须为有限正数。
local function bad_cooked(cooked)
    return cooked ~= nil and (type(cooked) ~= 'number' or cooked <= 0 or cooked ~= cooked or cooked >= math.huge)
end

-- 单个物品实例：ID 走旧号映射、容器合法、格号/件数/倍率/熟度合法、格号不重复（写回 slot.id）。
local function migrate_slot(slot, max, seen)
    slot.id = GameCfg.Items.LegacyIdMap[slot.id] or slot.id
    local def = GameCfg.Items.Definitions[slot.id]
    if not def or def.Container == GameCfg.Items.ContainerId.Bait
        or not integer(slot.i, 1, max) or seen[slot.i] or not integer(slot.n, 1, 1)
        or bad_mult(slot.m) or bad_cooked(slot.k) then
        return false, '物品实例损坏'
    end
    return true
end

-- 单个容器（bar/bp）：键在容量内、实例合法且格号不重复、格子序列连续。
local function migrate_container(packed, max)
    if type(packed) ~= 'table' then return false, '库存缺失' end
    local seen, total = {}, 0
    for key, slot in pairs(packed) do
        total = total + 1
        if not integer(key, 1, max) or type(slot) ~= 'table' then return false, '库存结构损坏' end
        local ok, reason = migrate_slot(slot, max, seen)
        if not ok then return false, reason end
        seen[slot.i] = true
    end
    for index = 1, total do if packed[index] == nil then return false, '库存序列不连续' end end
    return true
end

-- 背包容量：满级按最大格数，否则按每级增量累加。
local function backpack_capacity(level)
    if level == #GameCfg.Items.UpgradePrices then return GameCfg.Items.MaxBackpackSlots end
    return GameCfg.Items.InitialBackpackSlots + level * GameCfg.Items.BackpackSlotsPerUpgrade
end

-- 基础字段与鱼饵：金币/扩容等级/区名/鱼饵表，鱼饵 ID 走旧号映射并按容器类型校验。
local function migrate_base(saved)
    if not integer(saved.coin, 0) or not integer(saved.up, 0, #GameCfg.Items.UpgradePrices)
        or type(saved.zone) ~= 'string' or saved.zone == '' or type(saved.bait) ~= 'table' then
        return false, '基础字段损坏'
    end
    local bait = {}
    for id, count in pairs(saved.bait) do
        local mapped = GameCfg.Items.LegacyIdMap[id] or id
        local def = GameCfg.Items.Definitions[mapped]
        if not def or def.Container ~= GameCfg.Items.ContainerId.Bait or not integer(count, 0) then
            return false, '鱼饵字段损坏'
        end
        bait[mapped] = (bait[mapped] or 0) + count
    end
    saved.bait = bait
    return true
end

-- 两个容器：容量随扩容等级换算后逐个校验。
local function migrate_inventory(saved)
    local bar_capacity = GameCfg.Items.InitialItemBarSlots + saved.up
    for _, pair in ipairs({ { saved.bar, bar_capacity }, { saved.bp, backpack_capacity(saved.up) } }) do
        local ok, reason = migrate_container(pair[1], pair[2])
        if not ok then return false, reason end
    end
    return true
end

-- v1 存档没有持久身份与扩展字段，按默认值补齐。
local function migrate_v1(saved)
    saved.extra = defaults(saved.zone)
    saved.meta = { epoch = 0, revision = 0, sequence = 0, floor = 0, operations = {} }
    return true
end

-- 持久身份：epoch/revision/sequence/floor 单调、操作日志条数上限、扩展字段存在。
local function migrate_meta(saved)
    local meta, extra = saved.meta, saved.extra
    if type(meta) ~= 'table' or not integer(meta.epoch, 0) or not integer(meta.revision, 0)
        or not integer(meta.sequence, 0) or not integer(meta.floor, 0, meta.sequence)
        or type(meta.operations) ~= 'table' or #meta.operations > 64 or type(extra) ~= 'table' then
        return false, '持久身份损坏'
    end
    return true
end

-- 操作日志：序列在 [floor+1, sequence] 内递增、字段类型合法。
local function migrate_operations(meta)
    local last = meta.floor
    for _, op in ipairs(meta.operations) do
        if type(op) ~= 'table' or not integer(op.sequence, last + 1, meta.sequence)
            or type(op.id) ~= 'string' or type(op.kind) ~= 'string' or type(op.result) ~= 'table'
            or op.request_key ~= nil and type(op.request_key) ~= 'string' then
            return false, '操作日志损坏'
        end
        last = op.sequence
    end
    return true
end

-- 扩展字段外壳：分区默认子表齐备、队伍字段与手持/旅行/武器容器类型。
local function migrate_extra(saved)
    local extra = saved.extra
    if extra.party == nil then extra.party = defaults(saved.zone).party end
    for name in pairs(defaults(saved.zone)) do
        if type(extra[name]) ~= 'table' then return false, '扩展字段缺失 ' .. name end
    end
    if not integer(extra.party.id, 0) then return false, '队伍字段损坏' end
    if extra.party.epoch ~= nil and type(extra.party.epoch) ~= 'string' then
        return false, '队伍纪元损坏'
    end
    if type(extra.inventory.selection) ~= 'table' or type(extra.travel.arrived) ~= 'table'
        or type(extra.travel.safePoint) ~= 'table' or type(extra.inventory.weapons) ~= 'table' then
        return false, '扩展字段损坏'
    end
    return true
end

-- 手持状态：kind/id/slot 三项都是可选字段，出现时各自合法。
local function migrate_held(extra, saved)
    local held = extra.inventory.selection.held
    if type(held) ~= 'table' or held.kind ~= nil and held.kind ~= 'slot' and held.kind ~= 'weapon'
        or held.id ~= nil and type(held.id) ~= 'string'
        or held.slot ~= nil and not integer(held.slot, 1, GameCfg.Items.InitialItemBarSlots + saved.up) then
        return false, '手持状态损坏'
    end
    return true
end

-- 武器库存：物品是近战/远程武器且件数为正整数。
local function migrate_weapons(extra)
    for item_id, count in pairs(extra.inventory.weapons) do
        local def = GameCfg.Items.Definitions[item_id]
        if not def or def.Type ~= '近战武器' and def.Type ~= '远程武器' or not integer(count, 1) then
            return false, '武器库存损坏'
        end
    end
    return true
end

-- 成长：升级等级按 UpgradeKinds 上限、购买次数为非负整数。
local function migrate_growth(extra)
    local growth = extra.growth
    if type(growth.upgrades) ~= 'table' or type(growth.purchases) ~= 'table' then
        return false, '成长字段损坏'
    end
    for kind, level in pairs(growth.upgrades) do
        local spec = GameCfg.Shop.UpgradeKinds[kind]
        if not spec or not integer(level, 0, spec.MaxLevel) then return false, '升级等级损坏' end
    end
    for key, count in pairs(growth.purchases) do
        if type(key) ~= 'string' or not integer(count, 0) then return false, '购买次数损坏' end
    end
    return true
end

-- v2 存档：持久身份 → 扩展字段外壳 → 手持 → 武器 → 成长 → 操作日志，逐段校验。
local function migrate_v2(saved)
    local ok, reason = migrate_meta(saved)
    if not ok then return false, reason end
    ok, reason = migrate_extra(saved)
    if not ok then return false, reason end
    ok, reason = migrate_held(saved.extra, saved)
    if not ok then return false, reason end
    ok, reason = migrate_weapons(saved.extra)
    if not ok then return false, reason end
    ok, reason = migrate_growth(saved.extra)
    if not ok then return false, reason end
    return migrate_operations(saved.meta)
end

function PlayerData:Migrate(snapshot)
    if not migratable(snapshot) then return nil, '未知版本或不可序列化数据' end
    local saved = stripArrayMeta(snapshot, 'save')
    local ok, reason = migrate_base(saved)
    if not ok then return nil, reason end
    ok, reason = migrate_inventory(saved)
    if not ok then return nil, reason end
    if saved.v == 1 then ok, reason = migrate_v1(saved) else ok, reason = migrate_v2(saved) end
    if not ok then return nil, reason end
    saved.v = 2
    return saved
end

function PlayerData:IsValidSave(snapshot)
    return self:Migrate(snapshot) ~= nil
end

function PlayerData:Serialize()
    if not self.inited then return nil end
    self:NoteSafePoint()
    local function pack(containerId)
        local out = {}
        for index, entry in pairs(self.data.containers[containerId]) do
            if entry and entry.count > 0 then
                local slot = DeepCopy.copy(entry.saved or {})
                slot.i, slot.id, slot.n, slot.m = index, entry.itemId, entry.count, entry.mult
                out[#out + 1] = slot
            end
        end
        table.sort(out, function(a, b) return a.i < b.i end)
        return out
    end
    local bait = {}
    for itemId, count in pairs(self.data.Bait) do bait[itemId] = count end
    self.extra.inventory.selection.slot = self.data.selected_slot
    self.extra.inventory.selection.bait = self.data.selected_bait
    self.extra.inventory.selection.weapon = self.data.selected_weapon
    self.extra.inventory.weapons = DeepCopy.copy(self.data.weapons)
    self.extra.travel.zone = GameCfg.resolve_zone_id(self.data.Zone)
    return {
        v = 2,
        extra = DeepCopy.copy(self.extra),
        meta = DeepCopy.copy(self.save_meta),
        coin = self.data.FishCoin,
        bar = pack(GameCfg.Items.ContainerId.ItemBar),
        bp = pack(GameCfg.Items.ContainerId.Backpack),
        bait = bait,
        up = self.data.upgrade_level,
        zone = self.data.Zone,
    }
end

function PlayerData:ApplySave(snapshot)
    if not self.inited then return false end
    local saved, reason = self:Migrate(snapshot)
    if not saved then
        print('[PlayerData] 拒绝存档', self.Player and self.Player.UserId, reason)
        return false
    end
    local function unpack(packed, containerId)
        local items = {}
        for _, slot in ipairs(packed) do
            items[slot.i] = { itemId = slot.id, count = slot.n, mult = slot.m, cooked = slot.k,
                containerId = containerId, saved = DeepCopy.copy(slot) }
        end
        return items
    end
    self.data.FishCoin = saved.coin
    self.data.upgrade_level, self.data.Zone = saved.up, saved.zone
    self.data.Bait = saved.bait
    self.data.containers = {
        [GameCfg.Items.ContainerId.ItemBar] = unpack(saved.bar, GameCfg.Items.ContainerId.ItemBar),
        [GameCfg.Items.ContainerId.Backpack] = unpack(saved.bp, GameCfg.Items.ContainerId.Backpack),
    }
    self.extra, self.save_meta = saved.extra, saved.meta
    self.data.selected_slot = self.extra.inventory.selection.slot
    self.data.selected_bait = self.extra.inventory.selection.bait
    self.data.selected_weapon = self.extra.inventory.selection.weapon
    self.data.weapons = DeepCopy.copy(self.extra.inventory.weapons)
    self:SanitizeHeld()
    self.revision = (self.revision or 0) + 1
    self:Sync()
    return true
end

function PlayerData:ItemBarCapacity()
    return GameCfg.Items.InitialItemBarSlots + self.data.upgrade_level
end

function PlayerData:BackpackCapacity()
    local level = self.data.upgrade_level
    local capacity = GameCfg.Items.InitialBackpackSlots + level * GameCfg.Items.BackpackSlotsPerUpgrade
    if level == #GameCfg.Items.UpgradePrices then capacity = GameCfg.Items.MaxBackpackSlots end
    return capacity
end

-- ===== 拆分前 PlayerData:ApplyGMPatch 体内的分段：提到模块级，显式传参 =====

-- 补丁目标等级下的物品栏与背包容量（背包口径与 BackpackCapacity 一致，只是按补丁等级算）。
local function capacity_at(level)
    return GameCfg.Items.InitialItemBarSlots + level, backpack_capacity(level)
end

-- 容器浅拷贝：格位改动只落在副本上，全部校验通过后才由 ChangeCoin 一次性替换。
local function clone_containers(data)
    local ids, out = GameCfg.Items.ContainerId, {}
    for _, id in ipairs({ ids.ItemBar, ids.Backpack }) do
        local clone = {}
        for index, entry in pairs(data.containers[id]) do clone[index] = entry end
        out[id] = clone
    end
    return out
end

-- 某个容器的两套容量：返回（补丁等级容量, 当前等级容量）；未知容器返回 nil。
local function container_limits(self, id, level)
    local ids = GameCfg.Items.ContainerId
    local bar, backpack = capacity_at(level)
    if id == ids.ItemBar then return bar, self:ItemBarCapacity() end
    if id == ids.Backpack then return backpack, self:BackpackCapacity() end
    return nil, nil
end

-- 写入一个格位（非清空路径）：物品合法且不是鱼饵、件数为 1、个体倍率合法。
local function fill_slot(containers, id, edit)
    local definition = type(edit.itemId) == 'string' and GameCfg.Items.Definitions[edit.itemId]
    if edit.clear ~= nil or not definition or definition.Container == GameCfg.Items.ContainerId.Bait
        or not integer(edit.count, 1, 1) then
        return false, '格位物品或件数无效'
    end
    local mult = edit.mult
    if mult ~= nil and (type(mult) ~= 'number' or mult < 1 or mult > 2
        or math.abs(mult * 100 - math.floor(mult * 100 + 0.5)) > 1e-7
        or not hasIndividualMult(edit.itemId)) then
        return false, '个体倍率无效'
    end
    containers[id][edit.index] = { itemId = edit.itemId, count = 1, containerId = id, mult = mult }
    return true
end

-- 单条格位操作：键/格号/重复校验，再按「清空」与「写入」两条路径落到副本上。
local function apply_slot_edit(self, containers, key, edit, level, seen)
    if type(key) ~= 'number' or not integer(key, 1, 100) or type(edit) ~= 'table' then
        return false, '格位操作无效'
    end
    local id = edit.container
    local max, old_max = container_limits(self, id, level)
    if not max or not integer(edit.index, 1, edit.clear == true and math.max(max, old_max) or max) then
        return false, '格号无效'
    end
    local unique = id .. ':' .. edit.index
    if seen[unique] then return false, '格号重复' end
    seen[unique] = true
    if edit.clear == true and edit.itemId == nil and edit.count == nil and edit.mult == nil then
        containers[id][edit.index] = nil
        return true
    end
    return fill_slot(containers, id, edit)
end

-- 缩容检查：按补丁等级缩小后不得挤掉已有物品。
local function check_shrink(containers, level)
    local ids = GameCfg.Items.ContainerId
    local bar, backpack = capacity_at(level)
    for _, pair in ipairs({ { ids.ItemBar, bar }, { ids.Backpack, backpack } }) do
        for index, entry in pairs(containers[pair[1]]) do
            if entry and (type(index) ~= 'number' or index > pair[2]) then return false, '缩容将挤掉已有物品' end
        end
    end
    return true
end

-- 金币与扩容等级：补丁缺省时取当前值。
local function patch_amounts(self, patch)
    local coin = patch.coin == nil and self.data.FishCoin or patch.coin
    local level = patch.upgrade_level == nil and self.data.upgrade_level or patch.upgrade_level
    return coin, level
end

function PlayerData:ApplyGMPatch(patch)
    if not self.inited or type(patch) ~= 'table' then return false, '状态尚未就绪' end
    local coin, level = patch_amounts(self, patch)
    if not integer(coin, 0, math.maxinteger) or not integer(level, 0, #GameCfg.Items.UpgradePrices) then
        return false, '金币或扩容等级无效'
    end
    if patch.slots ~= nil and type(patch.slots) ~= 'table' then return false, '格位操作无效' end
    local containers, seen = clone_containers(self.data), {}
    for key, edit in pairs(patch.slots or {}) do
        local ok, reason = apply_slot_edit(self, containers, key, edit, level, seen)
        if not ok then return false, reason end
    end
    local ok, reason = check_shrink(containers, level)
    if not ok then return false, reason end
    self:ChangeCoin(coin - self.data.FishCoin, function(data)
        data.upgrade_level = level
        data.containers = containers
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

function PlayerData:GetItemBarSnapshot()
    if not self.inited then return nil end
    local bait = {}
    for itemId, count in pairs(self.data.Bait) do
        bait[itemId] = count
    end
    local bosses = {}
    for itemId in pairs(GameCfg.Casting.BossBait or {}) do bosses[#bosses + 1] = itemId end
    table.sort(bosses)
    for _, itemId in ipairs(bosses) do
        local count = self:ItemBarItemCount(itemId)
        if count >= 1 then bait[itemId] = count end
    end
    return {
        slots = copySlots(self.data.containers[GameCfg.Items.ContainerId.ItemBar], self:ItemBarCapacity()),
        slotCount = self:ItemBarCapacity(),
        backpack = copySlots(self.data.containers[GameCfg.Items.ContainerId.Backpack], self:BackpackCapacity()),
        backpackCount = self:BackpackCapacity(),
        upgrade_level = self.data.upgrade_level,
        bait = bait,
        coin = self.data.FishCoin,
        selectedSlot = self.data.selected_slot,
        selectedBait = self.data.selected_bait,
        weapons = DeepCopy.copy(self.data.weapons),
        selectedWeapon = self.data.selected_weapon,
        held = DeepCopy.copy(self.extra.inventory.selection.held),
    }
end

function PlayerData:SelectSlot(index)
    if not self.inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local entry = self.data.containers[GameCfg.Items.ContainerId.ItemBar][index]
    self.data.selected_slot = self.data.selected_slot ~= index and entry and entry.count > 0 and index or nil
    return true
end

function PlayerData:HoldSlot(index)
    if not self.inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local held = self.extra.inventory.selection.held
    if held.kind == 'slot' and held.slot == index then
        held.kind, held.id, held.slot = nil, nil, nil
        return true
    end
    local entry = self.data.containers[GameCfg.Items.ContainerId.ItemBar][index]
    if not entry or entry.count <= 0 then return false end
    held.kind, held.id, held.slot = 'slot', entry.itemId, index
    return true
end

function PlayerData:SanitizeHeld()
    local held = self.extra.inventory.selection.held
    if held.kind == 'slot' then
        local entry = held.slot and self.data.containers[GameCfg.Items.ContainerId.ItemBar][held.slot]
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
    local definition = type(itemId) == 'string' and GameCfg.Items.Definitions[itemId]
    return definition ~= nil and (definition.Type == '近战武器' or definition.Type == '远程武器')
end

function PlayerData:shop_upgrade_level(kind)
    if kind == 'backpack' then
        return self.inited and self.data.upgrade_level or 0
    end
    if not self.inited then return 0 end
    local level = self.extra.growth.upgrades[kind]
    return integer(level, 0) and level or 0
end

function PlayerData:PurchaseCount(number)
    if not self.inited or not integer(number, 1) then return 0 end
    return self.extra.growth.purchases[tostring(number)] or 0
end

function PlayerData:NotePurchase(number)
    if not self.inited or not integer(number, 1) then return false end
    local key = tostring(number)
    self.extra.growth.purchases[key] = (self.extra.growth.purchases[key] or 0) + 1
    return true
end

function PlayerData:CanShopUpgrade(upgrade)
    if type(upgrade) ~= 'table' or type(upgrade.kind) ~= 'string' then return false, 'bad' end
    local spec = GameCfg.Shop.UpgradeKinds[upgrade.kind]
    if not spec or not integer(upgrade.level, 1, spec.MaxLevel) then return false, 'bad' end
    local current = self:shop_upgrade_level(upgrade.kind)
    if current >= spec.MaxLevel then return false, 'max' end
    if upgrade.level ~= current + 1 then return false, 'level' end
    return true
end

function PlayerData:ApplyShopUpgrade(upgrade)
    local ok = self:CanShopUpgrade(upgrade)
    if not ok then return false end
    if upgrade.kind == 'backpack' then
        self.data.upgrade_level = upgrade.level
    else
        self.extra.growth.upgrades[upgrade.kind] = upgrade.level
    end
    return true
end

function PlayerData:weapon_damage_scale(kind)
    if not self.inited then return 1 end
    return GameCfg.Shop.damage_scale(kind, self:shop_upgrade_level(kind)) or 1
end

function PlayerData:magazine_size(base)
    if not self.inited or type(base) ~= 'number' then return base end
    return GameCfg.Shop.magazine_size(base, self:shop_upgrade_level('magazine'))
end

function PlayerData:GrantWeapon(itemId, count)
    if not self.inited or not isWeapon(itemId)
        or not integer(count, 1) then return false end
    self:UpdateData(function(data)
        data.weapons[itemId] = (data.weapons[itemId] or 0) + count
    end, true)
    return true
end

function PlayerData:WeaponCount(itemId)
    return self.inited and self.data.weapons[itemId] or 0
end

function PlayerData:potion_count(itemId)
    return self.inited and self.extra.growth.potions[itemId] or 0
end

function PlayerData:ConsumeWeapon(itemId, count)
    if not self.inited or not integer(count, 1) or self:WeaponCount(itemId) < count then return false end
    self:UpdateData(function(data)
        data.weapons[itemId] = data.weapons[itemId] - count
        if data.weapons[itemId] == 0 then data.weapons[itemId] = nil end
        if data.selected_weapon == itemId and data.weapons[itemId] == nil then data.selected_weapon = nil end
    end, true)
    return true
end

function PlayerData:SelectWeapon(itemId)
    if not self.inited then return false end
    if itemId == nil then
        self.data.selected_weapon = nil
        self:PublishItemBar()
        return true
    end
    if not isWeapon(itemId) or self:WeaponCount(itemId) < 1 then return false end
    self.data.selected_weapon = self.data.selected_weapon ~= itemId and itemId or nil
    self:PublishItemBar()
    return true
end

function PlayerData:HoldWeapon(itemId)
    if not self.inited then return false end
    local held = self.extra.inventory.selection.held
    if held.kind == 'weapon' and held.id == itemId then
        held.kind, held.id, held.slot = nil, nil, nil
        return true
    end
    if not isWeapon(itemId) or self:WeaponCount(itemId) < 1 then return false end
    held.kind, held.id, held.slot = 'weapon', itemId, nil
    return true
end

function PlayerData:RestoreSlot(index)
    if not self.inited or type(index) ~= 'number' then return false end
    local entry = self.data.containers[GameCfg.Items.ContainerId.ItemBar][index]
    if not entry or entry.count < 1 or entry.itemId ~= GameCfg.Items.Id.StarterRod then return false end
    self.data.selected_slot = index
    return true
end

local function hasBait(data, itemId)
    local count = data.Bait[itemId]
    return type(count) == 'number' and count >= 1
end

function PlayerData:SetZone(zone)
    if not self.inited or type(zone) ~= 'string' or zone == '' then return false end
    self:UpdateData(function(data) data.Zone = zone end, false)
    return true
end

function PlayerData:ItemBarItemCount(itemId)
    if not self.inited then return 0 end
    local total = 0
    for _, entry in pairs(self.data.containers[GameCfg.Items.ContainerId.ItemBar]) do
        if entry.itemId == itemId and entry.count > 0 then total = total + entry.count end
    end
    return total
end

function PlayerData:ItemCount(itemId)
    if not self.inited then return 0 end
    local total = 0
    for _, container in pairs(self.data.containers) do
        for _, entry in pairs(container) do
            if entry.itemId == itemId and entry.count > 0 then total = total + entry.count end
        end
    end
    return total
end

function PlayerData:ConsumeItemBarItem(itemId)
    if not self.inited then return false end
    local items = self.data.containers[GameCfg.Items.ContainerId.ItemBar]
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

function PlayerData:ConsumeItem(itemId)
    if not self.inited then return false end
    for _, container in ipairs({
        { GameCfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { GameCfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        ---@type table<integer, any>
        local items = self.data.containers[container[1]]
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

function PlayerData:HasBait(itemId)
    if not self.inited or type(itemId) ~= 'string' then return false end
    if hasBait(self.data, itemId) then return true end
    local bossBait = GameCfg.Casting.BossBait
    return bossBait ~= nil and bossBait[itemId] ~= nil and self:ItemBarItemCount(itemId) >= 1
end

function PlayerData:SelectBait(itemId)
    if not self.inited then return false end
    if itemId == nil then
        self.data.selected_bait = nil
        return true
    end
    if type(itemId) ~= 'string' or not self:HasBait(itemId) then return false end
    self.data.selected_bait = itemId
    return true
end

function PlayerData:EatBait(itemId)
    if not self.inited or type(itemId) ~= 'string' or not hasBait(self.data, itemId) then return false end
    self:UpdateData(function(data)
        data.Bait[itemId] = data.Bait[itemId] - 1
    end, true)
    return true
end

function PlayerData:EatSlot(index)
    if not self.inited or type(index) ~= 'number' or index ~= self.data.selected_slot then return nil end
    local items = self.data.containers[GameCfg.Items.ContainerId.ItemBar]
    local entry = items[index]
    local definition = entry and entry.count > 0 and GameCfg.Items.Definitions[entry.itemId]
    if not entry or not definition or type(definition.EatPercent) ~= 'number' then return nil end
    self:UpdateData(function(data)
        data.containers[GameCfg.Items.ContainerId.ItemBar][index] = nil
    end, true)
    return entry.itemId
end

function PlayerData:ConsumeSelectedBait()
    if not self.inited then return false, nil end
    local itemId = self.data.selected_bait
    if not itemId then return true, nil end
    local bossBait = GameCfg.Casting.BossBait
    if bossBait and bossBait[itemId] then
        if self:ConsumeItemBarItem(itemId) then return true, itemId end
        self.data.selected_bait = nil
        self:PublishItemBar()
        return false, nil
    end
    if not hasBait(self.data, itemId) then
        self.data.selected_bait = nil
        self:PublishItemBar()
        return false, nil
    end
    self:UpdateData(function(data)
        data.Bait[itemId] = data.Bait[itemId] - 1
    end, true)
    return true, itemId
end

function PlayerData:AddItem(itemId, mult, cooked)
    if not self.inited or type(itemId) ~= 'string' then return false end
    for _, container in ipairs({
        { GameCfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { GameCfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        ---@type table<integer, any>
        local items = self.data.containers[container[1]]
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

function PlayerData:AddBait(itemId, count)
    local definition = type(itemId) == 'string' and GameCfg.Items.Definitions[itemId]
    if not self.inited or not definition or definition.Container ~= GameCfg.Items.ContainerId.Bait
        or type(count) ~= 'number' or count < 1 or count ~= math.floor(count) then return false end
    self:UpdateData(function(data)
        data.Bait[itemId] = (data.Bait[itemId] or 0) + count
    end, true)
    return true
end

function PlayerData:CanGrant(itemId, count)
    local definition = type(itemId) == 'string' and GameCfg.Items.Definitions[itemId]
    if not self.inited or not definition or type(count) ~= 'number' or count < 1
        or count ~= math.floor(count) then return false, 'bad' end
    if definition.Container == GameCfg.Items.ContainerId.Bait then return true end
    if isWeapon(itemId) then return true end
    local free = 0
    for _, container in ipairs({
        { GameCfg.Items.ContainerId.ItemBar, self:ItemBarCapacity() },
        { GameCfg.Items.ContainerId.Backpack, self:BackpackCapacity() },
    }) do
        local items = self.data.containers[container[1]]
        for index = 1, container[2] do
            if not items[index] or items[index].count <= 0 then free = free + 1 end
        end
    end
    if free < count then return false, 'full' end
    return true
end

function PlayerData:GrantItem(itemId, count)
    if isWeapon(itemId) then return self:GrantWeapon(itemId, count) end
    local ok, reason = self:CanGrant(itemId, count)
    if not ok then return false, reason end
    if GameCfg.Items.Definitions[itemId].Container == GameCfg.Items.ContainerId.Bait then
        return self:AddBait(itemId, count)
    end
    for _ = 1, count do self:AddItem(itemId) end
    return true
end

local function isPositiveInt(n)
    return type(n) == 'number' and n >= 1 and n == math.floor(n)
end

function PlayerData:ChangeCoin(delta, apply, reason)
    if not self.inited then return false end
    local balance = self.data.FishCoin + delta
    if balance < 0 then
        print('[PlayerData] 金币不足', self.Player and self.Player.UserId, reason, delta, 'FishCoin=' .. tostring(self.data.FishCoin))
        return false
    end
    self:UpdateData(function(data)
        if apply then apply(data) end
        data.FishCoin = balance
    end, true)
    print('[PlayerData] 金币' .. (delta >= 0 and '收入' or '支出'), self.Player and self.Player.UserId, reason,
        (delta >= 0 and '+' or '') .. tostring(delta), 'FishCoin=' .. tostring(balance))
    return true
end

function PlayerData:AddCoin(amount, apply, reason)
    if not isPositiveInt(amount) then return false end
    return self:ChangeCoin(amount, apply, reason)
end

function PlayerData:SpendCoin(amount, apply, reason)
    if not isPositiveInt(amount) then return false end
    return self:ChangeCoin(-amount, apply, reason)
end

function PlayerData:ExchangeSlot(slot, product)
    local items = self.inited and self.data.containers[GameCfg.Items.ContainerId.ItemBar]
    local kept = type(slot) == 'number' and items and items[slot] or nil
    if type(kept) ~= 'table' or kept.count <= 0 or type(product) ~= 'string' then return false, 'bad' end
    if not self:CanGrant(product, 1) then return false, 'full' end
    self:UpdateData(function(d)
        d.containers[GameCfg.Items.ContainerId.ItemBar][slot] = nil
    end, false)
    if not self:AddItem(product) then
        self:UpdateData(function(d)
            d.containers[GameCfg.Items.ContainerId.ItemBar][slot] = kept
        end, true)
        print('[PlayerData] 兑换发放失败，已退回原物品', self.Player and self.Player.UserId, kept.itemId, product)
        return false, 'full'
    end
    return true
end

function PlayerData:MoveSlot(from, index, target, slot)
    if not self.inited then return false end
    local ids = GameCfg.Items.ContainerId
    local function capacity(id)
        return id == ids.ItemBar and self:ItemBarCapacity() or id == ids.Backpack and self:BackpackCapacity()
    end
    local sourceMax, targetMax = capacity(from), capacity(target)
    if not sourceMax or not targetMax or not integer(index, 1, sourceMax)
        or not integer(slot, 1, targetMax) or from == target and index == slot then return false end
    local source, destination = self.data.containers[from], self.data.containers[target]
    if not source[index] then return false end
    self:UpdateData(function()
        source[index], destination[slot] = destination[slot], source[index]
        if source[index] then source[index].containerId = from end
        destination[slot].containerId = target
        if from == ids.ItemBar and self.data.selected_slot == index
            or target == ids.ItemBar and self.data.selected_slot == slot then
            self.data.selected_slot = nil
        end
    end, true)
    return true
end

function PlayerData:MoveToItemBar(index)
    if not self.inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:BackpackCapacity() then return false end
    local backpack = self.data.containers[GameCfg.Items.ContainerId.Backpack]
    local entry = backpack[index]
    if not entry then return false end
    local bar = self.data.containers[GameCfg.Items.ContainerId.ItemBar]
    for slot = 1, self:ItemBarCapacity() do
        if not bar[slot] or bar[slot].count <= 0 then
            self:UpdateData(function()
                backpack[index] = nil
                bar[slot] = entry
                entry.containerId = GameCfg.Items.ContainerId.ItemBar
            end, true)
            return true
        end
    end
    return false
end

function PlayerData:UpgradeStorage()
    local price = GameCfg.Items.UpgradePrices[self.data.upgrade_level + 1]
    if not self.inited or not price then return false, 'max' end
    if not self:SpendCoin(price, function(data)
        data.upgrade_level = data.upgrade_level + 1
    end, 'storage-upgrade') then return false, 'coin' end
    return true, price
end

function PlayerData:DiscardSlot(index)
    if not self.inited or type(index) ~= 'number' or index ~= math.floor(index)
        or index < 1 or index > self:ItemBarCapacity() then return false end
    local items = self.data.containers[GameCfg.Items.ContainerId.ItemBar]
    if not items[index] then return false end
    self:UpdateData(function()
        items[index] = nil
    end, false)
    return true
end

function PlayerData:PublishItemBar()
    if self.on_item_bar_changed then
        self.on_item_bar_changed(self.Player, self)
    end
end

function PlayerData:UpdateData(updateCallBack, doSync)
    if not self.inited or not updateCallBack then return end
    self.touched = true
    updateCallBack(self.data)
    self.revision = (self.revision or 0) + 1
    local selected = self.data.selected_slot
    local entry = selected and self.data.containers[GameCfg.Items.ContainerId.ItemBar][selected]
    if selected and (not entry or entry.count <= 0) then self.data.selected_slot = nil end
    local baitId = self.data.selected_bait
    if baitId and not self:HasBait(baitId) then self.data.selected_bait = nil end
    self:SanitizeHeld()
    if doSync then
        self:Sync()
        self:PublishItemBar()
    end
end

function PlayerData:Sync()
    if not self.Player or not self.inited then return end
    self.Player:SetAttribute('FishCoin', self.data.FishCoin)
end

function PlayerData:destroy()
    self.Player = nil
    self.data = nil
    self.on_item_bar_changed = nil
    self.inited = false
    self.save_meta = nil
    self.revision = nil
end

function PlayerData:PersonalBestScaled(fishId)
    if not self.inited or type(fishId) ~= 'string' then return nil end
    local bag = self.extra and self.extra.collection
    local weight = bag and bag.weights and bag.weights[fishId]
    if type(weight) ~= 'number' then return nil end
    return Records.scale(weight)
end

return PlayerData
