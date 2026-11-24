local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local Number = require("common.Number")

local State = spoke.State
local Trigger = spoke.Trigger

local SpokeClock = {}

local function assert_finite_number(value, label)
  if not Number.IsFiniteNumber(value) then
    error(label .. " 必须是有限数字", 3)
  end
end

local function assert_non_negative_finite(value, label)
  if not Number.IsFiniteNumber(value) or value < 0 then
    error(label .. " 必须是非负有限数字", 3)
  end
end

---@param initial_now number|nil
---@return { second: table, on_second: table, on_frame: table, now: fun(): number, step: fun(self: table, dt: number, now?: number), advance: fun(self: table, seconds: number) }
function SpokeClock.new(initial_now)
  local start_now = initial_now == nil and 0 or initial_now
  assert_finite_number(start_now, "SpokeClock.new initial_now")

  local current_now = start_now
  local second = State.new("SpokeClock.second", math.floor(start_now))
  local on_second = Trigger.new("SpokeClock.on_second")
  local on_frame = Trigger.new("SpokeClock.on_frame")

  local clock = {
    second = second,
    on_second = on_second,
    on_frame = on_frame,
    now = function()
      return current_now
    end,
  }

  ---@param dt number
  ---@param now number|nil
  function clock:step(dt, now)
    assert_non_negative_finite(dt, "SpokeClock:step dt")
    local target_now
    if now == nil then
      target_now = current_now + dt
    else
      assert_finite_number(now, "SpokeClock:step now")
      target_now = now < current_now and current_now or now
    end

    local prev_sec = second:now()
    local target_sec = math.floor(target_now)
    if target_sec > prev_sec then
      for sec = prev_sec + 1, target_sec do
        current_now = sec
        SpokeRuntime.batch(function()
          second:set(sec)
          on_second:invoke(sec)
        end)
      end
    end

    current_now = target_now
    on_frame:invoke({ dt = dt, now = current_now })
  end

  ---@param seconds number
  function clock:advance(seconds)
    assert_non_negative_finite(seconds, "SpokeClock:advance seconds")
    self:step(seconds, current_now + seconds)
  end

  return clock
end

return SpokeClock
