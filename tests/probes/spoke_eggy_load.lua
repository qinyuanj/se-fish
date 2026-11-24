-- spoke_eggy 宿主包探针：不入任何 .busted 车道，执行方式与 tests/probes/ 其它探针一致。
--   lua tests/probes/spoke_eggy_load.lua
-- 目的：验证宿主层落位与「只 require 核心包」的依赖方向、Auto 树首帧同步 flush、
-- Destroying 先翻 is_alive 再 detach、dispose 幂等、不读宿主全局。
-- 完整行为规格由上游 tests/host/spoke_eggy_spec.lua 负责，本探针不重复。

package.path = "./?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if not ok then failures = failures + 1 end
  print(string.format("[spoke_eggy_load] %-32s %s %s", name, ok and "OK" or "FAIL", detail or ""))
end

-- 假 Unit：宿主层只允许索要 Destroying 的 Connect 协议与只读的 Name，其余一概不读。
local function fake_unit(name)
  local signal = { connections = {} }

  function signal:Connect(fn)
    local connection = { fn = fn, is_connected = true }
    function connection:Disconnect()
      self.is_connected = false
      self.fn = nil
    end
    self.connections[#self.connections + 1] = connection
    return connection
  end

  function signal:fire()
    for _, connection in ipairs(self.connections) do
      if connection.is_connected and connection.fn then
        connection.fn()
      end
    end
  end

  return { Name = name, Destroying = signal }, signal
end

local ok_api, spoke_eggy = pcall(require, "common.packages.spoke_eggy.api")
check("require api", ok_api, ok_api and "" or tostring(spoke_eggy))
if not ok_api then print("[spoke_eggy_load] failures=" .. failures) os.exit(1) end

check("导出 behaviour", type(spoke_eggy.behaviour) == "function")
check("不进核心门面", require("common.packages.spoke.api").spoke_eggy == nil)

local unit, signal = fake_unit("FishingPanel")
local seen = {}
local handle
local ok_behaviour, err = pcall(function()
  handle = spoke_eggy.behaviour(unit, function(s, self)
    check("init 内 root 为 nil", self.root == nil)
    s:effect(function(tick)
      seen[#seen + 1] = tick:d(self.is_alive)
    end)
  end)
end)
check("behaviour 同步执行 init", ok_behaviour, ok_behaviour and "" or tostring(err))
check("树名 Unit:SpokeTree", handle ~= nil and handle.root.name == "FishingPanel:SpokeTree")
check("首帧同步 flush", #seen == 1 and seen[1] == true, "seen=" .. #seen)

signal:fire()
check("Destroying 先跑一次 is_alive", #seen == 2 and seen[2] == false, "seen=" .. #seen)
check("Destroying 后树已 detach", handle.root.is_detached == true)
check("Destroying 后连接已断", signal.connections[1].is_connected == false)

handle:dispose()
check("dispose 幂等", handle.root.is_detached == true and handle.is_alive:now() == false)

local ok_reject, rejected = pcall(spoke_eggy.behaviour, {}, function() end)
check("拒绝无 Destroying 的 Unit", ok_reject == false and tostring(rejected):find("Destroying", 1, true) ~= nil)

-- 宿主全局探针：加载与运行都不许碰 game / RunService / World / workspace / EUI。
local HOST_GLOBALS = { "game", "RunService", "World", "workspace", "EUI" }
local touched, saved = {}, {}
for _, name in ipairs(HOST_GLOBALS) do
  saved[name] = rawget(_G, name)
  rawset(_G, name, setmetatable({}, {
    __index = function(_, key) touched[#touched + 1] = name .. "." .. tostring(key) end,
    __call = function() touched[#touched + 1] = name .. "()" end,
  }))
end

local ok_spy, spy_err = pcall(function()
  package.loaded["common.packages.spoke_eggy.api"] = nil
  local fresh = require("common.packages.spoke_eggy.api")
  local probe_unit, probe_signal = fake_unit("probe")
  local spy_handle = fresh.behaviour(probe_unit, function(s, self)
    s:effect(function(tick) tick:d(self.is_alive) end)
  end)
  probe_signal:fire()
  spy_handle:dispose()
end)

for _, name in ipairs(HOST_GLOBALS) do rawset(_G, name, saved[name]) end
check("不读宿主全局", ok_spy and #touched == 0,
  (not ok_spy and tostring(spy_err)) or table.concat(touched, ","))

print("[spoke_eggy_load] failures=" .. failures)
os.exit(failures == 0 and 0 or 1)
