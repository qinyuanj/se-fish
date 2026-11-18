-- #214 收尾回溯的跨真源守卫：client/ScreenHandlers/ScreenShop.lua 的 UINodes 名册
-- 与编辑器实际导出的节点树 data/UINodes.lua 绑定。这次收尾只靠人眼核对名册与导出树，差点漏掉。
--
-- 失败方式先列（每个用例对应其中一条）：
--   1. 名字改了场景没更新：预制体里把节点改名或删掉，名册还写着旧名 → Init 只打一行「找不到界面子节点」
--      就继续跑，控件静默变空（用例 1）；
--   2. 场景加了节点代码没登记：编辑器里新摆的节点没人读，玩家看得见、状态不跟着变（用例 2）；
--   3. 重名导致深查抓错：Init 用 FindFirstChild(name, true) 深查取第一个命中，重名不报错、静默抓到别的节点
--      （用例 3）；
--   4. 白名单被当成橡皮图章：为了让断言变绿，把归代码管的节点抄进装饰白名单，或把改名前的旧名字留在
--      白名单里兜住失效的名册（用例 2 的白名单两条检查）。
--
-- 口径：树的一侧从 data/UINodes.lua 里 ScreenShop 这一棵的**后代**开始收集（节点形如 {name, type, {子节点...}}）；
-- 根名 ScreenShop 由顶层条目本身保证，不在名册里。SceneNodeShop 下也有一个 LabelShopTitle，在子树之外，不算。
-- 只为拿 ScreenShop.UINodes 加载 handler：不调 Init()、不建节点、不碰 UINodeMap。

local HANDLER = 'client/ScreenHandlers/ScreenShop.lua'
local TREE = 'data/UINodes.lua'

-- 装饰白名单：ScreenShop 子树里确实存在、但代码从不按名字取的节点（对着 ScreenShop.lua 的 UINodes 核过，正好 4 个）。
-- 只放真正不归代码管的：整屏背景、内容根（坐标基准）、静态标题、金币条图标。
-- 新增条目要能说清「代码为什么不管它」；同一个名字不能既在白名单又在名册里。
local DECORATIONS = {
    ShopRootBG = true,
    ShopRoot = true,
    LabelShopTitle = true,
    ImageShopCoin = true,
}

-- 只在失败分支拼消息（本仓测试纪律：通过的断言不付一次 string.format 的钱）
local function fail(fmt, ...)
    assert.is_true(false, string.format(fmt, ...))
end

-- 只为拿 UINodes 的最小加载：handler 顶层读 LocalShop.ShopText / FailText，皮肤表在模块加载期调一次
-- Color.New 填色板——两个桩之外什么都不碰（不 Init、不建节点、不碰 UINodeMap）。
local function loadHandler()
    local previousColor, previousLocalShop = rawget(_G, 'Color'), package.loaded['client.LocalShop']
    _G.Color = { New = function(...) return { ... } end }
    package.loaded['client.LocalShop'] = { ShopText = {}, FailText = {} }
    local ok, handler = pcall(function() return assert(loadfile(HANDLER))() end)
    _G.Color, package.loaded['client.LocalShop'] = previousColor, previousLocalShop
    if not ok then
        fail('%s 加载失败（本文件只需要 Color 与 client.LocalShop 两个桩）：%s', HANDLER, tostring(handler))
    end
    return handler
end

-- 读编辑器的导出树，取出点名的那一棵（data/ 只读，只能从导出物这一侧取真源）。
local function exportedSubtree(name)
    local chunk, loadError = loadfile(TREE)
    if not chunk then
        fail('%s 读不出来（data/ 只读，改名或挪走会让这条守卫失去真源）：%s', TREE, tostring(loadError))
    end
    local ok, tree = pcall(chunk)
    if not ok then fail('%s 求值失败（应当只有 return {...} 的纯 Lua 表）：%s', TREE, tostring(tree)) end
    local node
    for _, candidate in ipairs(tree or {}) do
        if candidate[1] == name then node = candidate break end
    end
    if not node then fail('%s 里没有 %s 这一棵（界面被删或改名，handler 与预制体已经脱钩）', TREE, name) end
    return node
end

-- 深查收集后代的名字与出现次数：根节点自己不算（根名由 data/UINodes.lua 的顶层条目保证）。
local function countDescendants(node, counts)
    for _, child in ipairs(node[3] or {}) do
        counts[child[1]] = (counts[child[1]] or 0) + 1
        countDescendants(child, counts)
    end
    return counts
end

describe('ScreenShop 名册与编辑器导出树', function()
    local roster, rosterSet, treeCounts

    before_each(function()
        roster = loadHandler().UINodes
        rosterSet = {}
        for _, name in ipairs(roster) do rosterSet[name] = true end
        treeCounts = countDescendants(exportedSubtree('ScreenShop'), {})
    end)

    -- 名册 ⊆ 树：handler 要按名字深查的每个节点，编辑器导出的 ScreenShop 子树里都得在。
    it('test_roster_names_all_exist_in_exported_subtree', function()
        local missing = {}
        for _, name in ipairs(roster) do
            if not treeCounts[name] then missing[#missing + 1] = name end
        end
        if #missing > 0 then
            fail('名册里有 %d 个名字在 ScreenShop 子树里不存在：%s。预制体改名或删节点后要同步 %s 的 UINodes',
                #missing, table.concat(missing, ', '), HANDLER)
        end
    end)

    -- 树 ⊆ 名册 ∪ 装饰白名单：导出树里每个节点要么被代码按名取，要么显式声明不归代码管。
    -- 白名单另守两条，防止它变成橡皮图章：名字不得同时出现在名册里；不得留下树里已不存在的旧名字。
    it('test_exported_nodes_are_registered_or_decorative', function()
        local unmanaged = {}
        for name in pairs(treeCounts) do
            if not rosterSet[name] and not DECORATIONS[name] then unmanaged[#unmanaged + 1] = name end
        end
        if #unmanaged > 0 then
            table.sort(unmanaged)
            fail('ScreenShop 子树里有 %d 个节点既没登记进 UINodes、也不在装饰白名单里：%s。'
                .. '新摆的节点要么登记进名册，要么写明它为什么不归代码管',
                #unmanaged, table.concat(unmanaged, ', '))
        end
        local doubled, stale = {}, {}
        for name in pairs(DECORATIONS) do
            if rosterSet[name] then doubled[#doubled + 1] = name end
            if not treeCounts[name] then stale[#stale + 1] = name end
        end
        if #doubled > 0 then
            table.sort(doubled)
            fail('装饰白名单里有名字同时登记进了 UINodes：%s。白名单不是让断言变绿的抽屉：归代码管的节点只进名册',
                table.concat(doubled, ', '))
        end
        if #stale > 0 then
            table.sort(stale)
            fail('装饰白名单里留着 ScreenShop 子树里不存在的名字：%s。改名后把旧名填进白名单，等于用白名单兜住失效的名册',
                table.concat(stale, ', '))
        end
    end)

    -- 名字在 ScreenShop 子树里唯一：Init 深查取第一个命中，重名会静默抓到错节点。
    it('test_roster_names_appear_once_in_exported_subtree', function()
        local repeated = {}
        for _, name in ipairs(roster) do
            local count = treeCounts[name] or 0
            if count > 1 then repeated[#repeated + 1] = name .. 'x' .. count end
        end
        if #repeated > 0 then
            fail('ScreenShop 子树里重名：%s。Init 的 FindFirstChild(name, true) 深查只取第一个命中，重名会静默抓到别的节点',
                table.concat(repeated, ', '))
        end
    end)
end)
