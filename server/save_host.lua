local GameCfg = require('common.game_cfg')
local PlayerData = require('server.data.player_data')
local SaveHost = { SpokeHost = true, ledger = {}, pending = {}, flying = {}, sessions = {}, waiters = {}, next_autosave_at = nil }
local function cfg() return GameCfg.Save end
local function task() return game:GetService('Task') end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end
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
    return self.sessions[userId] == session and session.Data == data and data.Player == session.Player
end
function SaveHost:fail(userId, session, reason)
    if self.sessions[userId] ~= session then return end
    session.State, session.Error = 'failed', reason
    if session.Data then
        session.Data.load_state, session.Data.inited = 'failed', false
        if session.Data.Player then session.Data.Player:SetAttribute('SaveState', 'failed') end
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
function SaveHost:get_store()
    if self.store_checked then return self.Store end
    self.store_checked = true
    local ok, store = pcall(function() return game:GetService('DataStoreService'):GetDataStore(cfg().Store) end)
    if not ok or not store then
        print('[SaveHost] DataStore 不可用，保持读档失败屏障', tostring(store))
        return nil
    end
    self.Store = store
    return store
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
    local store = self:get_store()
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
    ledger.LastReason, ledger.revision = reason, snapshot.meta.revision
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

function SaveHost:load_into(player, data)
    local userId = player.UserId
    local previous = self:session(userId)
    if previous.Data and previous.Data ~= data then
        previous.Data.inited, previous.Data.load_state = false, 'stale'
    end
    self.counter = (self.counter or 0) + 1
    local s = { current = self.QaSlot, next = self.QaSlot, paused = false,
        State = 'pending', Player = player, Data = data,
        token = tostring(userId) .. ':' .. tostring(self.counter) .. ':' .. tostring({}) .. ':' .. tostring(math.random()) }
    self.sessions[userId] = s
    data.inited, data.load_state = false, 'pending'
    player:SetAttribute('SaveState', 'pending')
    local function load()
        task():Spawn(function()
            if not self:is_current(userId, s, data) then return end
            local store = self:get_store()
            if not store then self:fail(userId, s, '存档服务不可用') return end
            local okSlot, slot = self:with_retry('读取槽选择 ' .. userId, function()
                return store:GetAsync(cfg().KeyPrefix .. userId .. ':gm-slot')
            end)
            if not self:is_current(userId, s, data) then return end
            if not okSlot or slot ~= nil and slot ~= '' and not validSlot(slot) then
                self:fail(userId, s, '槽选择读取失败或损坏') return
            end
            if slot ~= nil then s.current, s.next = slot, slot end
            s.Key = self:key(userId)
            local loaded, status = self:load(userId)
            if not self:is_current(userId, s, data) then return end
            if status == 'failed' then self:fail(userId, s, '读取失败，不初始化新档') return end
            local candidate, reason
            if loaded == nil then
                local fresh = PlayerData.new({ UserId = userId, SetAttribute = function() end })
                fresh:Init()
                candidate = fresh:Serialize()
            else
                candidate, reason = data:Migrate(loaded)
            end
            if not candidate then self:fail(userId, s, reason) return end
            if not self:within_budget(candidate) then self:fail(userId, s, '存档容量超预算') return end
            local ok, claimed = self:with_retry('认领会话 ' .. userId, function()
                return store:UpdateAsync(s.Key, function(current)
                    if not self:is_current(userId, s, data) then return nil end
                    if current and current.meta and current.meta.session == s.token then return current end
                    if not equal(current, loaded) then return nil end
                    local nextValue = copy(candidate)
                    nextValue.meta.epoch = nextValue.meta.epoch + 1
                    nextValue.meta.revision = nextValue.meta.revision + 1
                    nextValue.meta.session = s.token
                    return nextValue
                end)
            end)
            if not self:is_current(userId, s, data) then return end
            if not ok or not claimed or claimed.meta.session ~= s.token then
                self:fail(userId, s, '会话认领失败或版本冲突') return
            end
            s.State, s.revision, s.epoch = 'ready', claimed.meta.revision, claimed.meta.epoch
            if not data:CompleteLoad(claimed) then self:fail(userId, s, '恢复数据无效') return end
            self:restore_landing(userId, player, data, s)
            self:note_write(userId, claimed, status == 'missing' and 'new' or 'load')
            player:SetAttribute('SaveState', 'ready')
            print('[SaveHost] ready', userId, s.token, 'coin=' .. claimed.coin, 'sequence=' .. claimed.meta.sequence)
            if self.on_ready then self.on_ready(player, data) end
            if self.player_data then self.player_data:send_item_bar(player, true) end
        end)
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
        return self.Store:UpdateAsync(job.Key, function(current)
            if self.sessions[userId] ~= s then return nil end
            if type(current) ~= 'table' or type(current.meta) ~= 'table'
                or current.meta.session ~= s.token or current.meta.epoch ~= s.epoch then return nil end
            if current.meta.write == job.Id then return current end
            if current.meta.revision ~= job.base_revision then return nil end
            return copy(job.snapshot)
        end)
    end)
    if self.sessions[userId] ~= s then return false, 'stale' end
    if not ok then return false, 'retry' end
    if not value or not value.meta or value.meta.write ~= job.Id then
        self:fail(userId, s, '写入会话或修订冲突')
        return false, 'conflict'
    end
    s.revision = value.meta.revision
    if s.Data and s.Data.Player == s.Player then
        s.Data.save_meta = PlayerData.strip_array_meta(value.meta, 'stored.meta')
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
    if not s or s.State ~= 'ready' or s.paused or s.transition or not self:get_store()
        or not s.Data or not s.Data.inited or not snapshot or not s.Data:IsValidSave(snapshot)
        or not self:within_budget(snapshot) or snapshot.meta.session ~= s.token then return false end
    local job = { session = s, Key = s.Key, snapshot = copy(snapshot), Reason = reason or 'save', done = done,
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
    local requestKey
    if type(requestId) == 'number' and requestId == math.floor(requestId)
        and requestId >= 1 and requestId <= 2147483647 then
        requestKey = s.token .. ':' .. kind .. ':' .. requestId
    elseif type(requestId) == 'table' and type(requestId.requestKey) == 'string'
        and type(requestId.id) == 'string' and type(requestId.sequence) == 'number'
        and requestId.kind == kind then
        requestKey = requestId.requestKey
    else return nil, 'invalid' end
    for _, recorded in ipairs(data.save_meta.operations) do
        if recorded.requestKey == requestKey then
            if type(requestId) == 'table' and (requestId.id ~= recorded.id
                or requestId.sequence ~= recorded.sequence or requestId.kind ~= recorded.kind) then
                return nil, 'identity-conflict'
            end
            return { id = recorded.id, sequence = recorded.sequence, kind = kind,
                requestKey = recorded.requestKey }, 'replay'
        end
    end
    if type(requestId) == 'table' then return nil, 'expired' end
    if self:is_paused(userId) then return nil, 'pending' end
    local operation = self:next_operation(player, kind)
    if not operation then return nil, 'pending' end
    operation.requestKey = requestKey
    return operation, 'new'
end

-- 身份由服务端颁发，调用者必须保留原身份重试；不能把客户端自报 id 当凭证。
function SaveHost:next_operation(player, kind)
    local s = self.sessions[player.UserId]
    if not s or s.Player ~= player or self:is_paused(player.UserId) or not s.Data.inited
        or type(kind) ~= 'string' or #kind < 1 or #kind > 80 then return nil end
    local sequence = s.Data.save_meta.sequence + 1
    return { id = tostring(player.UserId) .. ':' .. sequence, sequence = sequence, kind = kind }
end

-- transform 只改隔离 draft 并返回可序列化结果；外部实体交接由调用方在成功回调按操作身份确认。
-- 扣费、发奖、恢复记录和结果一次落在同键，失败时 draft 不向玩家发布。
function SaveHost:execute(player, data, operation, transform, done)
    local userId, s = player.UserId, self.sessions[player.UserId]
    if not s or not self:is_current(userId, s, data) or s.State ~= 'ready' or not data.inited
        or type(operation) ~= 'table' or type(operation.sequence) ~= 'number'
        or operation.sequence ~= math.floor(operation.sequence) or operation.sequence < 1
        or operation.id ~= tostring(userId) .. ':' .. operation.sequence
        or type(operation.kind) ~= 'string' or #operation.kind < 1 or #operation.kind > 80
        or operation.requestKey ~= nil and type(operation.requestKey) ~= 'string'
        or type(transform) ~= 'function' or type(done) ~= 'function' then return false, 'invalid' end
    local meta = data.save_meta
    for _, recorded in ipairs(meta.operations) do
        if recorded.id == operation.id then
            if recorded.kind ~= operation.kind or operation.requestKey ~= nil
                and recorded.requestKey ~= operation.requestKey then return false, 'identity-conflict' end
            callback('结果重放', userId, done, true, copy(recorded.result))
            return true
        end
    end
    if operation.sequence <= meta.sequence then return false, 'expired' end
    if self:is_paused(userId) then return false, 'pending' end
    if operation.sequence ~= meta.sequence + 1 then return false, 'out-of-order' end
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
        local nextValue = draft:Serialize()
        nextValue.meta.sequence = operation.sequence
        table.insert(nextValue.meta.operations, { id = operation.id, sequence = operation.sequence,
            kind = operation.kind, requestKey = operation.requestKey, result = copy(result) })
        while #nextValue.meta.operations > 64 do
            nextValue.meta.floor = table.remove(nextValue.meta.operations, 1).sequence
        end
        if not data:IsValidSave(nextValue) or not self:within_budget(nextValue) then
            s.transition = false
            callback('结算容量拒绝', userId, done, false, 'invalid-result-or-budget')
            return
        end
        data.inited = false
        local job = { session = s, Key = s.Key, snapshot = nextValue, Reason = operation.kind,
            done = function(written, value)
                if not self:is_current(userId, s, data) then return end
                s.transition = false
                if written then
                    data.inited = true
                    data:ApplySave(value)
                    data:PublishItemBar()
                    print('[SaveHost] operation', userId, operation.id, operation.kind,
                        'coinBefore=' .. snapshot.coin, 'coinAfter=' .. value.coin,
                        'bar=' .. #value.bar, 'bp=' .. #value.bp)
                    callback('结算完成', userId, done, true, copy(result))
                else
                    self:fail(userId, s, '结算未确认 ' .. tostring(value))
                    callback('结算失败', userId, done, false, value)
                end
            end }
        self.pending[userId] = job
        self:drain(userId)
    end)
    return true
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
    local s, store = self:session(userId), self:get_store()
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
    if not s or s.Player ~= player or s.Data ~= data then return end
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
