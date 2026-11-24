local ReelDisplay = {}
ReelDisplay.__index = ReelDisplay

local function clamp(value)
    return math.max(0, math.min(100, value))
end

function ReelDisplay.New(now, cfg)
    return setmetatable({ Cfg = cfg, Auth = cfg.Initial, AuthAt = now,
        Local = cfg.Initial, LocalAt = now, Unsent = 0, InFlight = {}, Chase = nil }, ReelDisplay)
end

function ReelDisplay:PendingClicks()
    local count = self.Unsent
    for _, batch in ipairs(self.InFlight) do count = count + batch.n end
    return count
end

function ReelDisplay:Target(now)
    return clamp(self.Auth - self.Cfg.DecayPerSec * (now - self.AuthAt)
        + self:PendingClicks() * self.Cfg.ClickGain)
end

function ReelDisplay:Value(now)
    local chase = self.Chase
    if chase then
        local alpha = (now - chase.Start) / self.Cfg.ChaseSec
        if alpha < 1 then
            return clamp(chase.From + (self:Target(now) - chase.From) * math.max(0, alpha))
        end
        self.Chase = nil
        self.Local, self.LocalAt = self:Target(now), now
    end
    return clamp(self.Local - self.Cfg.DecayPerSec * (now - self.LocalAt))
end

function ReelDisplay:Click(now)
    local gain = self.Cfg.ClickGain
    self.Unsent = self.Unsent + 1
    if self.Chase then
        self.Chase.From = self.Chase.From + gain
    else
        self.Local, self.LocalAt = clamp(self:Value(now) + gain), now
    end
end

function ReelDisplay:Sent(q, n, now)
    self.Unsent = math.max(0, self.Unsent - n)
    self.InFlight[#self.InFlight + 1] = { q = q, n = n, At = now }
end

function ReelDisplay:Authority(now, progress, q)
    if type(progress) ~= 'number' or progress ~= progress then return end
    local shown = self:Value(now)
    local kept = {}
    for _, batch in ipairs(self.InFlight) do
        if not (q and batch.q <= q) and now - batch.At <= self.Cfg.PendingTimeoutSec then
            kept[#kept + 1] = batch
        end
    end
    self.InFlight = kept
    self.Auth, self.AuthAt = clamp(progress), now
    if math.abs(shown - self:Target(now)) > self.Cfg.Tolerance then
        self.Chase = { From = shown, Start = now }
    end
end

return ReelDisplay
