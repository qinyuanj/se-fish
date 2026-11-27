-- 区域标记契约（common/zone_markers.lua 的 ZoneMarkers.contract）：编辑器里按这份清单摆锚点，
-- 解析期按同一批名字取位置，两边只靠它对齐，所以它必须跟着 GameCfg 的三张真源表走。
-- 失败方式：区域增减后契约漏掉某区的渔夫或商店锚点、产出 nil 名字；同一区域两个角色共用名字，
-- 场景寻址不确定；渡轮返程锚点挂错区号（返程锚点挂到出发岛）；契约不再读真源表而写死名字。
local GameCfg = require("common.game_cfg")
local ZoneMarkers = require("common.zone_markers")

local function index_by_zone(entries)
    local by_zone = {}
    for _, entry in ipairs(entries) do
        local zone = by_zone[entry.zone_index] or {}
        by_zone[entry.zone_index] = zone
        zone[entry.role] = zone[entry.role] or {}
        table.insert(zone[entry.role], entry.Name)
    end
    return by_zone
end

describe("ZoneMarkers.contract 区域标记契约", function()
    it("每个区域的锚点跟着渔夫/商店/渡轮真源表走，且同区域名字不重复", function()
        local by_zone = index_by_zone(ZoneMarkers.contract(GameCfg))
        for index = 1, #GameCfg.Zones do
            local zone = assert(by_zone[index], "区域 " .. index .. " 没有契约条目")
            assert.same({ GameCfg.Interact.Fishermen[index].AnchorNames[1] }, zone.Fisherman)
            assert.same({ GameCfg.Shop.Stands[index].AnchorName }, zone.Shop)
            assert.same({ "Z" .. index .. "_Safe" }, zone.Safe)
            assert.same({ "Z" .. index .. "_Lottery" }, zone.Lottery)
            local sides = {}
            for _, side in ipairs({ "West", "East", "South", "North" }) do
                sides[#sides + 1] = "Z" .. index .. "_Boundary" .. side
            end
            assert.same(sides, zone.Boundary)
            local seen = {}
            for role, names in pairs(zone) do
                for _, name in ipairs(names) do
                    assert.is_nil(seen[name], "区域 " .. index .. " 的两个角色共用名字 " .. name)
                    seen[name] = role
                end
            end
        end
        for route_index, route in ipairs(GameCfg.Ferry.Routes) do
            assert.same({ route.Outbound.AnchorName }, by_zone[route_index].FerryOut)
            assert.same({ route.Return.AnchorName }, by_zone[route_index + 1].FerryReturn,
                "返程锚点必须挂在目的地岛（区号 " .. (route_index + 1) .. "）")
        end
    end)

    it("配置真源缺行时直接报错，不产出空名字", function()
        assert.has_error(function()
            ZoneMarkers.contract({
                Zones = GameCfg.Zones,
                Interact = { Fishermen = { GameCfg.Interact.Fishermen[1] } },
                Shop = GameCfg.Shop,
                Ferry = GameCfg.Ferry,
            })
        end)
        assert.has_error(function()
            ZoneMarkers.contract({
                Zones = GameCfg.Zones,
                Interact = GameCfg.Interact,
                Shop = { Stands = { GameCfg.Shop.Stands[1] } },
                Ferry = GameCfg.Ferry,
            })
        end)
    end)
end)
