-- #179 主界面接线：代表性控件的位置等于布局模块输出；任务追踪条折叠只在客户端本地。
-- 接缝：ScreenMain 处理器 + ItemBarState / CastState / QuestState 客户端事件 + 假 World 替身；
-- 图鉴入口经 ScreenCompendium:BuildNodes(uiRoot)。
--
-- 动手前列出的失败方式：
--   1. 某个 Build 步骤仍写死坐标，换分辨率后与布局输出不一致；
--   2. 道具栏开放格数变化后格子没有重排，拖拽命中表仍是旧位置；
--   3. 「结束收线」没有按收线期间的布局摆放，压住攻击键；
--   4. 攻击键模块仍自己写死坐标；
--   5. 编辑器摆放的金币节点没有挪进左上状态区（或节点缺失时报错）；
--   6. 图鉴入口不在右上入口组；
--   7. 任务条折叠后被下一次 QuestState 重新展开、重进界面后丢失，或折叠操作发往服务端；
--   8. 任务文字超出追踪条宽度（没有换行）；
--   9. 血量 / 饥饿度文字仍写「饥饿」。
local MainHudLayout = require('client.MainHudLayout')

local function signal()
    local listeners = {}
    return {
        Connect = function(_, fn)
            listeners[#listeners + 1] = fn
            return { Disconnect = function()
                for i, cb in ipairs(listeners) do
                    if cb == fn then table.remove(listeners, i) break end
                end
            end }
        end,
        Fire = function(_, ...) for _, fn in ipairs(listeners) do fn(...) end end,
    }
end

local GLOBALS = { 'game', 'Vector2', 'Color', 'REUtil', 'GameUI', 'MgrGameUI', 'LocalReelIn' }

local function setUp(height)
    local ctx = { nodes = {}, created = {}, sent = {}, events = {}, now = 100, height = height }
    ctx.previous = {}
    for _, key in ipairs(GLOBALS) do ctx.previous[key] = rawget(_G, key) end
    ctx.previousAttack = package.loaded['client.LocalAttackButton']
    package.loaded['client.LocalAttackButton'] = nil
    _G.MgrGameUI = { SetCustomControlUI = function() end, GetScreen = function() end, CloseScreen = function() end }
    local world = { Created = ctx.created }
    function world:CreateUnit(kind, attrs)
        local node = { Kind = kind, OnClicked = signal() }
        for key, value in pairs(attrs) do node[key] = value end
        function node:Destroy()
            self.Destroyed = true
            for _, child in ipairs(world.Created) do
                if child.Parent == self then child:Destroy() end
            end
        end
        ctx.nodes[node.Name] = node
        ctx.created[#ctx.created + 1] = node
        return node
    end
    function world:GetServerTime() return ctx.now end
    local attributes = { Health = 80, MaxHealth = 100, Hunger = 60, MaxHunger = 100, FishCoin = 5 }
    local player = { GetAttribute = function(_, key) return attributes[key] end,
        GetAttributeChangedSignal = function() return signal() end }
    _G.game = { GetService = function(_, name)
        if name == 'World' then return world end
        if name == 'Players' then return { LocalPlayer = player } end
    end }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(...) return { ... } end }
    _G.GameUI = { GetEuiManager = function() return {
        GetDeviceResolution = function() return { x = 1920, y = height } end,
    } end, GetUIRoot = function() return ctx.uiRoot end }
    _G.REUtil = { GetRE = function(_, name)
        if not ctx.events[name] then
            ctx.events[name] = { OnClientEvent = signal(), FireServer = function(_, payload)
                ctx.sent[#ctx.sent + 1] = { name = name, payload = payload }
            end }
        end
        return ctx.events[name]
    end }
    _G.LocalReelIn = { SetSession = function(self, session) self.SessionId = session end,
        Clear = function() end, Suspend = function() end }
    -- 编辑器摆放的金币节点：ScreenMain 的直接子节点，运行时按名查找
    ctx.nodes.ImageCoin = { Name = 'ImageCoin', Position = { x = 864, y = 1145 }, Size = { x = 80, y = 80 } }
    ctx.nodes.LabelCoin = { Name = 'LabelCoin', Position = { x = 960, y = 1145 }, Size = { x = 200, y = 60 } }
    ctx.handler = assert(loadfile('client/ScreenHandlers/ScreenMain.lua'))()
    ctx.handler.RootNode = { Name = 'ScreenMain', FindFirstChild = function(_, name) return ctx.nodes[name] end }
    ctx.handler:Init()
    ctx.handler.IsOpen = true
    return ctx
end

local function tearDown(ctx)
    require('client.LocalAttackButton'):Destroy()
    package.loaded['client.LocalAttackButton'] = ctx.previousAttack
    for _, key in ipairs(GLOBALS) do _G[key] = ctx.previous[key] end
end

local function layoutFor(height, slots, reeling)
    return MainHudLayout.Compute({ width = 1920, height = height, itemBarSlots = slots, reeling = reeling })
end

local function assertAt(node, rect, label)
    assert.is_not_nil(node, label)
    assert.same({ x = rect.x, y = rect.y }, { x = node.Position.x, y = node.Position.y }, label)
    assert.same({ x = rect.w, y = rect.h }, { x = node.Size.x, y = node.Size.y }, label)
end

local function overlaps(a, b)
    return math.abs(a.Position.x - b.Position.x) * 2 < a.Size.x + b.Size.x
        and math.abs(a.Position.y - b.Position.y) * 2 < a.Size.y + b.Size.y
end

describe('主界面接线（布局模块）', function()
    local ctx
    after_each(function() if ctx then tearDown(ctx) end ctx = nil end)

    for _, height in ipairs({ 886, 1080, 1238, 1440 }) do
        it('test_representative_controls_follow_layout_' .. height, function()
            ctx = setUp(height)
            ctx.events.ItemBarState.OnClientEvent:Fire({ slots = {}, slotCount = 2, bait = {},
                backpackCount = 5 })
            local layout = layoutFor(height, 2, false)
            local r = layout.Rects
            assertAt(ctx.nodes.HealthRing, r.HealthRing, 'HealthRing')
            assertAt(ctx.nodes.HungerRing, r.HungerRing, 'HungerRing')
            assertAt(ctx.nodes.ImageCoin, r.CoinIcon, 'ImageCoin')
            assertAt(ctx.nodes.LabelCoin, r.CoinLabel, 'LabelCoin')
            assertAt(ctx.nodes.ItemBarSlot1, r.ItemBarSlot1, 'ItemBarSlot1')
            assertAt(ctx.nodes.ItemBarSlot2, r.ItemBarSlot2, 'ItemBarSlot2')
            assertAt(ctx.nodes.BtnBackpack, r.BackpackButton, 'BtnBackpack')
            assertAt(ctx.nodes.ItemAction2, r.ItemAction, 'ItemAction2')
            assertAt(ctx.nodes.ItemDiscard, r.Discard, 'ItemDiscard')
            assertAt(ctx.nodes.AttackControl, r.AttackControl, 'AttackControl')
            assertAt(ctx.nodes.QuestBackground, r.QuestPanel, 'QuestBackground')
            assertAt(ctx.nodes.QuestToggle, r.QuestToggle, 'QuestToggle')
            assertAt(ctx.nodes.HookHint, r.HintPrimary, 'HookHint')
            assertAt(ctx.nodes.CastWaitHint, r.HintPrimary, 'CastWaitHint')
            assertAt(ctx.nodes.CastSplashHint, r.HintSecondary, 'CastSplashHint')
            assertAt(ctx.nodes.CastFailureHint, r.HintTransient, 'CastFailureHint')
            assertAt(ctx.nodes.BackpackPanel, layout.Panels.BackpackPanel, 'BackpackPanel')
            assert.same({ x = r.HintSecondary.x, y = r.HintSecondary.y },
                { x = ctx.nodes.ReelProgress.Position.x, y = ctx.nodes.ReelProgress.Position.y })
            -- 按钮文字与按钮同位同尺寸
            for labelName, buttonName in pairs({ BtnItemActionLabel = 'ItemAction2',
                BtnDiscardLabel = 'ItemDiscard', LabelBackpack = 'BtnBackpack', QuestToggleLabel = 'QuestToggle' }) do
                assert.same(ctx.nodes[buttonName].Position, ctx.nodes[labelName].Position, labelName)
                assert.same(ctx.nodes[buttonName].Size, ctx.nodes[labelName].Size, labelName)
            end
            -- 道具栏格内的图标、名字、数量都落在格子里
            local slot = ctx.nodes.ItemBarSlot1
            for _, name in ipairs({ 'ItemBarIcon1', 'ItemBarLabel1', 'ItemBarAmount1' }) do
                local n = ctx.nodes[name]
                assert.is_true(math.abs(n.Position.x - slot.Position.x) * 2 + n.Size.x <= slot.Size.x + 0.01, name)
                assert.is_true(math.abs(n.Position.y - slot.Position.y) * 2 + n.Size.y <= slot.Size.y + 0.01, name)
            end
        end)
    end

    it('test_item_bar_relayout_when_slot_count_changes', function()
        ctx = setUp(1080)
        ctx.events.ItemBarState.OnClientEvent:Fire({ slots = {}, slotCount = 2, bait = {}, backpackCount = 5 })
        local two = layoutFor(1080, 2, false)
        assertAt(ctx.nodes.ItemBarSlot2, two.Rects.ItemBarSlot2, 'slot2 @2')
        ctx.events.ItemBarState.OnClientEvent:Fire({ slots = {}, slotCount = 8, bait = {}, backpackCount = 5 })
        local eight = layoutFor(1080, 8, false)
        for i = 1, 8 do assertAt(ctx.nodes['ItemBarSlot' .. i], eight.Rects['ItemBarSlot' .. i], 'slot' .. i) end
        assertAt(ctx.nodes.BtnBackpack, eight.Rects.BackpackButton, 'BtnBackpack @8')
        -- 拖拽命中表随之更新：新位置命中对应格
        local hit = ctx.handler:SlotAtPosition({ x = eight.Rects.ItemBarSlot8.x, y = eight.Rects.ItemBarSlot8.y })
        assert.same(8, hit and hit.index)
    end)

    it('test_reel_close_uses_reeling_layout_clear_of_attack', function()
        ctx = setUp(886)
        ctx.events.ItemBarState.OnClientEvent:Fire({ slots = {}, slotCount = 2, bait = {}, backpackCount = 5 })
        ctx.events.CastState.OnClientEvent:Fire({ phase = 'hooked', reelSession = 's1' })
        local close = ctx.nodes.ReelClose
        assert.is_true(close.Visible)
        assertAt(close, layoutFor(886, 2, true).Rects.ReelClose, 'ReelClose')
        assert.same(close.Position, ctx.nodes.BtnReelCloseLabel.Position)
        assert.is_false(overlaps(close, ctx.nodes.AttackControl))
        assert.is_false(overlaps(close, ctx.nodes.ItemAction2))
    end)

    it('test_quest_toggle_collapses_locally_and_survives_refresh', function()
        ctx = setUp(1080)
        local quest = ctx.events.QuestState.OnClientEvent
        assert.is_false(ctx.nodes.QuestToggle.Visible) -- 还没有任务文字时不占位
        quest:Fire({ text = '新手任务 1/9：拾取 5 只蚯蚓（0/5）' })
        assert.is_true(ctx.nodes.QuestLabel.Visible)
        assert.is_true(ctx.nodes.QuestToggle.Visible)
        assert.same('收起任务', ctx.nodes.QuestToggleLabel.Text)
        local before = #ctx.sent
        ctx.nodes.QuestToggle.OnClicked:Fire()
        assert.same(before, #ctx.sent, '折叠不发往服务端')
        assert.is_false(ctx.nodes.QuestLabel.Visible)
        assert.is_false(ctx.nodes.QuestBackground.Visible)
        assert.is_true(ctx.nodes.QuestToggle.Visible)
        assert.same('展开任务', ctx.nodes.QuestToggleLabel.Text)
        -- 推进时的新任务文字不会把折叠的追踪条重新展开
        quest:Fire({ text = '新手任务 2/9：喂钓鱼佬吃 5 只蚯蚓（0/5）' })
        assert.is_false(ctx.nodes.QuestLabel.Visible)
        -- 换根节点重进后折叠状态仍在（客户端本地）
        ctx.handler.RootNode = { Name = 'ScreenMain', FindFirstChild = function() return nil end }
        ctx.handler:Init()
        ctx.handler.IsOpen = true
        ctx.events.QuestState.OnClientEvent:Fire({ text = '新手任务 2/9：喂钓鱼佬吃 5 只蚯蚓（0/5）' })
        assert.is_false(ctx.nodes.QuestLabel.Visible)
        assert.same('展开任务', ctx.nodes.QuestToggleLabel.Text)
        local afterReentry = #ctx.sent
        ctx.nodes.QuestToggle.OnClicked:Fire()
        assert.is_true(ctx.nodes.QuestLabel.Visible)
        assert.is_true(ctx.nodes.QuestBackground.Visible)
        assert.same(afterReentry, #ctx.sent, '展开也不发往服务端')
    end)

    it('test_quest_text_wraps_inside_panel', function()
        ctx = setUp(886)
        local text = '新手任务 6/9：上钩后连续点击收线，将鱼钓上岸（0/1）'
        ctx.events.QuestState.OnClientEvent:Fire({ text = text })
        local label = ctx.nodes.QuestLabel
        assert.is_true(label.Size.x <= 1920 / 4)
        local lines = 0
        for line in (label.Text .. '\n'):gmatch('(.-)\n') do
            lines = lines + 1
            assert.is_true(utf8.len(line) * label.FontSize <= label.Size.x, line)
        end
        assert.is_true(lines >= 2)
        assert.is_true(lines * label.FontSize <= label.Size.y)
        assert.same(text, (label.Text:gsub('\n', '')))
    end)

    it('test_hunger_text_uses_glossary_term', function()
        ctx = setUp(1080)
        ctx.handler:ShowVitals()
        assert.same('饥饿度 60', ctx.nodes.HungerText.Text)
        assert.same('血 80', ctx.nodes.HealthText.Text)
        local file = assert(io.open('client/ScreenHandlers/ScreenMain.lua', 'r'))
        local source = file:read('*a')
        file:close()
        assert.is_nil(source:find("'饥饿 '", 1, true))
    end)
end)

describe('右上入口组接线（图鉴入口）', function()
    local saved
    before_each(function()
        saved = { loaded = {}, globals = {} }
        for _, key in ipairs({ 'game', 'Vector2', 'Color', 'MgrGameUI' }) do saved.globals[key] = rawget(_G, key) end
        for _, name in ipairs({ 'client.GameUI', 'common.REUtil' }) do saved.loaded[name] = package.loaded[name] end
    end)
    after_each(function()
        for key, value in pairs(saved.globals) do rawset(_G, key, value) end
        for _, name in ipairs({ 'client.GameUI', 'common.REUtil' }) do package.loaded[name] = saved.loaded[name] end
    end)

    for _, height in ipairs({ 886, 1440 }) do
        it('test_compendium_entry_follows_layout_' .. height, function()
            local nodes = {}
            local world = { CreateUnit = function(_, _, attrs)
                local node = { OnClicked = signal(), Destroy = function() end }
                for key, value in pairs(attrs) do node[key] = value end
                nodes[node.Name] = node
                return node
            end }
            rawset(_G, 'game', { GetService = function(_, name) if name == 'World' then return world end end })
            rawset(_G, 'Vector2', { New = function(x, y) return { x = x, y = y } end })
            rawset(_G, 'Color', { New = function(...) return { ... } end })
            rawset(_G, 'MgrGameUI', { GetScreen = function() end, CloseScreen = function() end })
            package.loaded['client.GameUI'] = { GetEuiManager = function() return {
                GetDeviceResolution = function() return { x = 1920, y = height } end } end,
                GetUIRoot = function() return {} end }
            package.loaded['common.REUtil'] = { GetRE = function() return { OnClientEvent = signal(),
                FireServer = function() end } end }
            local screen = assert(loadfile('client/ScreenHandlers/ScreenCompendium.lua'))()
            assert.is_true(screen:BuildNodes({ Name = 'UIRoot' }))
            local rect = layoutFor(height, 2, false).Rects.CompendiumEntry
            assertAt(nodes.BtnCompendiumEntry, rect, 'BtnCompendiumEntry')
        end)
    end
end)
