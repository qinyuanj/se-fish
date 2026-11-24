local Gesture = {}
Gesture.__index = Gesture

local DEFAULTS = {
    LongPressSec = 0.35,
    move_tolerance_px = 12,
}

function Gesture.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Gesture)
    self.LongPressSec = opts.LongPressSec or DEFAULTS.LongPressSec
    self.move_tolerance_px = opts.move_tolerance_px or DEFAULTS.move_tolerance_px
    self.Active = false
    return self
end

local function movedFar(self, pos)
    if not pos or not self.start_pos then return false end
    local dx, dy = pos.x - self.start_pos.x, pos.y - self.start_pos.y
    return dx * dx + dy * dy > self.move_tolerance_px * self.move_tolerance_px
end

function Gesture:begin(t, pos)
    self.Active = true
    self.start_t = t
    self.start_pos = pos and { x = pos.x, y = pos.y } or nil
    self.long_fired = false
    self.canceled = false
    return true
end

function Gesture:update(t)
    if not self.Active then return false end
    if self.canceled or self.long_fired then return false end
    if t - (self.start_t or t) >= self.LongPressSec then
        self.long_fired = true
        return true
    end
    return false
end

function Gesture:finish(t, pos)
    if not self.Active then return nil end
    self.Active = false
    if self.long_fired then return 'long' end
    if self.canceled or movedFar(self, pos) then return nil end
    if t - (self.start_t or t) >= self.LongPressSec then return 'long' end
    return 'tap'
end

function Gesture:move(pos)
    if not self.Active or self.long_fired then return end
    if movedFar(self, pos) then self.canceled = true end
end

return Gesture
