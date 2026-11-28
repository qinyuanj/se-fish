---@class ReelDisplay
---@field cfg table
---@field auth number
---@field auth_at number
---@field local_slot number
---@field local_at number
---@field unsent number
---@field in_flight table[]
---@field Chase { From: number, Start: number }?
local ReelDisplay = {}
ReelDisplay.__index = ReelDisplay

local function clamp(value)
    return math.max(0, math.min(100, value))
end

function ReelDisplay.new(now, cfg)
    return setmetatable({ cfg = cfg, auth = cfg.Initial, auth_at = now,
        local_slot = cfg.Initial, local_at = now, unsent = 0, in_flight = {}, Chase = nil }, ReelDisplay)
end

function ReelDisplay:pending_clicks()
    local count = self.unsent
    for _, batch in ipairs(self.in_flight) do count = count + batch.n end
    return count
end

function ReelDisplay:Target(now)
    return clamp(self.auth - self.cfg.DecayPerSec * (now - self.auth_at)
        + self:pending_clicks() * self.cfg.ClickGain)
end

function ReelDisplay:value(now)
    local chase = self.Chase
    if chase then
        local alpha = (now - chase.Start) / self.cfg.ChaseSec
        if alpha < 1 then
            return clamp(chase.From + (self:Target(now) - chase.From) * math.max(0, alpha))
        end
        self.Chase = nil
        self.local_slot, self.local_at = self:Target(now), now
    end
    return clamp(self.local_slot - self.cfg.DecayPerSec * (now - self.local_at))
end

function ReelDisplay:click(now)
    local gain = self.cfg.ClickGain
    self.unsent = self.unsent + 1
    if self.Chase then
        self.Chase.From = self.Chase.From + gain
    else
        self.local_slot, self.local_at = clamp(self:value(now) + gain), now
    end
end

function ReelDisplay:sent(q, n, now)
    self.unsent = math.max(0, self.unsent - n)
    self.in_flight[#self.in_flight + 1] = { q = q, n = n, at = now }
end

function ReelDisplay:authority(now, progress, q)
    if type(progress) ~= 'number' or progress ~= progress then return end
    local shown = self:value(now)
    local kept = {}
    for _, batch in ipairs(self.in_flight) do
        if not (q and batch.q <= q) and now - batch.at <= self.cfg.PendingTimeoutSec then
            kept[#kept + 1] = batch
        end
    end
    self.in_flight = kept
    self.auth, self.auth_at = clamp(progress), now
    if math.abs(shown - self:Target(now)) > self.cfg.Tolerance then
        self.Chase = { From = shown, Start = now }
    end
end

return ReelDisplay
