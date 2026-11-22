local REUtil = require('common.REUtil')
local RateLimit = require('common.RateLimit')
local GameCfg = require('common.GameCfg')
local ReelDisplay = require('common.ReelDisplay')
local spoke = require('common.packages.spoke.api')

local SpokeTree, LambdaEpoch, Effect, Trigger, Phase, State =
    spoke.SpokeTree, spoke.LambdaEpoch, spoke.Effect, spoke.Trigger, spoke.Phase, spoke.State

local LocalReelIn = { SessionId = nil }
LocalReelIn.CHANNEL = 'ReelInRE'

function LocalReelIn:SetSession(id)
    if type(id) ~= 'string' or id == '' or self.ClosedSession == id then return false end
    if self.SessionId == id then return true end
    self.SessionId = id
    self.Aggregator = RateLimit.NewAggregator({ SessionId = id,
        AggregateSec = GameCfg.HighFreqInput.AggregateSec })
    self.Display = ReelDisplay.New(self.World:GetServerTime(), GameCfg.ReelIn)
    self.Session:set(id)
    return true
end

function LocalReelIn:Send(payload)
    if not payload then return end
    if self.Display then self.Display:Sent(payload.q, payload.n, self.World:GetServerTime()) end
    self.RE:FireServer(payload)
end

function LocalReelIn:Flush()
    if not self.Aggregator then return end
    self:Send(self.Aggregator:Flush())
end

function LocalReelIn:Click()
    if not self.Aggregator then return end
    local now = self.World:GetServerTime()
    self.Aggregator:Click(now)
    if self.Display then self.Display:Click(now) end
end

function LocalReelIn:DisplayProgress()
    return self.Display and self.Display:Value(self.World:GetServerTime()) or nil
end

function LocalReelIn:Close(id)
    local session = id or self.SessionId
    if not session or (self.SessionId and self.SessionId ~= session)
        or self.ClosedSession == session then return end
    local payload = self.Aggregator and self.Aggregator:Flush()
    self.ClosedSession = session
    self.SessionId = nil
    self.Aggregator = nil
    self.Display = nil
    if payload then self.RE:FireServer(payload) end
    self.Session:set(nil)
    self.CloseRE:FireServer({ session = session })
end

function LocalReelIn:Suspend()
    if self.Aggregator then self:Flush() end
end

function LocalReelIn:Clear(id)
    if not id or self.SessionId ~= id then return end
    self.ClosedSession = id
    self.SessionId = nil
    self.Aggregator = nil
    self.Display = nil
    self.Session:set(nil)
end

function LocalReelIn:HandleInbound(payload)
    if type(payload) ~= 'table' or type(payload.session) ~= 'string' then return end
    if payload.action == 'started' then
        if not self:SetSession(payload.session) then return end
    elseif self.SessionId ~= payload.session then return end
    self.LastResult = payload
    if self.Display and (payload.action == 'progress' or payload.action == 'started') then
        self.Display:Authority(self.World:GetServerTime(), payload.progress, payload.q)
    end
    if payload.action == 'landed' or payload.action == 'unhooked' then
        self:Clear(payload.session)
    end
end

function LocalReelIn:Stop()
    self:Close()
    if self.Tree then
        self.Tree:dispose()
        self.Tree = nil
    end
    self.Session = nil
    self.World = nil
    self.RE = nil
    self.CloseRE = nil
end

function LocalReelIn:Start()
    if self.Tree then return end
    self.World = game:GetService('World')
    self.RE = REUtil:GetRE(self.CHANNEL)
    self.CloseRE = REUtil:GetRE('CloseReelIn')
    -- #232 两参数的 State.new 才是「名字 + 初值」；只写 State.new('session') 会把 'session' 当成初值。
    self.Session = State.new('session', nil)
    local inbox = {}
    local inbound = Trigger.new('LocalReelIn.Inbound')
    self.Tree = SpokeTree.spawn('LocalReelIn', LambdaEpoch.new(function(s)
        -- 宿主连接只有 Disconnect、不是 disposable：用 s:use 会在 Init 期 fault 整棵树，只能走 on_cleanup。
        local connection = self.RE.OnClientEvent:Connect(function(payload)
            if self.Tree and self.Tree.fault then return end
            inbox[#inbox + 1] = payload
            inbound:invoke()
        end)
        s:on_cleanup(function() connection:Disconnect() end)
        s:call(Effect.new(function()
            while #inbox > 0 do
                self:HandleInbound(table.remove(inbox, 1))
            end
        end, inbound))
        -- 条件必须直接给 State：写成 Memo(session ~= nil) 会把 s1→s2 归约成 true→true 而不重跑，
        -- 旧心跳就带着旧会话活下去了。
        s:call(Phase.new(self.Session, function(ps)
            local session = self.Session:now() -- 挂载时捕获：cleanup 里再读 State 读到的是新会话
            local heartbeat = game:GetService('RunService').Heartbeat:Connect(function()
                if self.SessionId == session then
                    self:Send(self.Aggregator:Collect(self.World:GetServerTime()))
                end
            end)
            ps:on_cleanup(function() heartbeat:Disconnect() end)
        end))
    end))
end

return LocalReelIn