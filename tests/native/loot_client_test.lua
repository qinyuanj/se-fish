-- #86 迁移（原 tests/gameplay/loot_client_test.lua，#126 共享掉落客户端侧）：
-- client/LocalLoot.lua 的预警闪烁节奏、普通掉落距离判定、点击只发请求。失败方式（先列后写）：
--   1. warn 不进客户端：预警期内文字泡一直亮，玩家看不出「这份马上要被回收」；
--   2. 闪的节奏写死或不走 GameCfg.Loot.FlashIntervalSec，改配置后两侧不同步；
--   3. 预警结束（新快照不带 warn）后还在闪，闪烁状态没清；
--   4. 距离判定被闪烁带偏：2 米外的件也亮、2 米内的普通件不亮；
--   5. 点击发的不是这一件的 ItemBarAction{action='Pickup', value=<id>}；
--   6. 重复 Start 或启动失败回滚不完整，通知、闪烁和快照回调跨代叠加；
--   7. 同 id 被误重建，或消失 id 只摘索引而没有销毁；
--   8. 根 Destroy 失败被静默吞掉，其他根也无法继续清理。
local GameCfg = require('common.GameCfg')

local function signal(name, ctx)
    local callbacks = {}
    local result = {}
    function result:Connect(fn)
        ctx.connectAttempts = ctx.connectAttempts + 1
        if ctx.failConnectAt == ctx.connectAttempts then error('connect-' .. ctx.connectAttempts) end
        local record = { name = name, fn = fn, active = true }
        callbacks[#callbacks + 1] = record
        ctx.connected[#ctx.connected + 1] = record
        return { Disconnect = function()
            if not record.active then return end
            record.active = false
            ctx.disconnects[#ctx.disconnects + 1] = name
        end }
    end
    function result:Fire(...)
        for _, record in ipairs(callbacks) do
            if record.active then record.fn(...) end
        end
    end
    function result:Count()
        local count = 0
        for _, record in ipairs(callbacks) do if record.active then count = count + 1 end end
        return count
    end
    return result
end

describe("共享掉落的客户端侧", function()
    local ctx

    -- 与旧 LuaUnit 的每例 setUp/tearDown 同级成对：客户端假环境逐例重建。
    before_each(function()
        ctx = { sent = {}, events = {}, created = {}, sceneNodes = {}, connected = {},
            disconnects = {}, notices = {}, logs = {}, connectAttempts = 0 }
        ctx.originalRE = package.loaded['common.REUtil']
        ctx.originalLoot = package.loaded['client.LocalLoot']
        ctx.originalBubble = package.loaded['client.InteractionBubble']
        ctx.originalGame, ctx.originalVector3 = _G.game, _G.Vector3
        ctx.originalColor, ctx.originalVector2 = _G.Color, _G.Vector2
        ctx.originalNotice, ctx.originalPrint = _G.LocalMsgNotice, _G.print
        ctx.heartbeat = signal('Heartbeat', ctx)
        ctx.character = { Position = { x = 0, y = 0, z = 0 } }
        _G.LocalMsgNotice = function(message) ctx.notices[#ctx.notices + 1] = message end
        _G.print = function(...)
            local parts = {}
            for index = 1, select('#', ...) do parts[index] = tostring(select(index, ...)) end
            ctx.logs[#ctx.logs + 1] = table.concat(parts, ' ')
        end
        _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
        _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
        _G.Color = { New = function(...) return { ... } end }
        _G.game = { GetService = function(_, name)
            if name == 'Players' then
                return { LocalPlayer = { Character = ctx.character,
                    PlayerGui = { EuiManager = { CreateSceneNodeAtPosition = function(_, position)
                        local node = { Position = position, Visible = false, DestroyAttempts = 0 }
                        function node:Destroy()
                            self.DestroyAttempts = self.DestroyAttempts + 1
                            if self.DestroyError then error(self.DestroyError) end
                            self.Destroyed = true
                        end
                        ctx.sceneNodes[#ctx.sceneNodes + 1] = node
                        return node
                    end } } } }
            end
            if name == 'RunService' then return { Heartbeat = ctx.heartbeat } end
            if name == 'World' then
                return { CreateUnit = function(_, unitType, values)
                    local unit = { UnitType = unitType, OnClicked = signal('OnClicked', ctx) }
                    for k, v in pairs(values) do unit[k] = v end
                    function unit:Destroy() self.Destroyed = true end
                    ctx.created[#ctx.created + 1] = unit
                    return unit
                end }
            end
        end }
        package.loaded['common.REUtil'] = { GetRE = function(_, name)
            if not ctx.events[name] then
                ctx.events[name] = { OnClientEvent = signal(name, ctx),
                    FireServer = function(_, payload)
                        ctx.sent[#ctx.sent + 1] = { name = name, payload = payload }
                        if name == 'RequestLoot' and ctx.failRequest then
                            if ctx.requestSnapshot then ctx.events.LootState.OnClientEvent:Fire(ctx.requestSnapshot) end
                            error('request-failed')
                        end
                    end }
            end
            return ctx.events[name]
        end }
        package.loaded['client.LocalLoot'] = nil
        ctx.client = require('client.LocalLoot')
    end)

    -- 全局、模块缓存逐例恢复；setUp 中途失败也照样清理。
    after_each(function()
        package.loaded['common.REUtil'] = ctx.originalRE
        package.loaded['client.LocalLoot'] = ctx.originalLoot
        package.loaded['client.InteractionBubble'] = ctx.originalBubble
        _G.game, _G.Vector3 = ctx.originalGame, ctx.originalVector3
        _G.Color, _G.Vector2 = ctx.originalColor, ctx.originalVector2
        _G.LocalMsgNotice, _G.print = ctx.originalNotice, ctx.originalPrint
    end)

    local function start()
        ctx.client:Start()
    end

    local function activeCount(name)
        local event = ctx.events[name]
        return event and event.OnClientEvent:Count() or 0
    end

    local function unitNamed(name)
        for _, unit in ipairs(ctx.created) do
            if unit.Name == name then return unit end
        end
    end

    -- 点击只发这一件的拾取请求，服务端回包为准
    it("test_click_sends_pickup_request_for_that_loot", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 9, kind = 'item', itemId = 'carp', x = 0, y = 0, z = 0 } })
        local button = unitNamed('BtnPickup_9')
        assert.is_not_nil(button)
        ctx.sent = {}
        button.OnClicked:Fire()
        assert.same({ { name = 'ItemBarAction', payload = { action = 'Pickup', value = 9 } } }, ctx.sent)
    end)

    -- 掉落物从快照消失就销毁文字泡；
    it("test_missing_loot_clears_its_bubble", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 3, kind = 'item', itemId = 'carp', x = 0, y = 0, z = 0 } })
        local node = ctx.sceneNodes[1]
        ctx.events.LootState.OnClientEvent:Fire({})
        assert.is_true(node.Destroyed)
        assert.same(1, node.DestroyAttempts)
    end)

    -- 同 id 是同一静止掉落的完整快照，不重建；消失再出现才是新根。
    it("test_same_id_preserves_root_and_first_position_until_removed", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 7, kind = 'fish', x = 1, y = 2, z = 3 } })
        local original = ctx.sceneNodes[1]
        ctx.events.LootState.OnClientEvent:Fire({ { id = 7, kind = 'fish', x = 90, y = 80, z = 70, warn = true } })
        assert.same(1, #ctx.sceneNodes)
        assert.is_true(original == ctx.sceneNodes[1])
        assert.same({ x = 1, y = 2 + GameCfg.Loot.BubbleHeight, z = 3 }, original.Position)
        assert.is_nil(original.Destroyed)
        ctx.events.LootState.OnClientEvent:Fire({})
        assert.is_true(original.Destroyed)
        assert.same(1, original.DestroyAttempts)
        ctx.events.LootState.OnClientEvent:Fire({ { id = 7, kind = 'fish', x = 1, y = 2, z = 3 } })
        assert.same(2, #ctx.sceneNodes)
        assert.is_false(original == ctx.sceneNodes[2])
        assert.is_nil(ctx.sceneNodes[2].Destroyed)
    end)

    -- 活动 Start 不得叠加连接、请求、通知或预警闪烁。
    it("test_active_start_is_noop_before_host_side_effects", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 7, kind = 'fish', x = 0, y = 0, z = 0, warn = true } })
        start()
        assert.same(1, ctx.events.LootState.OnClientEvent:Count())
        assert.same(1, ctx.events.LootResult.OnClientEvent:Count())
        assert.same(1, ctx.heartbeat:Count())
        assert.same(1, #ctx.sent)
        assert.same('RequestLoot', ctx.sent[1].name)
        ctx.heartbeat:Fire(GameCfg.Loot.FlashIntervalSec / 2)
        assert.is_true(ctx.sceneNodes[1].Visible)
        ctx.events.LootResult.OnClientEvent:Fire({ reason = 'full' })
        assert.same({ '背包已满' }, ctx.notices)
    end)

    -- 启动任一步失败都回滚已成功部分，并抛出原错误；随后可完整重试。
    it("test_startup_failures_roll_back_and_retry", function()
        local failures = {
            { connect = 1, error = 'connect-1' },
            { connect = 2, error = 'connect-2' },
            { connect = 3, error = 'connect-3' },
            { request = true, error = 'request-failed' },
        }
        for _, failure in ipairs(failures) do
            ctx.failConnectAt = failure.connect
            ctx.failRequest = failure.request
            local ok, err = pcall(start)
            assert.is_false(ok)
            assert.is_truthy(tostring(err):find(failure.error, 1, true))
            assert.same(0, activeCount('LootState'))
            assert.same(0, activeCount('LootResult'))
            assert.same(0, ctx.heartbeat:Count())
            if ctx.events.LootState then
                ctx.events.LootState.OnClientEvent:Fire({ { id = 4, kind = 'fish', x = 0, y = 0, z = 0 } })
            end
            if ctx.events.LootResult then
                ctx.events.LootResult.OnClientEvent:Fire({ reason = 'full' })
            end
            ctx.heartbeat:Fire(1)
            assert.same(0, #ctx.sceneNodes)
            assert.same({}, ctx.notices)
        end
        ctx.failConnectAt = nil
        ctx.failRequest = nil
        local sent = #ctx.sent
        start()
        assert.same(1, ctx.events.LootState.OnClientEvent:Count())
        assert.same(1, ctx.events.LootResult.OnClientEvent:Count())
        assert.same(1, ctx.heartbeat:Count())
        assert.same(sent + 1, #ctx.sent)
    end)

    -- 失败后不得停留在活动态：下一次 Start 重新连接并只多一次请求，再一次则不再增加。
    it("test_failed_start_retries_once_then_stays_idle", function()
        ctx.failConnectAt = 2
        local ok, err = pcall(start)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find('connect-2', 1, true))
        assert.same(0, #ctx.sent)
        assert.same(0, activeCount('LootState'))
        assert.same(0, activeCount('LootResult'))
        assert.same(0, ctx.heartbeat:Count())

        ctx.failConnectAt = nil
        ctx.failRequest = true
        ctx.requestSnapshot = { { id = 4, kind = 'fish', x = 0, y = 0, z = 0 } }
        ok, err = pcall(start)
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find('request-failed', 1, true))
        assert.same(1, #ctx.sent)
        assert.same(0, activeCount('LootState'))
        assert.same(0, activeCount('LootResult'))
        assert.same(0, ctx.heartbeat:Count())
        assert.same(0, #ctx.sceneNodes)
        ctx.events.LootState.OnClientEvent:Fire({ { id = 4, kind = 'fish', x = 0, y = 0, z = 0 } })
        ctx.events.LootResult.OnClientEvent:Fire({ reason = 'full' })
        ctx.heartbeat:Fire(1)
        assert.same(0, #ctx.sceneNodes)
        assert.same({}, ctx.notices)

        ctx.failRequest = nil
        ctx.requestSnapshot = nil
        start()
        assert.same(2, #ctx.sent)
        assert.same(1, activeCount('LootState'))
        assert.same(1, activeCount('LootResult'))
        assert.same(1, ctx.heartbeat:Count())
        start()
        assert.same(2, #ctx.sent)
        assert.same(1, activeCount('LootState'))
        assert.same(1, activeCount('LootResult'))
        assert.same(1, ctx.heartbeat:Count())
    end)

    -- 失败尝试期间同步投递的旧回调，回滚后不得再创建、通知或改写节点。
    it("test_stale_generation_has_no_side_effects_after_rollback", function()
        ctx.requestSnapshot = { { id = 8, kind = 'fish', x = 0, y = 0, z = 0, warn = true } }
        ctx.failRequest = true
        local ok = pcall(start)
        assert.is_false(ok)
        assert.same(0, #ctx.sceneNodes)
        assert.same(0, activeCount('LootState'))
        assert.same(0, activeCount('LootResult'))
        assert.same(0, ctx.heartbeat:Count())
        ctx.failRequest = nil
        ctx.requestSnapshot = nil
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 8, kind = 'fish', x = 0, y = 0, z = 0, warn = true } })
        ctx.heartbeat:Fire(GameCfg.Loot.FlashIntervalSec / 2)
        assert.is_true(ctx.sceneNodes[1].Visible)
        ctx.events.LootResult.OnClientEvent:Fire({ reason = 'full' })
        assert.same({ '背包已满' }, ctx.notices)
    end)

    -- 一个根 Destroy 失败不得吞错或阻止其他根继续清理。
    it("test_destroy_failure_logs_loot_id_and_continues", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({
            { id = 3, kind = 'fish', x = 0, y = 0, z = 0 },
            { id = 7, kind = 'fish', x = 1, y = 0, z = 0 },
        })
        local failed = ctx.sceneNodes[1]
        failed.DestroyError = 'destroy-3'
        ctx.events.LootState.OnClientEvent:Fire({})
        assert.same(1, failed.DestroyAttempts)
        assert.is_nil(failed.Destroyed)
        assert.is_true(ctx.sceneNodes[2].Destroyed)
        assert.same(1, ctx.sceneNodes[2].DestroyAttempts)
        local found = false
        for _, line in ipairs(ctx.logs) do
            if line:find('3', 1, true) and line:find('destroy-3', 1, true) then found = true end
        end
        assert.is_true(found)
        ctx.heartbeat:Fire(1)
        assert.is_false(failed.Visible)
    end)

    -- 普通掉落不闪；出 2 米（PickupRadius）才隐藏
    it("test_plain_loot_stays_visible_and_range_still_applies", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 1, kind = 'fish', fishId = 'carp', x = 0, y = 0, z = 0 } })
        local node = ctx.sceneNodes[1]
        for _ = 1, 4 do ctx.heartbeat:Fire(0.25) end
        assert.is_true(node.Visible)
        ctx.character.Position = { x = GameCfg.Loot.PickupRadius + 1, y = 0, z = 0 }
        ctx.heartbeat:Fire(0.25)
        assert.is_false(node.Visible)
        -- 回到范围内又是亮的
        ctx.character.Position = { x = 1, y = 0, z = 0 }
        ctx.heartbeat:Fire(0.25)
        assert.is_true(node.Visible)
    end)

    -- 预警件按配置节奏闪：配置间隔的前半拍亮、后半拍暗（服务端模型同节奏）
    it("test_warned_loot_flickers_at_configured_interval", function()
        start()
        local interval = GameCfg.Loot.FlashIntervalSec
        assert.same('number', type(interval))
        ctx.events.LootState.OnClientEvent:Fire({ { id = 7, kind = 'fish', fishId = 'carp', x = 0, y = 0, z = 0, warn = true } })
        local node = ctx.sceneNodes[1]
        ctx.heartbeat:Fire(interval / 2)
        assert.is_true(node.Visible)
        ctx.heartbeat:Fire(interval / 2)
        assert.is_false(node.Visible)
        ctx.heartbeat:Fire(interval / 2)
        assert.is_false(node.Visible)
        ctx.heartbeat:Fire(interval / 2)
        assert.is_true(node.Visible)
    end)

    -- 预警结束（新快照不带 warn）后不再闪，节点回到常亮
    it("test_warning_flag_clears_with_the_next_snapshot", function()
        start()
        ctx.events.LootState.OnClientEvent:Fire({ { id = 5, kind = 'item', itemId = 'carp', x = 0, y = 0, z = 0, warn = true } })
        ctx.heartbeat:Fire(0.25)
        assert.is_true(ctx.sceneNodes[1].Visible)
        ctx.events.LootState.OnClientEvent:Fire({ { id = 5, kind = 'item', itemId = 'carp', x = 0, y = 0, z = 0 } })
        for _ = 1, 4 do ctx.heartbeat:Fire(0.25) end
        assert.is_true(ctx.sceneNodes[1].Visible)
    end)
end)
