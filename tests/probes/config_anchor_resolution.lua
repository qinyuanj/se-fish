-- #65 P2 配置依赖复解析（编辑器侧，edit mode，只读）。
-- 复跑：
--   lua tools/gen_config_anchor_probe.lua                        # 按当前 GameCfg 重新生成下面的数据块
--   editor-cli exec --file tests/probes/config_anchor_resolution.lua --expect-edit-mode --timeout 120 --json
--   editor-cli log grep P2CFG65 --platform editor --context 0 --max-matches 800 --json
--
-- 数据块由 `lua tools/gen_config_anchor_probe.lua` 生成，**不要手改数据块**：
-- fast 车道的 tests/native/config_anchor_baseline_sync_test.lua 会逐字节校验它与当前 GameCfg 同步。
--
-- 为什么清单是生成出来的字面量：编辑器 exec 沙盒里 require 不可用
-- （sdk.common.lua:830: attempt to call a nil value (field 'require')），且没有 io/os，
-- 探针既不能自己加载 common/GameCfg.lua，也不能读外部数据文件。
--
-- 用途：P2 要求每批修改前「重解析名称、类型、层级、当前变换及配置依赖」。本探针把配置里
-- 被运行时**按名查找**的锚点逐条在七区现场重新解析：是否存在、命中几个、命中在哪条层级路径、
-- 是否落在配置预期的区里。
--
-- 口径：
--   1. 只读；手工栈遍历（Unit:FindFirstChild 只匹配直接子级，多传的 true 被静默忽略，
--      见 tests/probes/zone_baseline_inventory.lua 顶部注释）；不枚举 Script/PresetLink 类型。
--   2. 列出**全部同名命中**（运行时 World:FindFirstChild 只取第一个）：命中数 > 1 是歧义风险；
--      命中数 0 时区分 observed / planned 两种原因。
--   3. 名称能解析只说明查找链完好，**不**证明碰撞、落点、可通行或玩法验收通过（玩法归 P8）。
local MARK = 'P2CFG65'

-- >>> GENERATED ANCHOR DATA（由 tools/gen_config_anchor_probe.lua 生成）
local ZONES = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }
-- 每行：来源|预期区|锚点名|配置状态
local ANCHOR_DATA = [[
Ferry.Outbound|01 鱼塘|FerryBoat|-
Ferry.Outbound|02 虾池|Z2_FerryOut|-
Ferry.Outbound|03 蟹湖|Z3_FerryOut|-
Ferry.Outbound|04 树林岛|Z4_FerryOut|-
Ferry.Outbound|05 沙滩岛|Z5_FerryOut|-
Ferry.Outbound|06 礁石岛|Z6_FerryOut|-
Ferry.Return|02 虾池|FerryReturn|-
Ferry.Return|03 蟹湖|Z3_FerryReturn|-
Ferry.Return|04 树林岛|Z4_FerryReturn|-
Ferry.Return|05 沙滩岛|Z5_FerryReturn|-
Ferry.Return|06 礁石岛|Z6_FerryReturn|-
Ferry.Return|07 火山岛|Z7_FerryReturn|-
Grill.Points|03 蟹湖|Z3_Grill|-
Grill.Points|04 树林岛|Z4_Grill|-
Grill.Points|05 沙滩岛|Z5_Grill|-
Grill.Points|06 礁石岛|Z6_Grill|-
Grill.Points|07 火山岛|Z7_Grill|-
Interact.Fishermen|01 鱼塘|TGUnitFish|-
Interact.Fishermen|02 虾池|TGUnitFishShrimp|-
Interact.Fishermen|03 蟹湖|Z3_Fisherman|-
Interact.Fishermen|04 树林岛|Z4_Fisherman|-
Interact.Fishermen|05 沙滩岛|Z5_Fisherman|-
Interact.Fishermen|06 礁石岛|Z6_Fisherman|-
Interact.Fishermen|07 火山岛|Z7_Fisherman|-
Marker.Bait1|01 鱼塘|Z1_Bait1|contract
Marker.Bait1|02 虾池|Z2_Bait1|contract
Marker.Bait1|03 蟹湖|Z3_Bait1|contract
Marker.Bait1|04 树林岛|Z4_Bait1|contract
Marker.Bait1|05 沙滩岛|Z5_Bait1|contract
Marker.Bait1|06 礁石岛|Z6_Bait1|contract
Marker.Bait1|07 火山岛|Z7_Bait1|contract
Marker.Bait2|01 鱼塘|Z1_Bait2|contract
Marker.Bait2|02 虾池|Z2_Bait2|contract
Marker.Bait2|03 蟹湖|Z3_Bait2|contract
Marker.Bait2|04 树林岛|Z4_Bait2|contract
Marker.Bait2|05 沙滩岛|Z5_Bait2|contract
Marker.Bait2|06 礁石岛|Z6_Bait2|contract
Marker.Bait2|07 火山岛|Z7_Bait2|contract
Marker.Bait3|01 鱼塘|Z1_Bait3|contract
Marker.Bait4|01 鱼塘|Z1_Bait4|contract
Marker.Bait5|01 鱼塘|Z1_Bait5|contract
Marker.Boundary|01 鱼塘|Z1_BoundaryEast|contract
Marker.Boundary|01 鱼塘|Z1_BoundaryNorth|contract
Marker.Boundary|01 鱼塘|Z1_BoundarySouth|contract
Marker.Boundary|01 鱼塘|Z1_BoundaryWest|contract
Marker.Boundary|02 虾池|Z2_BoundaryEast|contract
Marker.Boundary|02 虾池|Z2_BoundaryNorth|contract
Marker.Boundary|02 虾池|Z2_BoundarySouth|contract
Marker.Boundary|02 虾池|Z2_BoundaryWest|contract
Marker.Boundary|03 蟹湖|Z3_BoundaryEast|contract
Marker.Boundary|03 蟹湖|Z3_BoundaryNorth|contract
Marker.Boundary|03 蟹湖|Z3_BoundarySouth|contract
Marker.Boundary|03 蟹湖|Z3_BoundaryWest|contract
Marker.Boundary|04 树林岛|Z4_BoundaryEast|contract
Marker.Boundary|04 树林岛|Z4_BoundaryNorth|contract
Marker.Boundary|04 树林岛|Z4_BoundarySouth|contract
Marker.Boundary|04 树林岛|Z4_BoundaryWest|contract
Marker.Boundary|05 沙滩岛|Z5_BoundaryEast|contract
Marker.Boundary|05 沙滩岛|Z5_BoundaryNorth|contract
Marker.Boundary|05 沙滩岛|Z5_BoundarySouth|contract
Marker.Boundary|05 沙滩岛|Z5_BoundaryWest|contract
Marker.Boundary|06 礁石岛|Z6_BoundaryEast|contract
Marker.Boundary|06 礁石岛|Z6_BoundaryNorth|contract
Marker.Boundary|06 礁石岛|Z6_BoundarySouth|contract
Marker.Boundary|06 礁石岛|Z6_BoundaryWest|contract
Marker.Boundary|07 火山岛|Z7_BoundaryEast|contract
Marker.Boundary|07 火山岛|Z7_BoundaryNorth|contract
Marker.Boundary|07 火山岛|Z7_BoundarySouth|contract
Marker.Boundary|07 火山岛|Z7_BoundaryWest|contract
Marker.FerryOut|01 鱼塘|FerryBoat|contract
Marker.FerryOut|02 虾池|Z2_FerryOut|contract
Marker.FerryOut|03 蟹湖|Z3_FerryOut|contract
Marker.FerryOut|04 树林岛|Z4_FerryOut|contract
Marker.FerryOut|05 沙滩岛|Z5_FerryOut|contract
Marker.FerryOut|06 礁石岛|Z6_FerryOut|contract
Marker.FerryReturn|02 虾池|FerryReturn|contract
Marker.FerryReturn|03 蟹湖|Z3_FerryReturn|contract
Marker.FerryReturn|04 树林岛|Z4_FerryReturn|contract
Marker.FerryReturn|05 沙滩岛|Z5_FerryReturn|contract
Marker.FerryReturn|06 礁石岛|Z6_FerryReturn|contract
Marker.FerryReturn|07 火山岛|Z7_FerryReturn|contract
Marker.Fisherman|01 鱼塘|TGUnitFish|contract
Marker.Fisherman|02 虾池|TGUnitFishShrimp|contract
Marker.Fisherman|03 蟹湖|Z3_Fisherman|contract
Marker.Fisherman|04 树林岛|Z4_Fisherman|contract
Marker.Fisherman|05 沙滩岛|Z5_Fisherman|contract
Marker.Fisherman|06 礁石岛|Z6_Fisherman|contract
Marker.Fisherman|07 火山岛|Z7_Fisherman|contract
Marker.Grill|03 蟹湖|Z3_Grill|contract
Marker.Grill|04 树林岛|Z4_Grill|contract
Marker.Grill|05 沙滩岛|Z5_Grill|contract
Marker.Grill|06 礁石岛|Z6_Grill|contract
Marker.Grill|07 火山岛|Z7_Grill|contract
Marker.Lottery|01 鱼塘|Z1_Lottery|contract
Marker.Lottery|02 虾池|Z2_Lottery|contract
Marker.Lottery|03 蟹湖|Z3_Lottery|contract
Marker.Lottery|04 树林岛|Z4_Lottery|contract
Marker.Lottery|05 沙滩岛|Z5_Lottery|contract
Marker.Lottery|06 礁石岛|Z6_Lottery|contract
Marker.Lottery|07 火山岛|Z7_Lottery|contract
Marker.Safe|01 鱼塘|Z1_Safe|contract
Marker.Safe|02 虾池|Z2_Safe|contract
Marker.Safe|03 蟹湖|Z3_Safe|contract
Marker.Safe|04 树林岛|Z4_Safe|contract
Marker.Safe|05 沙滩岛|Z5_Safe|contract
Marker.Safe|06 礁石岛|Z6_Safe|contract
Marker.Safe|07 火山岛|Z7_Safe|contract
Marker.Shop|01 鱼塘|TGUnitShop|contract
Marker.Shop|02 虾池|TGUnitShopShrimp|contract
Marker.Shop|03 蟹湖|Z3_Shop|contract
Marker.Shop|04 树林岛|Z4_Shop|contract
Marker.Shop|05 沙滩岛|Z5_Shop|contract
Marker.Shop|06 礁石岛|Z6_Shop|contract
Marker.Shop|07 火山岛|Z7_Shop|contract
Shop.Stands|01 鱼塘|TGUnitShop|-
Shop.Stands|02 虾池|TGUnitShopShrimp|-
Shop.Stands|03 蟹湖|Z3_Shop|-
Shop.Stands|04 树林岛|Z4_Shop|-
Shop.Stands|05 沙滩岛|Z5_Shop|-
Shop.Stands|06 礁石岛|Z6_Shop|-
Shop.Stands|07 火山岛|Z7_Shop|-
]]
-- <<< GENERATED ANCHOR DATA

local world = editor:GetService('World')
local function emit(line) print(MARK .. '|' .. line) end
local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if not ok then return fallback end
    return value
end
local function unitType(unit)
    return tostring(safe(function() return unit:GetUnitType() end, '?'))
end

local anchors = {}
for line in tostring(ANCHOR_DATA):gmatch('[^\n]+') do
    local source, zone, name, state = line:match('^([^|]*)|([^|]*)|([^|]*)|(.*)$')
    if source and name and name ~= '' then
        anchors[#anchors + 1] = { source = source, zone = zone, name = name, state = state }
    end
end

-- 建立 名称 → 命中列表（路径#类型）索引，一次遍历七区子树。
local indexByName = {}
local walkErrors = 0
for _, label in ipairs(ZONES) do
    local zone = safe(function() return world:FindFirstChild(label) end, nil)
    if not zone then
        emit('ZONE|' .. label .. '|MISS')
    else
        local stack = { { zone, label } }
        while #stack > 0 do
            local item = table.remove(stack)
            local unit, path = item[1], item[2]
            local kids = safe(function() return unit:GetChildren() end, nil)
            if kids == nil then
                walkErrors = walkErrors + 1
            else
                for _, child in ipairs(kids) do
                    local cname = tostring(child.Name)
                    local cpath = path .. '/' .. cname
                    local list = indexByName[cname]
                    if list == nil then
                        list = {}
                        indexByName[cname] = list
                    end
                    list[#list + 1] = cpath .. '#' .. unitType(child)
                    stack[#stack + 1] = { child, cpath }
                end
            end
        end
    end
end

local counters = { total = 0, resolved = 0, ambiguous = 0, outOfZone = 0,
    missObserved = 0, missPlanned = 0, missUnknown = 0 }
local rows = {}
for _, entry in ipairs(anchors) do
    counters.total = counters.total + 1
    local hits = indexByName[entry.name] or {}
    local firstPath, firstType, extra, inZone = '-', '-', '', '-'
    if #hits > 0 then
        local head = hits[1]
        local sep = head:find('#', 1, true)
        firstPath = head:sub(1, sep - 1)
        firstType = head:sub(sep + 1)
        if entry.zone ~= '-' then
            inZone = firstPath:sub(1, #entry.zone) == entry.zone and 'yes' or 'no'
        end
        if #hits > 1 then
            local rest = {}
            for i = 2, #hits do rest[#rest + 1] = hits[i] end
            extra = table.concat(rest, ';')
            counters.ambiguous = counters.ambiguous + 1
        end
        if inZone == 'no' then counters.outOfZone = counters.outOfZone + 1 end
        counters.resolved = counters.resolved + 1
    elseif entry.state == 'observed' or entry.state == 'contract' then
        counters.missObserved = counters.missObserved + 1
    elseif entry.state == 'planned' then
        counters.missPlanned = counters.missPlanned + 1
    else
        counters.missUnknown = counters.missUnknown + 1
    end
    rows[#rows + 1] = table.concat({ 'A', entry.source, entry.zone, entry.name,
        'state=' .. entry.state, 'hits=' .. tostring(#hits), 'inZone=' .. inZone,
        'first=' .. firstPath, 'type=' .. firstType,
        (#hits > 1 and ('extra=' .. extra) or '') }, '|')
end
table.sort(rows)
for _, row in ipairs(rows) do emit(row) end
local nameCount = 0
for _ in pairs(indexByName) do nameCount = nameCount + 1 end
emit('SUMMARY|entries=' .. tostring(counters.total) .. '|resolved=' .. tostring(counters.resolved)
    .. '|ambiguous=' .. tostring(counters.ambiguous) .. '|outOfZone=' .. tostring(counters.outOfZone)
    .. '|missObserved=' .. tostring(counters.missObserved)
    .. '|missPlanned=' .. tostring(counters.missPlanned)
    .. '|missUnknown=' .. tostring(counters.missUnknown)
    .. '|indexNames=' .. tostring(nameCount) .. '|walkErrors=' .. tostring(walkErrors))
return MARK .. ' emitted entries=' .. tostring(counters.total)
