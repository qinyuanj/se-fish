
local Number = require('common.number')

local RateLimit = {}

RateLimit.Result = { Ok = "ok", dropped = "dropped" }
RateLimit.Reason = {
    bad_payload = "bad-payload",
    session = "session",
    order = "order",
}

RateLimit.PAYLOAD_FIELDS = { "s", "n", "q" }

-- NaN 会毒化 UsedCount/remaining 并让比较恒为 false，必须显式拒绝。
local isFiniteNumber = Number.is_finite_number

local function checkSessionId(sessionId, where)
    if type(sessionId) ~= "string" or sessionId == "" then
        error(where .. ": 会话 id 必须是非空字符串")
    end
end


local Window = {}
Window.__index = Window

function RateLimit.new_window(windowSec, maxCount)
    if not isFiniteNumber(windowSec) or windowSec <= 0 then
        error("RateLimit.NewWindow: WindowSec 必须是正数")
    end
    if not isFiniteNumber(maxCount) or maxCount < 1 then
        error("RateLimit.NewWindow: MaxCount 必须是 ≥1 的数")
    end

    return setmetatable({
        WindowSec = windowSec,
        MaxCount = math.floor(maxCount),
        bursts = {},
        first = 1,
        Last = 0,
        used_count = 0,
    }, Window)
end

function Window:trim(now)
    local deadline = now - self.WindowSec
    while self.first <= self.Last and self.bursts[self.first].Time <= deadline do
        self.used_count = self.used_count - self.bursts[self.first].Count
        self.bursts[self.first] = nil
        self.first = self.first + 1
    end
end

function Window:used(now)
    self:trim(now)
    return self.used_count
end

function Window:remaining(now)
    return self.MaxCount - self:used(now)
end

function Window:admit(now, count)
    if not isFiniteNumber(count) or count < 1 then
        return 0
    end

    self:trim(now)
    local accepted = math.min(math.floor(count), self.MaxCount - self.used_count)
    if accepted <= 0 then
        return 0
    end

    self.Last = self.Last + 1
    self.bursts[self.Last] = { Time = now, Count = accepted }
    self.used_count = self.used_count + accepted
    return accepted
end

function Window:reset()
    self.bursts = {}
    self.first = 1
    self.Last = 0
    self.used_count = 0
end


local Aggregator = {}
Aggregator.__index = Aggregator

function RateLimit.new_aggregator(opts)
    opts = opts or {}
    checkSessionId(opts.SessionId, "RateLimit.NewAggregator")
    if not isFiniteNumber(opts.AggregateSec) or opts.AggregateSec <= 0 then
        error("RateLimit.NewAggregator: AggregateSec 必须是正数")
    end

    return setmetatable({
        SessionId = opts.SessionId,
        AggregateSec = opts.AggregateSec,
        Pending = 0,
        window_start = nil,
        seq = 0,
    }, Aggregator)
end

function Aggregator:set_session(sessionId)
    checkSessionId(sessionId, "RateLimit.Aggregator:SetSession")
    self.SessionId = sessionId
    self.Pending = 0
    self.window_start = nil
    self.seq = 0
end

function Aggregator:click(now)
    if self.Pending == 0 then
        self.window_start = now
    end
    self.Pending = self.Pending + 1
end

function Aggregator:collect(now)
    if self.Pending == 0 or now - self.window_start < self.AggregateSec then
        return nil
    end

    return self:flush()
end

function Aggregator:flush()
    if self.Pending == 0 then
        return nil
    end

    self.seq = self.seq + 1
    local payload = { s = self.SessionId, n = self.Pending, q = self.seq }
    self.Pending = 0
    self.window_start = nil
    return payload
end

function Aggregator:pending_count()
    return self.Pending
end


local Receiver = {}
Receiver.__index = Receiver

function RateLimit.new_receiver(opts)
    opts = opts or {}
    return setmetatable({
        SessionId = opts.SessionId,
        window = RateLimit.new_window(opts.WindowSec, opts.MaxCount),
        LastSeq = nil,
    }, Receiver)
end

function Receiver:set_session(sessionId)
    checkSessionId(sessionId, "RateLimit.Receiver:SetSession")
    self.SessionId = sessionId
    self.LastSeq = nil
    self.window:reset()
end

function Receiver:end_session()
    self.SessionId = nil
    self.LastSeq = nil
    self.window:reset()
end

local function drop(reason, seq)
    return { Status = RateLimit.Result.dropped, Reason = reason, seq = seq }
end

function Receiver:accept(now, msg)
    if type(msg) ~= "table" then
        return drop(RateLimit.Reason.bad_payload, nil)
    end

    local n = msg.n
    local q = msg.q
    if type(msg.s) ~= "string" or msg.s == ""
        or not isFiniteNumber(n) or n < 1 or n ~= math.floor(n)
        or not isFiniteNumber(q) or q < 1 or q ~= math.floor(q) then
        return drop(RateLimit.Reason.bad_payload, nil)
    end

    if self.SessionId == nil or msg.s ~= self.SessionId then
        return drop(RateLimit.Reason.session, q)
    end

    if self.LastSeq ~= nil and q <= self.LastSeq then
        return drop(RateLimit.Reason.order, q)
    end

    self.LastSeq = q
    local accepted = self.window:admit(now, n)
    return {
        Status = RateLimit.Result.Ok,
        Requested = math.floor(n),
        accepted = accepted,
        seq = q,
        clamped = accepted < math.floor(n),
    }
end

return RateLimit
