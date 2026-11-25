-- 本地连接夹具（#264）：在一个测试进程里复现 server/main.lua 的「加入 → 读档就绪 → 在线 → 离场」连接生命周期，
-- 让 8 条以上虚拟连接驱动小队、PK、他人抢救与共享地面实例的完整代码路径。
--
-- 口径（ADR-0029 第三节第 10 行、条款 1-04 / 19-12）：夹具只证明**代码路径完整**，
-- 不证明真实容量，也不证明真实多人行为；真实平台容量与真实多人结论是生产开关，由平台/人另行签署，
-- 夹具结论不替代它。用例与探针里不得把夹具通过写成「容量已验收」「多人已验收」。
--
-- 不加生产代码分支、不读管理器私有表。引擎边界（Task / World / DataStoreService / Players /
-- RunService / PhysicsService / Vector3 / Vector2 / Color / REUtil）用替身，close 时逐项还原。
--
-- 与 server/main.lua 的接线一一对应：WIRING 逐行核对，接线一改这里先红（先红再改夹具，别让夹具漂走）。
-- 在 main.lua 里也有 on_player_added / BeforeLeave 钩子，它们的路径不在本夹具声明的覆盖范围里。
-- MgrLoot 只用于共享地面实例（SpawnItem / pickup / snapshot），**不调 Start**：点位鱼饵刷新
-- 与区上限回收由 MgrLoot 自己的用例覆盖，连接夹具不替它起刷新区。

local M = {}

local function vec(x, y, z) return { x = x, y = y, z = z } end

local function signal()
    local slots = {}
    return {
        Connect = function(_, fn) slots[#slots + 1] = fn return { Disconnect = function() end } end,
        Fire = function(_, ...) for _, fn in ipairs(slots) do fn(...) end end,
    }
end

-- 复现的接线：每行都是 server/main.lua 的原文子串，缺一行就说明生产装配变了。
M.WIRING = {
    'player_data = PlayerDataHost',
    'save = SaveHost',
    'Vitals = runtime.life',
    'bind_party_action = function(dispatch)',
    'bind_party_state_request = function(dispatch)',
    'bind_interact_action = function(dispatch)',
    'local fishHost = WorldRuntime.fish_host',
}

function M.assert_wiring()
    local handle = assert(io.open('server/main.lua', 'rb'), '读不到 server/main.lua')
    local source = handle:read('a')
    handle:close()
    local runtime_handle = assert(io.open('server/world_host/server_runtime.lua', 'rb'), '读不到 server/world_host/server_runtime.lua')
    source = source .. '\n' .. runtime_handle:read('a')
    runtime_handle:close()
    for _, line in ipairs(M.WIRING) do
        assert(source:find(line, 1, true), 'server/main.lua 里找不到接线：' .. line)
    end
end

-- 就绪顺序照 server/main.lua 的 on_ready：先操作角色与生命状态的那批，再其余管理器。
local READY_FIRST = { 'Vitals', 'Survival' }
local READY_REST = {}
-- 离场顺序照 ContinuePlayerRemoving：终镜像先于序列化，序列化先于其余管理器的 on_player_removing。
local LEAVING_REST = { 'Vitals', 'Survival' }

-- 前向声明：M:Start 与 handleAdded 的读档回调都转发到它（实现见下方连接生命周期段）。
local onReady

local function new_player(env, userId, position, name)
    local controller = {
        Health = env.cfg.Vitals.MaxHealth, MaxHealth = env.cfg.Vitals.MaxHealth, WalkSpeed = 10,
        HealthChanged = signal(), Died = signal(), OnReborn = signal(),
    }
    function controller:TakeDamage(amount)
        self.Health = math.max(0, self.Health - amount)
        self.HealthChanged:Fire(self.Health)
        if self.Health <= 0 then self.Died:Fire() end
    end
    local player = { UserId = userId, Name = name or ('p' .. userId), attrs = {} }
    player.Character = {
        Position = position or vec(0, 0, 0),
        Controller = controller,
        SetPosition = function(self, pos) self.Position = pos end,
    }
    player.CharacterAdded, player.CharacterRemoving = signal(), signal()
    player.SetAttribute = function(self, key, value) self.attrs[key] = value end
    player.GetAttribute = function(self, key) return self.attrs[key] end
    return player
end

--- 建一套连接夹具：装引擎替身、加载并装配管理器，但不 Start。
--- 调用方随后 link:start()（等价 GameStart），结束时必须 link:close()。
function M.new(opts)
    opts = opts or {}
    local GameCfg = require('common.game_cfg')
    local ZoneFixtures = require('tests.support.zone_fixtures')
    local ZoneMarkers = require('common.zone_markers')
    if not ZoneMarkers.ready then ZoneFixtures.apply(GameCfg) end

    local env = {
        cfg = GameCfg, queue = {}, sent = {}, re = {}, values = {}, online_players = {}, created = {},
        now = opts.now or 1000, started = false, active = {}, current = {}, leaving = {}, ready = {},
        saved = {
            game = rawget(_G, 'game'), Vector3 = rawget(_G, 'Vector3'), Vector2 = rawget(_G, 'Vector2'),
            Color = rawget(_G, 'Color'), REUtil = rawget(_G, 'REUtil'), task = rawget(_G, 'task'),
            reutil = package.loaded['common.re_util'], playerdata = package.loaded['server.data.player_data'],
            carrier = package.loaded['server.world_host.fish_carrier'],
        },
    }

    local function reStub(name)
        env.sent[name] = env.sent[name] or {}
        if not env.re[name] then
            env.re[name] = {
                OnServerEvent = signal(), OnClientEvent = signal(),
                FireClient = function(_, player, value)
                    env.sent[name][#env.sent[name] + 1] = { userId = player and player.UserId, payload = value }
                end,
                FireAllClients = function(_, value)
                    env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = value }
                end,
                FireServer = function(_, payload)
                    env.sent[name][#env.sent[name] + 1] = { userId = nil, payload = payload }
                end,
            }
        end
        return env.re[name]
    end

    env.playersService = { GetPlayers = function()
        local list = {}
        for _, player in pairs(env.online_players) do list[#list + 1] = player end
        return list
    end, LocalPlayer = nil }

    _G.Vector3 = { New = vec }
    _G.Vector2 = { New = function(x, y) return { x = x, y = y } end }
    _G.Color = { New = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end }
    _G.game = {
        GetService = function(_, name)
            if name == 'Task' then
                return {
                    Spawn = function(_, fn) env.queue[#env.queue + 1] = fn end,
                    Wait = function() end,
                }
            end
            if name == 'DataStoreService' then
                return { GetDataStore = function() return {
                    GetAsync = function(_, key) return env.values[key] end,
                    SetAsync = function(_, key, value) env.values[key] = value end,
                    UpdateAsync = function(_, key, transform)
                        local value = transform(env.values[key])
                        if value ~= nil then env.values[key] = value end
                        return value
                    end,
                } end }
            end
            if name == 'World' then
                return {
                    GetServerTime = function() return env.now end,
                    CreateUnit = function(_, kind, props)
                        local node = { Kind = kind, UnitType = kind }
                        for key, value in pairs(props or {}) do node[key] = value end
                        node.OnClicked = signal()
                        node.Destroy = function() node.Destroyed = true end
                        env.created[#env.created + 1] = node
                        return node
                    end,
                }
            end
            if name == 'PhysicsService' then
                return { Raycast = function() return nil end }
            end
            if name == 'Players' then return env.playersService end
            if name == 'RunService' then
                return { IsServer = function() return true end, Heartbeat = signal() }
            end
        end,
        BindToClose = function() end,
    }
    local re = { get_re = function(_, name) return reStub(name) end, check_recd = function() return false end }
    package.loaded['common.re_util'] = re
    _G.REUtil = re

    package.loaded['server.data.player_data'] = nil
    env.PlayerData = require('server.data.player_data')
    env.managers = {
        Save = assert(loadfile('server/save_host.lua'))(),
        PlayerData = assert(loadfile('server/player_data_host.lua'))(),
        Party = {},
    }
    local mgr = env.managers
    env.filter = function()
        return require('server.world_host.pk_damage_filter').make({
            party = mgr.Party,
            zone_markers = require('common.zone_markers'),
        })
    end

    mgr.Save.PlayerData = mgr.PlayerData
    mgr.PlayerData.Save = mgr.Save
    function mgr.Party:same_party(a, b)
        local squad = env.lifeHost and env.lifeHost.runtime.world.squad
        return squad and squad:same_party(a, b) or false
    end
    function mgr.Party:Count(player)
        local squad = env.lifeHost and env.lifeHost.runtime.world.squad
        return squad and squad:Count(player) or 0
    end
    -- #255 生产接线：统一伤害入口的过滤函数由 MgrPkFilter 工厂实例化，只读注入的权威队伍与区域入口。
    env.lifeHost = require('tests.support.life_host').start({
      now = env.now, remote = re, player_data = mgr.PlayerData, save = mgr.Save,
      bind_interact_action = function(dispatch)
        re:get_re('InteractAction').OnServerEvent:Connect(function(player, payload)
          dispatch(player, payload)
        end)
      end,
    })
    mgr.Vitals = env.lifeHost.runtime.life
    mgr.Survival = mgr.Vitals
    mgr.PlayerData.Vitals = mgr.Vitals
    mgr.Vitals.Party = mgr.Party
    mgr.Vitals.ZoneMarkers = ZoneMarkers
    mgr.Vitals:set_damage_filter(env.filter())

    env.player = function(self, userId, position, name) return new_player(self, userId, position, name) end
    return setmetatable(env, { __index = M })
end

-- ===== 任务队列与世界时钟 =====

function M:tick()
    for _ = 1, 500 do
        if #self.queue == 0 then return self end
        table.remove(self.queue, 1)()
    end
    error('Task 队列未收敛')
end

function M:advance(seconds)
    self.now = self.now + (seconds or 0)
    if self.started then
        self.lifeHost.clock:advance(seconds or 0)
        self.now = self.lifeHost.clock.now()
        self.managers.Save:update()
    end
    return self:tick()
end

function M:start()
    M.assert_wiring()
    -- 读档就绪回调：main.lua 用 MgrSave.on_ready 分发第一批管理器的 on_player_added，
    -- 这里接同一个入口，而不是自己另写一套「加入后初始化」。
    self.managers.Save.on_ready = function(player, data) onReady(self, player, data) end
    for _, name in ipairs({ 'Save', 'PlayerData' }) do
        local manager = self.managers[name]
        if manager.Start then manager.start(manager) end
    end
    self.started = true
    for userId, entry in pairs(self.ready) do
        self.ready[userId] = nil
        self.managers.Save.on_ready(entry[1], entry[2])
    end
    return self:tick()
end

-- ===== 连接生命周期（server/main.lua 的同构子集）=====

onReady = function(env, player, data)
    local userId = player.UserId
    if env.current[userId] ~= player or env.leaving[userId]
        or env.managers.PlayerData:get_data_inst(player) ~= data or env.active[userId] == player then
        return
    end
    if not env.started then env.ready[userId] = { player, data } return end
    env.active[userId] = player
    env.lifeHost:add(player, data)
    for _, name in ipairs(READY_FIRST) do
        local manager = env.managers[name]
        if manager.on_player_added then manager:on_player_added(player) end
    end
    for _, name in ipairs(READY_REST) do
        local manager = env.managers[name]
        if manager.on_player_added then manager:on_player_added(player) end
    end
end

local function handleAdded(env, player)
    local leaving = env.leaving[player.UserId]
    if leaving then
        leaving.Waiting = player
        player:SetAttribute('SaveState', 'pending')
        return
    end
    env.online_players[player.UserId] = player
    env.current[player.UserId] = player
    env.managers.PlayerData:on_player_added(player)
end

local function continueRemoving(env, player, leaving)
    if env.leaving[player.UserId] ~= leaving or leaving.cleaned then return end
    leaving.cleaned = true
    local active = env.active[player.UserId] == player
    if active then env.active[player.UserId] = nil end
    if active then env.lifeHost:remove(player) end
    env.managers.PlayerData:on_player_removing(player)
    if active then
        for _, name in ipairs(LEAVING_REST) do
            local manager = env.managers[name]
            if manager.on_player_removing then manager:on_player_removing(player) end
        end
    end
    env.managers.Save:after_idle(player.UserId, function()
        if env.leaving[player.UserId] ~= leaving then return end
        env.leaving[player.UserId], env.current[player.UserId] = nil, nil
        env.online_players[player.UserId] = nil
        if leaving.Waiting then handleAdded(env, leaving.Waiting) end
    end)
end

local function handleRemoving(env, player)
    local leaving = env.leaving[player.UserId]
    if leaving then
        if leaving.Waiting == player then leaving.Waiting = nil end
        return
    end
    if env.current[player.UserId] ~= player then return end
    leaving = {}
    env.leaving[player.UserId] = leaving
    local queued = env.ready[player.UserId]
    if queued and queued[1] == player then env.ready[player.UserId] = nil end
    continueRemoving(env, player, leaving)
end

--- 一条虚拟连接加入：userId 是连接身份，position/name 只服务场景相关判定。
--- 就绪前返回 nil；用 join 表示「等到读档就绪」，join_raw 表示「只是发出加入」。
function M:join_raw(userId, opts)
    opts = opts or {}
    local player = self:player(userId, opts.position, opts.name)
    handleAdded(self, player)
    return player
end

function M:join(userId, opts)
    local player = self:join_raw(userId, opts)
    for _ = 1, 20 do
        self:tick()
        if self.managers.PlayerData:get_data_inst(player) then return player end
        self:advance(0.05)
    end
    error('连接 ' .. tostring(userId) .. ' 未在 20 轮内就绪')
end

--- 一条虚拟连接离开；返回 true 表示按在线玩家清理，false 表示重复 / 迟到回调被忽略。
function M:leave(player)
    if self.current[player.UserId] ~= player then handleRemoving(self, player) return false end
    handleRemoving(self, player)
    for _ = 1, 20 do
        self:tick()
        if not self.leaving[player.UserId] then break end
        self:advance(0.05)
    end
    return true
end

--- 只发出离场，不推进任何 Task：给「离场未结算时重连」这类跨连接时序用。
--- 调用方自己用 Tick/advance 决定何时结算（真实断线就是离场与结算之间还有空档）。
function M:leave_raw(player)
    handleRemoving(self, player)
    return self
end

--- 等到这条连接真正离场结算完（after_idle 回调跑完）。
function M:wait_leave(userId)
    for _ = 1, 20 do
        self:tick()
        if not self.leaving[userId] then return true end
        self:advance(0.05)
    end
    return false
end

function M:online(player)
    return player ~= nil and self.active[player.UserId] == player
end

function M:Count()
    local count = 0
    for _, player in pairs(self.online_players) do
        if self.active[player.UserId] == player then count = count + 1 end
    end
    return count
end

-- ===== 业务入口（与客户端同一条通道）=====

function M:request(name, player, payload)
    self.re[name].OnServerEvent:Fire(player, payload)
    return self:tick()
end

function M:Party(player, payload) return self:request('PartyAction', player, payload) end

function M:Interact(player, payload) return self:request('InteractAction', player, payload) end

function M:reply(name)
    local list = self.sent[name] or {}
    return list[#list]
end

--- 统一伤害入口：与武器 / 鱼攻击走同一个 apply_hit。
function M:hit(source, target, category, amount)
    local vitals = self.managers.Vitals
    return vitals:apply_hit(vitals:new_hit(source, category), target, amount)
end

--- 共享地面实例：不经过库存，直接在世界里落一份（盲盒溢出、丢弃补偿同一入口）。
function M:Loot(itemId, position, mult)
    local world = self.lifeHost and self.lifeHost.runtime:get_world()
    if not world then return nil end
    local ok = world:place_ground_item('fishPond', {
        kind = 'item', itemId = itemId, count = 1, mult = mult or 1,
        x = position.x, y = position.y or 0, z = position.z,
    })
    if not ok then return nil end
    local row = world:ground_snapshot().list[#world:ground_snapshot().list]
    if row then row.Id = row.id end
    return row
end

function M:loot_snapshot()
    local world = self.lifeHost and self.lifeHost.runtime:get_world()
    return world and world:ground_snapshot().list or {}
end

function M:pickup(player, lootId)
    local world = self.lifeHost and self.lifeHost.runtime:get_world()
    if not world then return false end
    local ok = world:try_pickup(player, lootId)
    return ok == true
end

--- 存档快照：MgrSave 的键与值，读档就绪后可核对「服务端没丢状态」。
function M:stored(userId) return self.values[self.managers.Save:key(userId)] end

function M:data(player) return self.managers.PlayerData:get_data_inst(player) end

function M:Save(player)
    local data = self:data(player)
    local ok = self.managers.Save:Save(player.UserId, data:Serialize(), 'test')
    self:tick()
    return ok
end

function M:phase(player) return self.managers.Survival:phase(player) end

-- ===== 拆除 =====

function M:close()
    local saved = self.saved
    _G.game, _G.Vector3, _G.Vector2 = saved.game, saved.Vector3, saved.Vector2
    _G.Color, _G.REUtil, _G.task = saved.Color, saved.REUtil, saved.task
    package.loaded['common.re_util'] = saved.reutil
    package.loaded['server.data.player_data'] = saved.playerdata
    package.loaded['server.world_host.fish_carrier'] = saved.carrier
    self.saved, self.queue, self.re, self.sent = nil, {}, {}, {}
    return self
end

--- 一案例一套夹具：new + Start，返回 link；用完 close。
function M.open(opts)
    local link = M.new(opts)
    link:start()
    return link
end

return M
