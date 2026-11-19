local REUtil = require('common.REUtil')
local RateLimit = require('common.RateLimit')
local GameCfg = require('common.GameCfg')
local ReelDisplay = require('common.ReelDisplay')
local spoke = require('common.packages.spoke.api')

local SpokeTree, LambdaEpoch, Effect, Trigger =
    spoke.SpokeTree, spoke.LambdaEpoch, spoke.Effect, spoke.Trigger

local LocalReelIn = { SessionId = nil }
LocalReelIn.CHANNEL = 'ReelInRE'

function LocalReelIn:SetSession(id)
    if type(id) ~= 'string' or id == '' or self.ClosedSession == id then return false end
    if self.SessionId == id then return true end
    self.SessionId = id
    self.Aggregator = RateLimit.NewAggregator({ SessionId = id,
        AggregateSec = GameCfg.HighFreqInput.AggregateSec })
    self.Display = ReelDisplay.New(self.World:GetServerTime(), GameCfg.ReelIn)
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

-- 当前会话的显示进度（本地反馈 + 平滑追平）；没有会话返回 nil
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
    self.CloseRE:FireServer({ session = session })
end

-- #133 界面被遮挡只是表现：待发批次先送出去（C-10），会话、序号与本地进度原样保留。
-- 不主动收线——服务端照常按权威时钟衰减，到 0 由服务端判脱钩，重开界面接着显示同一个进度。
-- 这里不做本地暂停：留一个「暂停中」标志只会让人以为计时停了，实际权威进度仍在下降。
function LocalReelIn:Suspend()
    if self.Aggregator then self:Flush() end
end

function LocalReelIn:Clear(id)
    if not id or self.SessionId ~= id then return end
    self.ClosedSession = id
    self.SessionId = nil
    self.Aggregator = nil
    self.Display = nil
end

-- 一条入站事件的业务处理。它由树里的 Effect 调用，不直接挂在 RE 连接上：
-- 这里抛出的执行期错误会进 tree.fault（树级故障），不会甩回宿主的事件回调。
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

-- 停止：先走既有结束顺序（Close 送出待发批次与 CloseReelIn），再统一销毁树与各处连接。
function LocalReelIn:Stop()
    self:Close()
    if self.Tree then
        self.Tree:dispose()
        self.Tree = nil
    end
    if self.UpdateConnection then self.UpdateConnection:Disconnect() end
    self.UpdateConnection = nil
    self.World = nil
    self.RE = nil
    self.CloseRE = nil
end

-- 启停与入站订阅交给一棵 Auto 树持有：重复 Start 不叠加订阅，Stop 之后 Start 得到一棵全新的树。
function LocalReelIn:Start()
    if self.Tree then return end
    self.World = game:GetService('World')
    self.RE = REUtil:GetRE(self.CHANNEL)
    self.CloseRE = REUtil:GetRE('CloseReelIn')
    -- RE 回调只登记载荷并唤醒 Trigger，真正的处理在树里的 Effect 里跑。
    -- 队列与 Trigger 都是本次 Start 私有的：旧连接即使有残留送达，也只写进没人读的队列。
    local inbox = {}
    local inbound = Trigger.new('LocalReelIn.Inbound')
    self.Tree = SpokeTree.spawn('LocalReelIn', LambdaEpoch.new(function(s)
        -- 宿主连接只有 Disconnect、不是 disposable：用 s:use 会在 Init 期 fault 整棵树，只能走 on_cleanup。
        local connection = self.RE.OnClientEvent:Connect(function(payload)
            inbox[#inbox + 1] = payload
            inbound:invoke(payload)
        end)
        s:on_cleanup(function() connection:Disconnect() end)
        s:call(Effect.new(function()
            while #inbox > 0 do
                self:HandleInbound(table.remove(inbox, 1))
            end
        end, inbound))
    end))
    -- 合批心跳仍按现状挂在这里（#232 才把它搬进会话 Phase）：上行频率、批次内容与消息顺序逐字不变。
    self.UpdateConnection = game:GetService('RunService').Heartbeat:Connect(function()
        if self.Aggregator then
            self:Send(self.Aggregator:Collect(self.World:GetServerTime()))
        end
    end)
end

return LocalReelIn