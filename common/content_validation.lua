local Validate = {}
local Ledger = require('common.cfg.content_ledger')

local function positive(value) return type(value) == 'number' and value > 0 end
local function nonnegative(value) return type(value) == 'number' and value >= 0 end
local function integer(value) return type(value) == 'number' and value % 1 == 0 end
local function count(map) local n = 0; for _ in pairs(map or {}) do n = n + 1 end; return n end

local function check_ledger(cfg, fail, activeGoods)
    local groups = {
        Fish = { rows = cfg.Fish, key = function(row) return row.Id end },
        Items = { rows = cfg.Items.Definitions, key = function(row) return row.Id end },
        Shop = { rows = cfg.Content.Shop.Goods, key = function(row) return row.number end },
        Lottery = { rows = cfg.Content.Lottery.Patterns, key = function(row) return row.number end },
        Blindbox = { rows = cfg.Content.Blindbox.Entries, key = function(row) return row.number end },
    }
    for name, group in pairs(groups) do
        local ledger = Ledger[name] or {}
        local seen = {}
        for _, row in pairs(group.rows) do
            local id = group.key(row)
            local entry = ledger[id]
            if not entry then
                fail(row.source, name .. ' 的实现标记未登记到纯台账 ' .. tostring(id))
            else
                seen[id] = true
                if row.implemented ~= nil then fail(row.source, name .. ' 的内容表不得自带实现标记') end
                if entry.source ~= row.source then
                    fail(row.source, name .. ' 的台账来源与内容表不符 ' .. tostring(entry.source))
                end
                if entry.implemented ~= true and entry.implemented ~= false then
                    fail(row.source, name .. ' 的台账未标记可用状态')
                end
                local path = entry.path
                local inBusinessTree = type(path) == 'string'
                    and (path:sub(1, 7) == 'server/' or path:sub(1, 8) == 'common/' or path:sub(1, 7) == 'client/')
                if entry.implemented == false and path ~= nil then
                    fail(row.source, '标记为未实现但已有实现路径 ' .. tostring(path))
                elseif entry.implemented == true and not inBusinessTree then
                    fail(row.source, '标记为已实现但没有代码落点')
                end
                if name == 'Shop' and entry.implemented == true then
                    local active = activeGoods[row.number]
                    if not active or active.Price ~= row.price or active.MinShopLevel ~= row.minShopLevel then
                        fail(row.source, '标为可用但现有商店未上架该商品或价格/等级不同')
                    end
                end
            end
        end
        for id, entry in pairs(ledger) do
            if not seen[id] then fail(tostring(entry.source), name .. ' 的台账登记了不存在的内容 ' .. tostring(id)) end
        end
    end
end

-- ===== 拆分前 Validate.check 体内的分段：提到模块级，fail 显式传入 =====
-- 各段只负责一段内容表的校验；错误最后在入口统一排序，所以分段顺序不影响输出。
-- 错误文案、条数与返回的 counts 口径与拆分前完全一致。

-- 钓鱼区：ID 去重、水域登记与普通鱼饵存在性；返回按 ID / 水域索引的表。
local function check_zones(cfg, fail)
    local zones, waters = {}, {}
    for _, zone in ipairs(cfg.Zones or {}) do
        if zones[zone.Id] then fail(zone.source, '钓鱼区 ID 重复 ' .. tostring(zone.Id)) end
        zones[zone.Id], waters[zone.WaterId] = zone, zone
        if not cfg.Items.Definitions[zone.BaitItemId] then fail(zone.source, '普通鱼饵不存在 ' .. tostring(zone.BaitItemId)) end
    end
    return zones, waters
end

-- 物品：键与 ID 一致、编号去重、编号映射与售价。
local function check_items(cfg, fail)
    local items, numbers = cfg.Items.Definitions, {}
    for key, item in pairs(items) do
        local source = item.source
        if key ~= item.Id then fail(source, '物品键与 ID 不同 ' .. tostring(key)) end
        if numbers[item.SourceId] then fail(source, '物品编号重复 ' .. tostring(item.SourceId) .. '（' .. numbers[item.SourceId] .. '）') end
        numbers[item.SourceId] = source
        if cfg.Items.SourceIdMap[item.SourceId] ~= key then fail(source, '物品编号映射失效 ' .. tostring(item.SourceId)) end
        if not nonnegative(item.BasePrice) then fail(source, '出售价格无效') end
    end
end

-- 单条鱼种的掉落：物品存在、件数为正整数。
local function check_drops(species, items, source, fail)
    if type(species.Drops) ~= 'table' or #species.Drops == 0 then
        fail(source, '缺少掉落')
        return
    end
    for _, drop in ipairs(species.Drops) do
        if not items[drop.ItemId] then fail(source, '掉落物不存在 ' .. tostring(drop.ItemId)) end
        if not integer(drop.Count) or drop.Count < 1 then fail(source, '掉落数量无效') end
    end
end

-- 鱼种：键、编号+品级去重、映射、所属区/水域、数值区间、鱼饵与掉落；返回有普通抽鱼表的区集合。
local function check_fish(cfg, items, zones, waters, fail)
    local fishNumbers, zoneSeen = {}, {}
    for key, species in pairs(cfg.Fish) do
        local source = species.source
        if key ~= species.Id then fail(source, '鱼种键与 ID 不同 ' .. tostring(key)) end
        local sourceKey = tostring(species.SourceId) .. ':' .. tostring(species.Grade)
        if fishNumbers[sourceKey] then fail(source, '鱼种编号和品级重复 ' .. sourceKey .. '（' .. fishNumbers[sourceKey] .. '）') end
        fishNumbers[sourceKey] = source
        if cfg.FishSourceIdMap[sourceKey] ~= key then fail(source, '鱼种编号映射失效 ' .. sourceKey) end
        if not zones[species.ZoneId] or not waters[species.WaterId] or waters[species.WaterId].Id ~= species.ZoneId then
            fail(source, '钓鱼区或水域 ID 无效 ' .. tostring(species.ZoneId) .. '/' .. tostring(species.WaterId))
        end
        if not positive(species.Health) or not positive(species.BaseWeight) or not positive(species.DrawWeight)
            or not integer(species.RodLevel) or species.RodLevel < 1 or species.RodLevel > 7
            or not nonnegative(species.BasePrice) then fail(source, '血量/重量/抽签权重/竿级/价格无效') end
        if species.Bait ~= 0 and not items[species.Bait] then fail(source, '鱼饵不存在 ' .. tostring(species.Bait)) end
        check_drops(species, items, source, fail)
        if species.Grade ~= 'boss' then zoneSeen[species.ZoneId] = true end
    end
    return zoneSeen
end

-- 每个钓鱼区都要有普通抽鱼表。
local function check_zone_coverage(cfg, zoneSeen, fail)
    for _, zone in ipairs(cfg.Zones or {}) do
        if not zoneSeen[zone.Id] then fail(zone.source, '缺少普通抽鱼表 ' .. zone.Id) end
    end
end

-- 单条商品：编号去重、禁售名单、名称与物品表一致、价格/等级/限购区间。
local function check_shop_row(row, items, numbers, fail)
    if numbers[row.number] then fail(row.source, '商品编号重复 ' .. tostring(row.number) .. '（' .. numbers[row.number] .. '）') end
    numbers[row.number] = row.source
    if row.number == 27 or row.itemName == '夜明珠' then fail(row.source, '作废或禁止售卖商品') end
    if row.itemKey and not items[row.itemKey] then fail(row.source, '商品物品不存在 ' .. row.itemKey) end
    if row.itemKey and items[row.itemKey] and row.itemName ~= items[row.itemKey].Name then
        fail(row.source, '商品名称与物品表不一致 ' .. row.itemName)
    end
    if not positive(row.price) or not integer(row.minShopLevel) or row.minShopLevel < 1 or row.minShopLevel > 7
        or not nonnegative(row.purchaseLimit) or not integer(row.purchaseLimit) then fail(row.source, '商品价格/商店等级/限购无效') end
end

-- 商品：逐行校验，同时收集现有商店在架表（台账校验按它在架与价格/等级比对）。
local function check_shop(cfg, items, fail)
    local goods, numbers, active = cfg.Content.Shop.Goods, {}, {}
    for _, row in ipairs(cfg.Shop.Goods or {}) do active[row.Number] = row end
    for _, row in ipairs(goods) do check_shop_row(row, items, numbers, fail) end
    return active
end

-- 抽奖图案：权重、两同倍率与三同奖项引用；返回权重合计。
local function check_lottery(cfg, items, fail)
    local lottery, weight = cfg.Content.Lottery.Patterns, 0
    for _, row in ipairs(lottery) do
        weight = weight + (row.weight or 0)
        if not positive(row.weight) or not positive(row.pairMultiplier) then fail(row.source, '抽奖图案权重/两同倍率无效') end
        local reward = row.tripleReward or {}
        if reward.kind == 'weaponChoice' then
            if #reward.itemKeys ~= 5 then fail(row.source, '三同武器组须五件') end
            for _, key in ipairs(reward.itemKeys) do if not items[key] then fail(row.source, '大奖武器不存在 ' .. tostring(key)) end end
        elseif reward.kind == 'item' then
            if not items[reward.itemKey] then fail(row.source, '三同物品不存在 ' .. tostring(reward.itemKey)) end
        else
            fail(row.source, '三同奖项无效')
        end
    end
    return weight
end

-- 盲盒奖池：权重合计、大奖个数、物品去重与名称/类别/基础价。
local function check_blindbox(cfg, items, fail)
    local blindbox, weight, jackpot, keys = cfg.Content.Blindbox.Entries, 0, 0, {}
    for _, row in ipairs(blindbox) do
        weight = weight + (row.weight or 0)
        if row.jackpot then jackpot = jackpot + 1 end
        if keys[row.itemKey] then fail(row.source, '盲盒物品重复 ' .. tostring(row.itemKey)) end
        keys[row.itemKey] = true
        local item = items[row.itemKey]
        if not item then fail(row.source, '盲盒物品不存在 ' .. tostring(row.itemKey))
        elseif item.Name ~= row.itemName or item.Type ~= '极品食物' or item.BasePrice ~= row.basePrice then
            fail(row.source, '盲盒物品名称/类别/基础价与物品表不符') end
        if not positive(row.weight) or row.multiplier ~= 1 then fail(row.source, '盲盒权重或固定倍率无效') end
    end
    return weight, jackpot, keys
end

-- 盲盒价格/保底规则与保底物品落点。
local function check_blindbox_rules(cfg, jackpotCount, blindboxKeys, fail)
    local blind = cfg.Content.Blindbox
    if blind.Currency ~= '金豆' or blind.SinglePrice ~= 10 or blind.TenPrice ~= 90
        or blind.Pity.afterMisses ~= 49 or blind.Pity.guaranteedDraw ~= 50
        or jackpotCount ~= 2 then fail('GameSpec.md#15', '盲盒价格/保底大奖规则无效') end
    for _, key in ipairs(blind.Pity.prizeItemKeys) do
        if not blindboxKeys[key] then fail('GameSpec.md#15', '保底物品不在奖池 ' .. tostring(key)) end
    end
end

-- 单条兑换链的鱼种一致：精英/首领的存在、品级、所属区与掉落位。
local function check_chain_fish(chain, fish, fail)
    local source = chain.source
    local elite, boss = fish[chain.EliteFish], fish[chain.BossFish]
    if not elite or elite.Grade ~= 'elite' or elite.ZoneId ~= chain.ZoneId then fail(source, '精英鱼不存在或钓鱼区不匹配 ' .. tostring(chain.EliteFish)) end
    if not boss or boss.Grade ~= 'boss' or boss.ZoneId ~= chain.ZoneId then fail(source, '首领不存在或钓鱼区不匹配 ' .. tostring(chain.BossFish)) end
    if elite and elite.Drops[2] and elite.Drops[2].ItemId ~= chain.EliteToken then fail(source, '精英信物与掉落不匹配') end
    if boss and (boss.Bait ~= chain.BossBait or not boss.Drops[2] or boss.Drops[2].ItemId ~= chain.BossToken) then
        fail(source, '首领饵或首领信物与鱼种不匹配') end
end

-- 单条兑换链的物品引用：精英信物、首领饵、首领信物与兑换结果。
local function check_chain_items(chain, items, fail)
    local source = chain.source
    if not items[chain.EliteToken] then fail(source, '精英信物不存在 ' .. tostring(chain.EliteToken)) end
    if not items[chain.BossBait] or not items[chain.BossBait].BossBait then fail(source, '首领饵不存在 ' .. tostring(chain.BossBait)) end
    if not items[chain.BossToken] then fail(source, '首领信物不存在 ' .. tostring(chain.BossToken)) end
    if chain.Result ~= 'achievement.final' and not items[chain.Result] then fail(source, '兑换物品不存在 ' .. tostring(chain.Result)) end
end

-- 信物兑换链：逐条校验并断言链数为七组。
local function check_exchanges(cfg, items, fish, fail)
    local chains = cfg.Content.Exchanges or {}
    for _, chain in ipairs(chains) do
        check_chain_fish(chain, fish, fail)
        check_chain_items(chain, items, fail)
    end
    if #chains ~= 7 then fail('GameSpec.md#8.1', '信物兑换链不是七组') end
end

-- 汇总数量与权重（既是校验项也是返回给调用方的统计口径）。
local function build_counts(cfg, fish, items, lotteryWeight, blindboxWeight)
    return { zones = #(cfg.Zones or {}), fish = count(fish), items = count(items),
        shop = #cfg.Content.Shop.Goods, lottery = #cfg.Content.Lottery.Patterns,
        blindbox = #cfg.Content.Blindbox.Entries, lotteryWeight = lotteryWeight, blindboxWeight = blindboxWeight }
end

-- GameSpec.md#19 数量/权重下限
local EXPECTED_COUNTS = { zones = 7, fish = 98, items = 172, shop = 50, lottery = 7,
    blindbox = 42, lotteryWeight = 100, blindboxWeight = 1000 }

local function check_counts(counts, fail)
    for field, expected in pairs(EXPECTED_COUNTS) do
        if counts[field] ~= expected then fail('GameSpec.md#19', field .. ' 数量/权重应为 ' .. expected .. '，实际 ' .. counts[field]) end
    end
end

function Validate.check(cfg)
    local errors = {}
    local function fail(source, message) errors[#errors + 1] = tostring(source or '配置') .. ': ' .. message end
    local zones, waters = check_zones(cfg, fail)
    local items, fish = cfg.Items.Definitions, cfg.Fish
    check_items(cfg, fail)
    local zoneSeen = check_fish(cfg, items, zones, waters, fail)
    check_zone_coverage(cfg, zoneSeen, fail)
    local activeGoods = check_shop(cfg, items, fail)
    local lotteryWeight = check_lottery(cfg, items, fail)
    local blindboxWeight, jackpotCount, blindboxKeys = check_blindbox(cfg, items, fail)
    check_blindbox_rules(cfg, jackpotCount, blindboxKeys, fail)
    check_exchanges(cfg, items, fish, fail)
    check_ledger(cfg, fail, activeGoods)
    local counts = build_counts(cfg, fish, items, lotteryWeight, blindboxWeight)
    check_counts(counts, fail)
    table.sort(errors)
    return { errors = errors, counts = counts }
end

return Validate
