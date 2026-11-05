--技能系统 - client按住持续施法策略
-- 按下后立即尝试施法并开启循环检测持续施法，松开时请求停止。

local BaseStrategy = require("client.packages.ability_system.strategy.BaseStrategy")

local HoldStrategy = setmetatable({}, BaseStrategy)
HoldStrategy.__index = HoldStrategy

function HoldStrategy:OnTouchBegin(eventData)
	self.isHolding = true
	local ctrl = self.ctrl
	local Task = game:GetService("Task")

	-- 立即尝试一次
	self:TryCast()

	-- 开启循环检测（Task:Delay 自调度；取消走 Task:Cancel）
	if self.timer then
		Task:Cancel(self.timer)
	end
	local function tick()
		if not self.isHolding then
			self.timer = nil
			return
		end
		self:TryCast()
		self.timer = Task:Delay(0.1, tick)
	end
	self.timer = Task:Delay(0.1, tick)
end

function HoldStrategy:TryCast()
	if not self.isHolding then
		return
	end
	local ctrl = self.ctrl
	if not ctrl._ability then
		return
	end
	-- 充能次数耗尽：结束本次持续施法交互（停循环并收掉界面残留）
	if ctrl.HasCastableCharge and not ctrl:HasCastableCharge() then
		self:Cancel()
		if ctrl.CancelInteraction then
			ctrl:CancelInteraction()
		end
		return
	end
	-- 简单检查 CD（服务端也会检查，客户端预判减少请求）
	if not ctrl._ability:GetAttribute("InCD") then
		local owner = ctrl:GetOwner()
		if not owner then
			return
		end
		local dir = owner.Forward
		ctrl:_requestCast(nil, dir, nil)
	end
end

function HoldStrategy:OnTouchEnd(eventData)
	self.isHolding = false
	if self.timer then
		game:GetService("Task"):Cancel(self.timer)
		self.timer = nil
	end

	local ctrl = self.ctrl
	ctrl:_requestStop()
end

-- 外部强制取消（如按钮被禁用）：停止持续施法循环；不打断服务端进行中的施法
function HoldStrategy:Cancel()
	self.isHolding = false
	if self.timer then
		game:GetService("Task"):Cancel(self.timer)
		self.timer = nil
	end
end

function HoldStrategy:Destroy()
	self.isHolding = false
	if self.timer then
		game:GetService("Task"):Cancel(self.timer)
		self.timer = nil
	end
end

return HoldStrategy
