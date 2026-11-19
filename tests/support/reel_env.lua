-- 收线共享夹具（#231）：RE / World / Heartbeat 三件套的适配器，断开真实生效。
-- 抽出的原因：收线用例原先各自手写「只增不减」的假 signal——Disconnect 是空操作、
-- Fire 永远送到全部历史回调，于是「会话结束 / Stop 之后旧回调不再运行」「空闲时没有合批心跳」
-- 这类失败方式在公共接缝上根本写不出来，#234 / #232 的验收点都依赖本夹具。
-- 只搭环境、不含任何断言；业务行为一律走真实管理器公共接口（LocalReelIn / MgrReelIn / ScreenMain）。
--
-- 公开 API（下游照此写断言）：
--   local Reel = require('tests.support.reel_env')
--   local env = Reel.new('client')        -- 或 'server'；缺省 'client'
--   env:setUp() / env:tearDown()          -- 装/还原 _G.game、package.loaded['common.REUtil']、_G.REUtil
--   env.now                               -- 假时钟；World:GetServerTime() 读它，可直接赋值
--   env.sent                              -- 有序上行记录
--                                         --   client: { name, payload }
--                                         --   server: { name, player, payload }
--   env.events[name] / env:remote(name)   -- 按名字取远程事件（首次访问时建）
--                                         --   client: { OnClientEvent = signal, FireServer = fn }
--                                         --   server: { OnServerEvent = signal, FireClient = fn }
--   env.world                             -- World 服务（GetServerTime，可挂 CreateUnit 等）
--   env.heartbeat                         -- RunService.Heartbeat
--   env:serve(name, service)              -- 注册额外服务（如 CameraService）
--   env:subscriptionCount(name)           -- 入站 signal 的当前存活订阅数（重复 Start 不增加用这条）
--   env:heartbeatCount()                  -- 当前存活的 Heartbeat 连接数（无会话时为 0 用这条）
--   env.onFireServer(name, payload)       -- 可选钩子：client 每次 FireServer 后调用
--   env.onFireClient(name, player, payload) -- 可选钩子：server 每次 FireClient 后调用
--   Reel.signal()                         -- 同款假 signal，给玩家事件等旁路用
--
-- signal 的形状：:Connect(fn) 返回 { Disconnect() }，:Fire(...) 送到当前存活回调，:Count() 是存活连接数。
--
-- 失败方式（夹具写错时哪条断言先红）：
--   1. Disconnect 仍是空操作 —— Stop 后存活计数不为 0，reel_client 与 reel_session 的
--      restart 用例直接红；同一退化还会让旧 RE 回调被送达，reel_client 以 error 暴露；
--   2. Disconnect 只标记不摘除 —— 同样停在存活计数（:Count() 就是存活槽位数）；
--   3. Fire 把已断开的连接也送达 —— 下游「旧会话回调安全 no-op」会被夹具掩盖成假绿；
--   4. sent 元素多带或少带字段 —— reel_client 的 assert.same({ name, payload }) 深比较失败；
--   5. role 混用（client 拿到 OnServerEvent）—— 用例里 Fire 直接报 nil 而红；
--   6. 未注册服务对 server 返回空表 —— MgrReelIn:Start 去调不存在的 GetPlayers 而崩。
-- 反证实测（#231）：把第 1 条退回空操作，fast 从 1528 绿变成 2 failures。

local M = {}

local Signal = {}
Signal.__index = Signal

--- 假 signal：Connect 返回真实生效的 handle；断开后 Fire 不再送达原回调。
function Signal:Connect(fn)
  assert(type(fn) == 'function', 'signal 回调必须是函数')
  local slots = self.slots
  local slot = { fn = fn }
  slots[#slots + 1] = slot
  return { Disconnect = function()
    if slot.fn == nil then return end
    slot.fn = nil
    for i = #slots, 1, -1 do
      if slots[i] == slot then table.remove(slots, i) break end
    end
  end }
end

--- 先取快照再逐个确认存活：回调里断开的连接在本次触发中也不再送达。
function Signal:Fire(...)
  local live = {}
  for i = 1, #self.slots do live[i] = self.slots[i] end
  for i = 1, #live do
    local slot = live[i]
    if slot.fn then slot.fn(...) end
  end
end

--- 当前存活连接数（不是累计连接次数）。
function Signal:Count()
  return #self.slots
end

--- 给玩家 CharacterAdded / Died 这类旁路事件用的同款 signal。
function M.signal()
  return setmetatable({ slots = {} }, Signal)
end

local Env = {}
Env.__index = Env

--- role: 'client'（缺省）或 'server'。未知服务的默认返回值随 role 走：
--- 客户端沿用旧夹具的空表（界面代码会直接取字段），服务端沿用旧的 nil
--- （MgrReelIn:Start 用 `if players then` 判断可选服务，空表会让它去调不存在的方法）。
function M.new(role)
  role = role or 'client'
  local env = setmetatable({
    role = role,
    events = {},
    sent = {},
    now = 0,
    heartbeat = M.signal(),
    services = {},
  }, Env)
  -- 不能写 `role == 'server' and nil or {}`：Lua 的 and/or 组合在这里恒等于 {}。
  if role ~= 'server' then env.defaultService = {} end
  env.world = { GetServerTime = function() return env.now end }
  env.services.World = env.world
  env.services.RunService = { Heartbeat = env.heartbeat }
  return env
end

--- 抓还原快照并装上 _G.game / _G.REUtil / package.loaded['common.REUtil']。
function Env:setUp()
  self.saved = {
    game = rawget(_G, 'game'),
    REUtil = rawget(_G, 'REUtil'),
    loaded = package.loaded['common.REUtil'],
  }
  self.reutil = {
    GetRE = function(_, name) return self:remote(name) end,
    CheckRECD = function() return false end,
  }
  package.loaded['common.REUtil'] = self.reutil
  _G.REUtil = self.reutil
  _G.game = { GetService = function(_, name) return self:service(name) end }
  return self
end

--- 还原 setUp 前的快照；对没跑完的 setUp 幂等（与收线用例的 after_each 约定一致）。
function Env:tearDown()
  local saved = self.saved
  if not saved then return end
  self.saved = nil
  _G.game = saved.game
  _G.REUtil = saved.REUtil
  package.loaded['common.REUtil'] = saved.loaded
end

--- 注册一个额外服务（CameraService、Players……），返回该服务。
function Env:serve(name, service)
  self.services[name] = service
  return service
end

function Env:service(name)
  local service = self.services[name]
  if service ~= nil then return service end
  return self.defaultService
end

--- 按名字取远程事件，第一次访问时按 role 建。
function Env:remote(name)
  local remote = self.events[name]
  if remote then return remote end
  if self.role == 'server' then
    remote = {
      OnServerEvent = M.signal(),
      FireClient = function(_, player, payload)
        self.sent[#self.sent + 1] = { name = name, player = player, payload = payload }
        if self.onFireClient then self.onFireClient(name, player, payload) end
      end,
    }
  else
    remote = {
      OnClientEvent = M.signal(),
      FireServer = function(_, payload)
        self.sent[#self.sent + 1] = { name = name, payload = payload }
        if self.onFireServer then self.onFireServer(name, payload) end
      end,
    }
  end
  self.events[name] = remote
  return remote
end

--- 入站 signal 的当前存活订阅数（重复 Start 不叠加订阅用这条）。
function Env:subscriptionCount(name)
  local remote = self:remote(name)
  if self.role == 'server' then return remote.OnServerEvent:Count() end
  return remote.OnClientEvent:Count()
end

--- 当前存活的 Heartbeat 连接数（无会话时为 0 用这条）。
function Env:heartbeatCount()
  return self.heartbeat:Count()
end

return M
