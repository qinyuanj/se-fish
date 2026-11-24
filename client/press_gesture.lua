local gesture = {}
gesture.__index = gesture

local DEFAULTS = {
    LongPressSec = 0.35,
    MoveTolerancePx = 12,
}

function gesture.New(opts)
    opts = opts or {}
    local self = setmetatable({}, gesture)
    self.LongPressSec = opts.LongPressSec or DEFAULTS.LongPressSec
    self.MoveTolerancePx = opts.MoveTolerancePx or DEFAULTS.MoveTolerancePx
    self.Active = false
    return self
end

local function movedFar(self, pos)
    if not pos or not self.StartPos then return false end
    local dx, dy = pos.x - self.StartPos.x, pos.y - self.StartPos.y
    return dx * dx + dy * dy > self.MoveTolerancePx * self.MoveTolerancePx
end

function gesture:Begin(t, pos)
    self.Active = true
    self.StartT = t
    self.StartPos = pos and { x = pos.x, y = pos.y } or nil
    self.LongFired = false
    self.Canceled = false
    return true
end

function gesture:Update(t)
    if not self.Active then return false end
    if self.Canceled or self.LongFired then return false end
    if t - (self.StartT or t) >= self.LongPressSec then
        self.LongFired = true
        return true
    end
    return false
end

function gesture:End(t, pos)
    if not self.Active then return nil end
    self.Active = false
    if self.LongFired then return 'long' end
    if self.Canceled or movedFar(self, pos) then return nil end
    if t - (self.StartT or t) >= self.LongPressSec then return 'long' end
    return 'tap'
end

function gesture:Move(pos)
    if not self.Active or self.LongFired then return end
    if movedFar(self, pos) then self.Canceled = true end
end

return gesture
