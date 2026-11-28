---@class ReelProgress
---@field Progress number
---@field Time number
---@field zero_at number?
---@field Result string?
---@field config table
local ReelProgress = {}
ReelProgress.__index = ReelProgress

function ReelProgress.new(now, cfg)
    return setmetatable({ Progress = cfg.Initial, Time = now, zero_at = nil,
        Result = nil, config = cfg }, ReelProgress)
end

function ReelProgress:advance(now, count, span)
    if self.Result then return self.Result end
    now = math.max(now, self.Time)
    local cfg = self.config
    local function step(at)
        if self.Result then return end
        local elapsed = at - self.Time
        if elapsed > 0 then
            local before = self.Progress
            self.Progress = math.max(0.0, before - cfg.DecayPerSec * elapsed)
            if before > 0 and self.Progress == 0 then
                self.zero_at = self.Time + before / cfg.DecayPerSec
            end
            self.Time = at
        end
        if self.zero_at and at > self.zero_at + cfg.GraceSec then
            self.Result = 'unhooked'
        end
    end
    count = count or 0
    local first = math.max(self.Time, now - (span or 0))
    for i = 1, count do
        step(first + (now - first) * i / count)
        if self.Result then return self.Result end
        self.Progress = math.min(100.0, self.Progress + cfg.ClickGain)
        if self.Progress > 0 then self.zero_at = nil end
        if self.Progress == 100 then self.Result = 'landed' end
    end
    step(now)
    return self.Result
end

return ReelProgress
