local Gesture = {}
Gesture.__index = Gesture

local DEFAULTS = {
    LongPressSec = 0.35,
    MoveTolerancePx = 12,
}

function Gesture.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Gesture)
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

function Gesture:begin(t, pos)
    self.Active = true
    self.StartT = t
    self.StartPos = pos and { x = pos.x, y = pos.y } or nil
    self.LongFired = false
    self.Canceled = false
    return true
end

function Gesture:update(t)
    if not self.Active then return false end
    if self.Canceled or self.LongFired then return false end
    if t - (self.StartT or t) >= self.LongPressSec then
        self.LongFired = true
        return true
    end
    return false
end

function Gesture:finish(t, pos)
    if not self.Active then return nil end
    self.Active = false
    if self.LongFired then return 'long' end
    if self.Canceled or movedFar(self, pos) then return nil end
    if t - (self.StartT or t) >= self.LongPressSec then return 'long' end
    return 'tap'
end

function Gesture:move(pos)
    if not self.Active or self.LongFired then return end
    if movedFar(self, pos) then self.Canceled = true end
end

return Gesture
