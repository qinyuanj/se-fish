
local number = require('common.number')

local rate_limit = {}

rate_limit.Result = { Ok = "ok", Dropped = "dropped" }
rate_limit.Reason = {
    BadPayload = "bad-payload",
    Session = "session",
    Order = "order",
}

rate_limit.PAYLOAD_FIELDS = { "s", "n", "q" }

-- NaN 会毒化 UsedCount/Remaining 并让比较恒为 false，必须显式拒绝。
local isFiniteNumber = number.IsFiniteNumber

local function checkSessionId(sessionId, where)
    if type(sessionId) ~= "string" or sessionId == "" then
        error(where .. ": 会话 id 必须是非空字符串")
    end
end


local Window = {}
Window.__index = Window

function rate_limit.NewWindow(windowSec, maxCount)
    if not isFiniteNumber(windowSec) or windowSec <= 0 then
        error("rate_limit.NewWindow: WindowSec 必须是正数")
    end
    if not isFiniteNumber(maxCount) or maxCount < 1 then
        error("rate_limit.NewWindow: MaxCount 必须是 ≥1 的数")
    end

    return setmetatable({
        WindowSec = windowSec,
        MaxCount = math.floor(maxCount),
        Bursts = {},
        First = 1,
        Last = 0,
        UsedCount = 0,
    }, Window)
end

function Window:Trim(now)
    local deadline = now - self.WindowSec
    while self.First <= self.Last and self.Bursts[self.First].Time <= deadline do
        self.UsedCount = self.UsedCount - self.Bursts[self.First].Count
        self.Bursts[self.First] = nil
        self.First = self.First + 1
    end
end

function Window:Used(now)
    self:Trim(now)
    return self.UsedCount
end

function Window:Remaining(now)
    return self.MaxCount - self:Used(now)
end

function Window:Admit(now, count)
    if not isFiniteNumber(count) or count < 1 then
        return 0
    end

    self:Trim(now)
    local accepted = math.min(math.floor(count), self.MaxCount - self.UsedCount)
    if accepted <= 0 then
        return 0
    end

    self.Last = self.Last + 1
    self.Bursts[self.Last] = { Time = now, Count = accepted }
    self.UsedCount = self.UsedCount + accepted
    return accepted
end

function Window:Reset()
    self.Bursts = {}
    self.First = 1
    self.Last = 0
    self.UsedCount = 0
end


local Aggregator = {}
Aggregator.__index = Aggregator

function rate_limit.NewAggregator(opts)
    opts = opts or {}
    checkSessionId(opts.SessionId, "rate_limit.NewAggregator")
    if not isFiniteNumber(opts.AggregateSec) or opts.AggregateSec <= 0 then
        error("rate_limit.NewAggregator: AggregateSec 必须是正数")
    end

    return setmetatable({
        SessionId = opts.SessionId,
        AggregateSec = opts.AggregateSec,
        Pending = 0,
        WindowStart = nil,
        Seq = 0,
    }, Aggregator)
end

function Aggregator:SetSession(sessionId)
    checkSessionId(sessionId, "rate_limit.Aggregator:SetSession")
    self.SessionId = sessionId
    self.Pending = 0
    self.WindowStart = nil
    self.Seq = 0
end

function Aggregator:Click(now)
    if self.Pending == 0 then
        self.WindowStart = now
    end
    self.Pending = self.Pending + 1
end

function Aggregator:Collect(now)
    if self.Pending == 0 or now - self.WindowStart < self.AggregateSec then
        return nil
    end

    return self:Flush()
end

function Aggregator:Flush()
    if self.Pending == 0 then
        return nil
    end

    self.Seq = self.Seq + 1
    local payload = { s = self.SessionId, n = self.Pending, q = self.Seq }
    self.Pending = 0
    self.WindowStart = nil
    return payload
end

function Aggregator:PendingCount()
    return self.Pending
end


local Receiver = {}
Receiver.__index = Receiver

function rate_limit.NewReceiver(opts)
    opts = opts or {}
    return setmetatable({
        SessionId = opts.SessionId,
        Window = rate_limit.NewWindow(opts.WindowSec, opts.MaxCount),
        LastSeq = nil,
    }, Receiver)
end

function Receiver:SetSession(sessionId)
    checkSessionId(sessionId, "rate_limit.Receiver:SetSession")
    self.SessionId = sessionId
    self.LastSeq = nil
    self.Window:Reset()
end

function Receiver:EndSession()
    self.SessionId = nil
    self.LastSeq = nil
    self.Window:Reset()
end

local function drop(reason, seq)
    return { Status = rate_limit.Result.Dropped, Reason = reason, Seq = seq }
end

function Receiver:Accept(now, msg)
    if type(msg) ~= "table" then
        return drop(rate_limit.Reason.BadPayload, nil)
    end

    local n = msg.n
    local q = msg.q
    if type(msg.s) ~= "string" or msg.s == ""
        or not isFiniteNumber(n) or n < 1 or n ~= math.floor(n)
        or not isFiniteNumber(q) or q < 1 or q ~= math.floor(q) then
        return drop(rate_limit.Reason.BadPayload, nil)
    end

    if self.SessionId == nil or msg.s ~= self.SessionId then
        return drop(rate_limit.Reason.Session, q)
    end

    if self.LastSeq ~= nil and q <= self.LastSeq then
        return drop(rate_limit.Reason.Order, q)
    end

    self.LastSeq = q
    local accepted = self.Window:Admit(now, n)
    return {
        Status = rate_limit.Result.Ok,
        Requested = math.floor(n),
        Accepted = accepted,
        Seq = q,
        Clamped = accepted < math.floor(n),
    }
end

return rate_limit
