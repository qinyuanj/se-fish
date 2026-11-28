local DeepCopy = require('common.deep_copy')
local GameCfg = require('common.game_cfg')
local StoreHandle = require('common.store_handle')
local PlayerData = require('server.data.player_data')
---@class SaveHost
---@field SpokeHost boolean
---@field ledger table
---@field pending table
---@field flying table
---@field sessions table
---@field waiters table
---@field next_autosave_at number?
---@field player_data any
---@field QaSlot string?
---@field slot_pinned boolean?
---@field store_checked boolean?
---@field Store any
local SaveHost = { SpokeHost = true, ledger = {}, pending = {}, flying = {}, sessions = {}, waiters = {}, next_autosave_at = nil }
local function cfg() return GameCfg.Save end
-- DataStore 句柄缓存字段与取不到时的说明。字段名沿用既有的 store_checked/Store（save_test 直接复位它们模拟服务缺失）。
local STORE_CACHE = { checked = 'store_checked', store = 'Store' }
local STORE_LOG = '[SaveHost] DataStore 不可用，保持读档失败屏障'
local function task() return game:GetService('Task') end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function callback(label, userId, fn, ...)
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then print('[SaveHost] 回调失败', label, userId, tostring(err)) end
end
local function validSlot(slot)
    return type(slot) == 'string' and #slot >= 1 and #slot <= 40 and slot:match('^[%w_-]+$') ~= nil
end
function SaveHost:key(userId)
    if not self.slot_pinned then
        ---@type string?
        local slot = cfg().QaSlot
        assert(slot == nil or slot == '' or validSlot(slot), 'QA 存档槽须为 1—40 位字母、数字、下划线或连字符')
        self.QaSlot, self.slot_pinned = slot or '', true
    end
    local session = self.sessions[userId]
    local slot = session and session.current or self.QaSlot
    return cfg().KeyPrefix .. tostring(userId) .. (slot ~= '' and ':qa:' .. slot or '')
end
function SaveHost:session(userId)
    self:key(userId)
    if not self.sessions[userId] then
        self.sessions[userId] = { current = self.QaSlot, next = self.QaSlot, paused = false }
    end
    return self.sessions[userId]
end
function SaveHost:status(userId)
    local s = self:session(userId)
    return { currentSlot = s.current, nextSlot = s.next, autosavePaused = s.paused,
        loadState = s.State or 'pending', error = s.Error, revision = s.revision, epoch = s.epoch }
end
function SaveHost:is_paused(userId)
    local s = self.sessions[userId]
    return not s or s.State ~= 'ready' or s.paused or s.transition or false
end
function SaveHost:is_current(userId, session, data)
    return self.sessions[userId] == session and session.data == data and data.Player == session.Player
end
function SaveHost:fail(userId, session, reason)
    if self.sessions[userId] ~= session then return end
    session.State, session.Error = 'failed', reason
    if session.data then
        session.data.load_state, session.data.inited = 'failed', false
        if session.data.Player then session.data.Player:SetAttribute('SaveState', 'failed') end
    end
    print('[SaveHost] 读写屏障关闭', userId, tostring(session.token), reason)
end
function SaveHost:after_idle(userId, fn)
    if not self.flying[userId] and not self.pending[userId] then callback('AfterIdle', userId, fn) return end
    self.waiters[userId] = self.waiters[userId] or {}
    table.insert(self.waiters[userId], fn)
end
function SaveHost:finish_save(userId)
    self.flying[userId] = nil
    if self.pending[userId] then
        if self.pending[userId].retry_rounds then return end
        self:drain(userId)
        return
    end
    local callbacks = self.waiters[userId] or {}
    self.waiters[userId] = nil
    for _, fn in ipairs(callbacks) do callback('AfterIdle', userId, fn) end
end
function SaveHost:with_retry(label, fn)
    for attempt = 1, cfg().MaxRetries do
        local ok, value = pcall(fn)
        if ok then return true, value end
        print('[SaveHost]', label, '失败', attempt, tostring(value))
        if attempt < cfg().MaxRetries then task():Wait(cfg().RetryDelaySec) end
    end
    return false, nil
end
function SaveHost:load(userId)
    local store = StoreHandle.get(self, STORE_CACHE, cfg().Store, STORE_LOG)
    if not store then return nil, 'failed' end
    local key = self:key(userId)
    local ok, value = self:with_retry('读档 ' .. tostring(userId), function() return store:GetAsync(key) end)
    if not ok then return nil, 'failed' end
    return value, value == nil and 'missing' or 'found'
end
function SaveHost:estimate_size(value)
    if type(value) == 'string' then return #value end
    if type(value) == 'number' then return 8 end
    if type(value) ~= 'table' then return 1 end
    local total = 2
    for k, v in pairs(value) do total = total + self:estimate_size(k) + self:estimate_size(v) + 2 end
    return total
end
function SaveHost:within_budget(snapshot)
    return self:estimate_size(snapshot) <= 256 * 1024
end
function SaveHost:note_write(userId, snapshot, reason)
    local ledger = self.ledger[userId] or { writes = 0 }
    ledger.writes, ledger.bytes = ledger.writes + 1, self:estimate_size(snapshot)
    ledger.last_reason, ledger.revision = reason, snapshot.meta.revision
    ledger.operation_count = #snapshot.meta.operations
    self.ledger[userId] = ledger
    print('[SaveHost] 落账', userId, reason, 'revision=' .. ledger.revision,
        'bytes=' .. ledger.bytes, 'writes=' .. ledger.writes, 'ops=' .. ledger.operation_count)
end

function SaveHost:restore_landing(userId, player, data, session)
    if not self:is_current(userId, session, data) then return end
    local point, corrected = data:ResolveSafePoint()
    if not corrected or not point then return end
    local function teleport(character)
        local ok, err = pcall(function()
            local pos = Vector3.New(point.x, point.y, point.z)
            if character.SetPosition then character:SetPosition(pos) else character.Position = pos end
        end)
        if not ok then print('[SaveHost] 安全落点恢复失败', userId, tostring(err)) end
    end
    if player.Character then teleport(player.Character) return end
    if not player.CharacterAdded then return end
    local connection
    connection = player.CharacterAdded:Connect(function(character)
        if self.sessions[userId] ~= session then connection:Disconnect() return end
        teleport(character)
        connection:Disconnect()
    end)
end

-- 读槽选择并写入会话：失败时已 fail 并返回 nil。
local function prepare_session_store(self, userId, s, data)
    local store = StoreHandle.get(self, STORE_CACHE, cfg().Store, STORE_LOG)
    if not store then self:fail(userId, s, '存档服务不可用') return nil end
    local ok_slot, slot = self:with_retry('读取槽选择 ' .. userId, function()
        return store:GetAsync(cfg().KeyPrefix .. userId .. ':gm-slot')
    end)
    if not self:is_current(userId, s, data) then return nil end
    if not ok_slot or slot ~= nil and slot ~= '' and not validSlot(slot) then
        self:fail(userId, s, '槽选择读取失败或损坏') return nil
    end
    if slot ~= nil then s.current, s.next = slot, slot end
    s.Key = self:key(userId)
    return store
end

-- 无存档时造新档，有存档时迁移；失败已 fail 并返回 nil。
local function resolve_candidate(self, userId, s, data, loaded)
    local candidate, reason
    if loaded == nil then
        local fresh = PlayerData.new({ UserId = userId, SetAttribute = function() end })
        fresh:Init()
        candidate = fresh:Serialize()
    else
        candidate, reason = data:Migrate(loaded)
    end
    if not candidate then self:fail(userId, s, reason) return nil end
    if not self:within_budget(candidate) then self:fail(userId, s, '存档容量超预算') return nil end
    return candidate
end

-- 在 store 上认领会话（CAS）；失败已 fail 并返回 nil。
local function claim_session(self, userId, s, data, store, candidate, loaded)
    local ok, claimed = self:with_retry('认领会话 ' .. userId, function()
        return store:UpdateAsync(s.Key, function(current)
            if not self:is_current(userId, s, data) then return nil end
            if current and current.meta and current.meta.session == s.token then return current end
            if not equal(current, loaded) then return nil end
            local next_value = DeepCopy.copy(candidate)
            next_value.meta.epoch = next_value.meta.epoch + 1
            next_value.meta.revision = next_value.meta.revision + 1
            next_value.meta.session = s.token
            return next_value
        end)
    end)
    if not self:is_current(userId, s, data) then return nil end
    if not ok or not claimed or claimed.meta.session ~= s.token then
        self:fail(userId, s, '会话认领失败或版本冲突') return nil
    end
    return claimed
end

-- 收尾：写回会话状态、恢复落点、记一笔写入账并通知就绪。
local function finish_load(self, userId, player, data, s, claimed, status)
    s.State, s.revision, s.epoch = 'ready', claimed.meta.revision, claimed.meta.epoch
    if not data:CompleteLoad(claimed) then self:fail(userId, s, '恢复数据无效') return end
    self:restore_landing(userId, player, data, s)
    self:note_write(userId, claimed, status == 'missing' and 'new' or 'load')
    player:SetAttribute('SaveState', 'ready')
    print('[SaveHost] ready', userId, s.token, 'coin=' .. claimed.coin, 'sequence=' .. claimed.meta.sequence)
    if self.on_ready then self.on_ready(player, data) end
    if self.player_data then self.player_data:send_item_bar(player, true) end
end

-- 一次读档的完整流程：取 store、读槽、造档/迁移、认领会话、收尾。
local function run_load(self, userId, player, data, s)
    if not self:is_current(userId, s, data) then return end
    local store = prepare_session_store(self, userId, s, data)
    if not store then return end
    local loaded, status = self:load(userId)
    if not self:is_current(userId, s, data) then return end
    if status == 'failed' then self:fail(userId, s, '读取失败，不初始化新档') return end
    local candidate = resolve_candidate(self, userId, s, data, loaded)
    if not candidate then return end
    local claimed = claim_session(self, userId, s, data, store, candidate, loaded)
    if not claimed then return end
    finish_load(self, userId, player, data, s, claimed, status)
end

function SaveHost:load_into(player, data)
    local userId = player.UserId
    local previous = self:session(userId)
    if previous.data and previous.data ~= data then
        previous.data.inited, previous.data.load_state = false, 'stale'
    end
    self.counter = (self.counter or 0) + 1
    local s = { current = self.QaSlot, next = self.QaSlot, paused = false,
        State = 'pending', Player = player, data = data,
        token = tostring(userId) .. ':' .. tostring(self.counter) .. ':' .. tostring({}) .. ':' .. tostring(math.random()) }
    self.sessions[userId] = s
    data.inited, data.load_state = false, 'pending'
    player:SetAttribute('SaveState', 'pending')
    local function load()
        task():Spawn(function() run_load(self, userId, player, data, s) end)
    end
    if previous.slot_choosing then
        previous.slot_waiters = previous.slot_waiters or {}
        table.insert(previous.slot_waiters, load)
    else load() end
end

function SaveHost:write_job(userId, job)
    local s = job.session
    if self.sessions[userId] ~= s then return false, 'stale' end
    if not job.base_revision then
        job.base_revision = s.revision
        job.snapshot.meta.revision = s.revision + 1
        job.snapshot.meta.epoch, job.snapshot.meta.session = s.epoch, s.token
        s.write_sequence = (s.write_sequence or 0) + 1
        job.Id = s.token .. ':write:' .. s.write_sequence
        job.snapshot.meta.write = job.Id
    end
    local ok, value = self:with_retry('写档 ' .. userId .. ' ' .. job.Reason, function()
        return StoreHandle.get(self, STORE_CACHE, cfg().Store, STORE_LOG):UpdateAsync(job.Key, function(current)
            if self.sessions[userId] ~= s then return nil end
            if type(current) ~= 'table' or type(current.meta) ~= 'table'
                or current.meta.session ~= s.token or current.meta.epoch ~= s.epoch then return nil end
            if current.meta.write == job.Id then return current end
            if current.meta.revision ~= job.base_revision then return nil end
            return DeepCopy.copy(job.snapshot)
        end)
    end)
    if self.sessions[userId] ~= s then return false, 'stale' end
    if not ok then return false, 'retry' end
    if not value or not value.meta or value.meta.write ~= job.Id then
        self:fail(userId, s, '写入会话或修订冲突')
        return false, 'conflict'
    end
    s.revision = value.meta.revision
    if s.data and s.data.Player == s.Player then
        s.data.save_meta = PlayerData.strip_array_meta(value.meta, 'stored.meta')
    end
    self:note_write(userId, value, job.Reason)
    return true, value
end
local function appendJob(current, job)
    if not current then return job end
    if not current.base_revision and not current.done and not current.after then return job end
    local last = current
    while last.after do last = last.after end
    last.after = job
    return current
end
function SaveHost:drain(userId)
    if self.flying[userId] then return end
    self.flying[userId] = true
    task():Spawn(function()
        while self.pending[userId] do
            local job = self.pending[userId]
            self.pending[userId] = nil
            local ok, result = self:write_job(userId, job)
            if not ok and result == 'retry' and not job.no_retry then
                job.retry_rounds = (job.retry_rounds or 0) + 1
                if job.retry_rounds <= 3 then
                    if self.pending[userId] then job.after = appendJob(job.after, self.pending[userId]) end
                    self.pending[userId] = job
                    break
                end
                print('[SaveHost] 写档重试耗尽，关闭会话', userId, job.Reason)
                self:fail(userId, job.session, '写档重试耗尽')
            end
            callback('写入结果', userId, job.done, ok, result)
            if not ok and result == 'retry' and job.session.State == 'failed' then
                local current = job.after
                while current do
                    callback('后续写入取消', userId, current.done, false, '写档失败')
                    current = current.after
                end
                self.pending[userId] = nil
                break
            end
            if job.after then self.pending[userId] = appendJob(job.after, self.pending[userId]) end
        end
        self:finish_save(userId)
    end)
end
function SaveHost:enqueue(userId, snapshot, reason, done)
    local s = self.sessions[userId]
    if not s or s.State ~= 'ready' or s.paused or s.transition or not StoreHandle.get(self, STORE_CACHE, cfg().Store, STORE_LOG)
        or not s.data or not s.data.inited or not snapshot or not s.data:IsValidSave(snapshot)
        or not self:within_budget(snapshot) or snapshot.meta.session ~= s.token then return false end
    local job = { session = s, Key = s.Key, snapshot = DeepCopy.copy(snapshot), Reason = reason or 'save', done = done,
        no_retry = reason == 'gm' }
    self.pending[userId] = appendJob(self.pending[userId], job)
    self:drain(userId)
    return true
end
function SaveHost:Save(userId, snapshot, reason) return self:enqueue(userId, snapshot, reason) end
function SaveHost:commit(userId, snapshot, reason) return self:enqueue(userId, snapshot, reason) end

function SaveHost:resolve_request(player, data, kind, requestId)
    local userId = player and player.UserId
    local s = userId and self.sessions[userId]
    if not s or not self:is_current(userId, s, data) or s.State ~= 'ready'
        or type(kind) ~= 'string' or #kind < 1 or #kind > 80 then return nil, 'invalid' end
    local request_key
    if type(requestId) == 'number' and requestId == math.floor(requestId)
        and requestId >= 1 and requestId <= 2147483647 then
        request_key = s.token .. ':' .. kind .. ':' .. requestId
    elseif type(requestId) == 'table' and type(requestId.request_key) == 'string'
        and type(requestId.id) == 'string' and type(requestId.sequence) == 'number'
        and requestId.kind == kind then
        request_key = requestId.request_key
    else return nil, 'invalid' end
    for _, recorded in ipairs(data.save_meta.operations) do
        if recorded.request_key == request_key then
            if type(requestId) == 'table' and (requestId.id ~= recorded.id
                or requestId.sequence ~= recorded.sequence or requestId.kind ~= recorded.kind) then
                return nil, 'identity-conflict'
            end
            return { id = recorded.id, sequence = recorded.sequence, kind = kind,
                request_key = recorded.request_key }, 'replay'
        end
    end
    if type(requestId) == 'table' then return nil, 'expired' end
    if self:is_paused(userId) then return nil, 'pending' end
    local operation = self:next_operation(player, kind)
    if not operation then return nil, 'pending' end
    operation.request_key = request_key
    return operation, 'new'
end

-- 身份由服务端颁发，调用者必须保留原身份重试；不能把客户端自报 id 当凭证。
function SaveHost:next_operation(player, kind)
    local s = self.sessions[player.UserId]
    if not s or s.Player ~= player or self:is_paused(player.UserId) or not s.data.inited
        or type(kind) ~= 'string' or #kind < 1 or #kind > 80 then return nil end
    local sequence = s.data.save_meta.sequence + 1
    return { id = tostring(player.UserId) .. ':' .. sequence, sequence = sequence, kind = kind }
end

-- transform 只改隔离 draft 并返回可序列化结果；外部实体交接由调用方在成功回调按操作身份确认。
-- 扣费、发奖、恢复记录和结果一次落在同键，失败时 draft 不向玩家发布。
-- 操作身份校验：会话、数据、序号、id 与回调都必须齐备且自洽。
local function valid_operation(self, userId, s, data, operation, transform, done)
    if not s or not self:is_current(userId, s, data) or s.State ~= 'ready' or not data.inited
        or type(operation) ~= 'table' or type(operation.sequence) ~= 'number'
        or operation.sequence ~= math.floor(operation.sequence) or operation.sequence < 1
        or operation.id ~= tostring(userId) .. ':' .. operation.sequence
        or type(operation.kind) ~= 'string' or #operation.kind < 1 or #operation.kind > 80
        or operation.request_key ~= nil and type(operation.request_key) ~= 'string'
        or type(transform) ~= 'function' or type(done) ~= 'function' then return false end
    return true
end

-- 已记录的同 id 操作：身份一致就回放结果，不一致返回 'identity-conflict'。
-- 返回 false 表示这一 id 还没记录过，继续走新结算。
local function replay_recorded(userId, data, operation, done)
    for _, recorded in ipairs(data.save_meta.operations) do
        if recorded.id == operation.id then
            if recorded.kind ~= operation.kind or operation.request_key ~= nil
                and recorded.request_key ~= operation.request_key then
                return 'identity-conflict'
            end
            callback('结果重放', userId, done, true, DeepCopy.copy(recorded.result))
            return 'replayed'
        end
    end
    return false
end

-- 序号单调性、暂停与乱序三道闸；放行返回 nil，否则返回拒绝原因。
local function sequence_gate(self, userId, data, operation)
    local meta = data.save_meta
    if operation.sequence <= meta.sequence then return 'expired' end
    if self:is_paused(userId) then return 'pending' end
    if operation.sequence ~= meta.sequence + 1 then return 'out-of-order' end
    return nil
end

-- 把本次结果并进 draft 序列化：写序号、追加操作记录并按 64 条裁剪。
local function build_next_value(draft, operation, result)
    local next_value = draft:Serialize()
    next_value.meta.sequence = operation.sequence
    table.insert(next_value.meta.operations, { id = operation.id, sequence = operation.sequence,
        kind = operation.kind, request_key = operation.request_key, result = DeepCopy.copy(result) })
    while #next_value.meta.operations > 64 do
        next_value.meta.floor = table.remove(next_value.meta.operations, 1).sequence
    end
    return next_value
end

-- 写档完成回调：成功发布 draft 并回结果，失败记 fail 并回失败原因。
local function settle_job(self, userId, data, s, operation, snapshot, result, done, written, value)
    if not self:is_current(userId, s, data) then return end
    s.transition = false
    if not written then
        self:fail(userId, s, '结算未确认 ' .. tostring(value))
        callback('结算失败', userId, done, false, value)
        return
    end
    data.inited = true
    data:ApplySave(value)
    data:PublishItemBar()
    print('[SaveHost] operation', userId, operation.id, operation.kind,
        'coinBefore=' .. snapshot.coin, 'coinAfter=' .. value.coin,
        'bar=' .. #value.bar, 'bp=' .. #value.bp)
    callback('结算完成', userId, done, true, DeepCopy.copy(result))
end

-- 在隔离 draft 上跑 transform 再落库：draft 不向玩家发布，只有写成功才 ApplySave。
local function run_transition(self, userId, data, s, operation, transform, done)
    s.transition = true
    self:after_idle(userId, function()
        if not self:is_current(userId, s, data) then return end
        local snapshot = data:Serialize()
        local draft = PlayerData.new({ UserId = userId, SetAttribute = function() end })
        draft:Init()
        draft:ApplySave(snapshot)
        local ok, result, reason = pcall(transform, draft)
        if not ok or type(result) ~= 'table' then
            s.transition = false
            print('[SaveHost] 结算拒绝', userId, operation.id, operation.kind, tostring(result), tostring(reason))
            callback('结算拒绝', userId, done, false, ok and reason or tostring(result))
            return
        end
        local next_value = build_next_value(draft, operation, result)
        if not data:IsValidSave(next_value) or not self:within_budget(next_value) then
            s.transition = false
            callback('结算容量拒绝', userId, done, false, 'invalid-result-or-budget')
            return
        end
        data.inited = false
        self.pending[userId] = { session = s, Key = s.Key, snapshot = next_value, Reason = operation.kind,
            done = function(written, value)
                settle_job(self, userId, data, s, operation, snapshot, result, done, written, value)
            end }
        self:drain(userId)
    end)
    return true
end

function SaveHost:execute(player, data, operation, transform, done)
    local userId, s = player.UserId, self.sessions[player.UserId]
    if not valid_operation(self, userId, s, data, operation, transform, done) then return false, 'invalid' end
    local replay = replay_recorded(userId, data, operation, done)
    if replay == 'identity-conflict' then return false, 'identity-conflict' end
    if replay == 'replayed' then return true end
    local rejection = sequence_gate(self, userId, data, operation)
    if rejection then return false, rejection end
    return run_transition(self, userId, data, s, operation, transform, done)
end

function SaveHost:apply_temporary(userId, data, patch, done)
    local s = self:session(userId)
    if s.transition or s.State ~= 'ready' or not self:is_current(userId, s, data) then
        return false, '存档尚未就绪'
    end
    s.transition = true
    local accepted, failure = true, nil
    self:after_idle(userId, function()
        if not self:is_current(userId, s, data) then return end
        local ok, reason = data:ApplyGMPatch(patch)
        accepted, failure = ok, reason
        if ok then s.paused = true end
        s.transition = false
        callback('GM 临时状态', userId, done, ok, reason)
    end)
    return accepted, failure
end
function SaveHost:save_explicit(userId, data, done)
    local s = self:session(userId)
    if s.transition or s.State ~= 'ready' or not self:is_current(userId, s, data) then return false, '存档尚未就绪' end
    s.transition = true
    self:after_idle(userId, function()
        if not self:is_current(userId, s, data) then return end
        local snapshot = data:Serialize()
        s.transition, s.paused = false, false
        local accepted = self:enqueue(userId, snapshot, 'gm', function(ok, result)
            if not self:is_current(userId, s, data) then return end
            s.paused = not ok
            callback('GM 保存', userId, done, ok, ok and nil or result)
        end)
        if not accepted then
            s.paused = true
            callback('GM 保存拒绝', userId, done, false, '存档写入未受理')
        end
    end)
    return true
end
function SaveHost:read_explicit(userId, data, done)
    local s = self:session(userId)
    if s.transition or s.State ~= 'ready' or not self:is_current(userId, s, data) then return false, '存档尚未就绪' end
    s.transition = true
    self:after_idle(userId, function()
        task():Spawn(function()
            if not self:is_current(userId, s, data) then return end
            local revision = data.revision
            local value, status = self:load(userId)
            if not self:is_current(userId, s, data) then return end
            local valid = status == 'found' and data.revision == revision and data:IsValidSave(value)
                and value.meta and value.meta.session == s.token and value.meta.revision == s.revision
            if valid then data:ApplySave(value) end
            s.transition = false
            callback('GM 读取', userId, done, valid or false,
                not valid and '读取失败、状态已变化或存档无效' or nil)
        end)
    end)
    return true
end
function SaveHost:select_next_slot(userId, slot, done)
    if slot ~= '' and not validSlot(slot) then return false, '存档槽须为 1—40 位字母、数字、下划线或连字符' end
    local s, store = self:session(userId), StoreHandle.get(self, STORE_CACHE, cfg().Store, STORE_LOG)
    if s.slot_choosing or not store then return false, '槽选择进行中或服务不可用' end
    s.slot_choosing = true
    task():Spawn(function()
        local ok = self:with_retry('选择槽 ' .. userId, function()
            store:SetAsync(cfg().KeyPrefix .. userId .. ':gm-slot', slot)
        end)
        if ok and self.sessions[userId] == s then s.next = slot end
        s.slot_choosing = false
        local waiters = s.slot_waiters or {}
        s.slot_waiters = nil
        for _, fn in ipairs(waiters) do callback('槽选择', userId, fn) end
        if self.sessions[userId] == s then callback('槽选择结果', userId, done, ok,
            not ok and '存档槽选择未保存' or nil) end
    end)
    return true
end
function SaveHost:release_session(userId, player)
    local s = self.sessions[userId]
    if not s or player and s.Player ~= player then return end
    s.leaving = true
    self:after_idle(userId, function() if self.sessions[userId] == s then self.sessions[userId] = nil end end)
end
function SaveHost:save_leaving(player, data)
    local s = self.sessions[player.UserId]
    if not s or s.Player ~= player or s.data ~= data then return end
    if data and data.inited then self:Save(player.UserId, data:Serialize(), 'leave') end
end
function SaveHost:update()
    for userId in pairs(self.pending) do self:drain(userId) end
    local now = game:GetService('World'):GetServerTime()
    local interval = cfg().AutosaveSec
    if not interval or interval <= 0 then return end
    if not self.next_autosave_at then self.next_autosave_at = now + interval return end
    if now < self.next_autosave_at then return end
    self.next_autosave_at = now + interval
    if self.player_data then
        for _, player in ipairs(game:GetService('Players'):GetPlayers()) do
            local data = self.player_data:get_data_inst(player)
            if data then self:Save(player.UserId, data:Serialize(), 'autosave') end
        end
    end
end
function SaveHost:start()
    local ok, err = pcall(function()
        game:BindToClose(function()
            if self.player_data then
                for _, player in ipairs(game:GetService('Players'):GetPlayers()) do
                    local data = self.player_data:get_data_inst(player)
                    if data then self:Save(player.UserId, data:Serialize(), 'shutdown') end
                end
            end
            for _ = 1, 25 do
                if next(self.pending) == nil and next(self.flying) == nil then return end
                for userId in pairs(self.pending) do self:drain(userId) end
                task():Wait(1)
            end
            print('[SaveHost] 关服刷新未排空，请核对台账')
        end)
    end)
    if not ok then print('[SaveHost] BindToClose 绑定失败', tostring(err)) end
end
return SaveHost
