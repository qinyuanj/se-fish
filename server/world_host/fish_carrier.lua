
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local DamageNotice = require("common.damage_notice")

local Mgr = {}

Mgr.RECEIVER_NAME = "FishHitReceiver"
Mgr.BODY_NAME_PREFIX = "FishCarrier"
Mgr.BodySeq = 0

Mgr.DEFAULT_MAX_HEALTH = 100

Mgr.Carriers = {}
Mgr.Subscribers = {}


local function isPositiveNumber(v)
	return Number.is_finite_number(v) and v > 0
end

local function resolveMaxHealth(opts, cfg)
	cfg = cfg or GameCfg.FishCarrier or {}
	local v = opts and opts.MaxHealth
	if v == nil then
		v = cfg.MaxHealth
	end
	if not isPositiveNumber(v) then
		return Mgr.DEFAULT_MAX_HEALTH
	end
	return v
end

local function resolveMesh(opts, cfg)
	cfg = cfg or GameCfg.FishCarrier or {}
	if opts and opts.RenderMeshId and opts.RenderMeshId ~= "" then
		return opts.RenderMeshId
	end
	if cfg.RenderMeshId and cfg.RenderMeshId ~= "" then
		return cfg.RenderMeshId
	end
	local id = (opts and opts.ModelId) or cfg.ModelId
	if id ~= nil and id ~= "" then
		return "official://mesh/" .. tostring(id)
	end
	return nil
end

Mgr.ResolveMaxHealth = resolveMaxHealth
Mgr.ResolveMesh = resolveMesh


local function readPosition(unit)
	if not unit then
		return nil
	end
	if unit.GetPosition then
		return unit:GetPosition()
	end
	local ok, pos = pcall(function()
		return unit.Position
	end)
	if ok then
		return pos
	end
	return nil
end

local function syncReceiver(carrier, targetPosition)
	if carrier.AiOwnsMovement then return end
	local body = carrier.Body
	local receiver = carrier.Receiver
	if not body or not receiver then
		return
	end
	local ok, pos = true, targetPosition
	if not pos then ok, pos = pcall(readPosition, body) end
	if not ok or not pos then
		return
	end
	carrier.LastPosition = { x = pos.x, y = pos.y, z = pos.z }
	pcall(function()
		if receiver.SetPosition then
			receiver:SetPosition(pos + carrier.ReceiverOffset)
		else
			receiver.Position = pos + carrier.ReceiverOffset
		end
	end)
end

function Mgr:subscribe_died(fn)
	if type(fn) ~= "function" then
		return false
	end
	self.Subscribers[#self.Subscribers + 1] = fn
	return true
end

function Mgr:unsubscribe_died(fn)
	if type(fn) ~= "function" then
		return false
	end
	for i = #self.Subscribers, 1, -1 do
		if self.Subscribers[i] == fn then
			table.remove(self.Subscribers, i)
			return true
		end
	end
	return false
end

function Mgr:sync_position(carrier, targetPosition)
	carrier.SkipNextAutoSync = targetPosition ~= nil
	syncReceiver(carrier, targetPosition)
end

function Mgr:sync_ai_position(carrier)
	if not carrier or not carrier.AiOwnsMovement then return true end
	local ok, err = pcall(function()
		local p = carrier.Receiver.Position
		for _, key in ipairs({ 'x', 'y', 'z' }) do
			local value = p and p[key]
			assert(Number.is_finite_number(value), '受击体坐标异常：' .. key)
		end
		local offset = carrier.ReceiverOffset or Vector3.New(0, 0, 0)
		carrier.Body.Position = Vector3.New(p.x - offset.x, p.y - offset.y, p.z - offset.z)
		carrier.Body.LinearVelocity = Vector3.New(0, 0, 0)
	end)
	if not ok then
		carrier.AiOwnsMovement = false
		print('[FishCarrier] operation=SyncAiPosition', carrier.Body and carrier.Body.UnitId, tostring(err))
	end
	return ok
end

-- 实测（M18 台账 §11.3）：致命那一下引擎**只发 `Died`、不发 `HealthChanged`**，所以两条都要接。
-- 通知前把 Controller 的真血量同步回记录：致命一击时 Died 早于 HealthChanged，
-- 订阅者若读 carrier.Health 会看到上一档的值（实测读到 25 而不是 0）。
function Mgr:record_health(carrier)
	if not carrier or carrier.Dead or not carrier.Controller then return end
	local ok, health = pcall(function() return carrier.Controller.Health end)
	if not ok or type(health) ~= 'number' or health ~= health then return end
	local previous = carrier.Health
	local position
	if carrier.Body then
		local positionOk, currentPosition = pcall(readPosition, carrier.Body)
		if positionOk then position = currentPosition end
	end
	if not position then position = carrier.LastPosition end
	carrier.Health = health
	if position then carrier.LastPosition = { x = position.x, y = position.y, z = position.z } end
	if carrier.Body and carrier.Body.UnitId and previous and health < previous then
		if position then
			local heightOk, size = pcall(function() return carrier.Body.Size end)
			local height = heightOk and size and size.y
			local payload = DamageNotice.from_health(carrier.Body.UnitId, previous, health, position,
				nil, 'fish', height)
			if payload then
				print('[FishCarrier] 实际扣血', payload.targetId, previous, health, payload.amount)
				local sent, err = pcall(self.damage_publisher or DamageNotice.publish, payload)
				if not sent then print('[FishCarrier] 伤害通知失败', carrier.Body.UnitId, tostring(err)) end
			end
		else
			print('[FishCarrier] 实际扣血缺少受伤位置', carrier.Body.UnitId, previous, health)
		end
	end
end

function Mgr:notify_died(carrier)
	if not carrier or carrier.Dead then
		return
	end
	self:record_health(carrier)
	carrier.Dead = true
	if carrier.Controller then
		local ok, health = pcall(function()
			return carrier.Controller.Health
		end)
		if ok and type(health) == "number" then
			carrier.Health = health
		end
	end
	for _, fn in ipairs(self.Subscribers) do
		pcall(fn, carrier)
	end
end

function Mgr:resolve_carrier(target)
    if not target then return nil end
    for _, carrier in pairs(self.Carriers) do
        if target == carrier or target == carrier.Body or target == carrier.Receiver
            or target.Carrier == carrier then
            return carrier
        end
    end
end

function Mgr:attach(body, opts)
	opts = opts or {}
	local World = rawget(_G, "game") and game:GetService("World") or nil
	local createUnit = opts.CreateUnit or function(kind, props)
		return World and World:CreateUnit(kind, props) or nil
	end
	if not body or not createUnit then
		return nil
	end

	local pos = readPosition(body) or Vector3.New(0, 0, 0)
	local maxHealth = resolveMaxHealth(opts)

	-- 受击体：与鱼本体同名的受击点。EggyUnit + EnableController 是引擎里唯一「脚本能建、
	-- 又带 Controller」的单位类型（WorldUnit 挂不上 Controller，#32 的根因）。
	local receiver = createUnit("EggyUnit", {
		Name = Mgr.RECEIVER_NAME .. "_" .. tostring(body.UnitId),
		Parent = body,
		Position = pos + (opts.ReceiverOffset or Vector3.New(0, 0, 0)),
		EnableController = true,
		Visible = false,
	})
	if not receiver then
		print("[FishCarrier] 受击体创建失败，这条鱼不会被挥砍扣血: " .. tostring(body.UnitId))
		return nil
	end

	local controller = receiver.Controller
	if not controller then
		pcall(function()
			receiver:Destroy()
		end)
		print("[FishCarrier] 受击体没有 Controller，伤害接口不成立: " .. tostring(body.UnitId))
		return nil
	end

	controller.MaxHealth = maxHealth
	controller.Health = maxHealth

	local carrier = {
		Body = body,
		Receiver = receiver,
		Controller = controller,
		MaxHealth = maxHealth,
		Health = maxHealth,
		FishId = opts.FishId,
		Player = opts.Player,
		ReceiverOffset = opts.ReceiverOffset or Vector3.New(0, 0, 0),
		LastPosition = { x = pos.x, y = pos.y, z = pos.z },
		Dead = false,
	}

	carrier.HealthConn = controller.HealthChanged:Connect(function()
		Mgr:record_health(carrier)
		if carrier.Health <= 0 then
			Mgr:notify_died(carrier)
		end
	end)
	carrier.DiedConn = controller.Died:Connect(function()
		Mgr:notify_died(carrier)
	end)

	if body.AddNoCollisionPairWithUnit then
		pcall(body.AddNoCollisionPairWithUnit, body, receiver)
	end

	self.Carriers[body.UnitId] = carrier
	return carrier
end

---建一条鱼载体：鱼本体（WorldUnit + 官方鱼模型）+ 伤害接口
---@param opts Table { Position, Rotation, FishId, MaxHealth, RenderMeshId, ModelId, Mass, BodyType, GravityEnabled, LinearDamping, AngularDamping, ReceiverOffset, Player }
---@return Table? carrier, string? 失败原因
function Mgr:spawn(opts)
	opts = opts or {}
	local World = rawget(_G, "game") and game:GetService("World") or nil
	local createUnit = opts.CreateUnit or function(kind, props)
		return World and World:CreateUnit(kind, props) or nil
	end
	if not createUnit then
		return nil, "no-world"
	end
	local mesh = resolveMesh(opts)
	if not mesh then
		return nil, "no-mesh"
	end

	local cfg = GameCfg.FishCarrier or {}
	local species = GameCfg.Fish[opts.FishId]
	local tint = species and species.VisualColor
	Mgr.BodySeq = Mgr.BodySeq + 1
	local values = {
		Name = Mgr.BODY_NAME_PREFIX .. "_" .. tostring(Mgr.BodySeq) .. "_" .. tostring(opts.FishId or "unknown"),
		Position = opts.Position or Vector3.New(0, 0, 0),
		Rotation = opts.Rotation or Quaternion.FromEulerAngles(0, 0, 0),
		RenderMeshId = mesh,
		BodyType = opts.BodyType or 4,
		PhysicsActive = true,
		Liftable = true,
		Mass = opts.Mass or 10,
		GravityEnabled = opts.GravityEnabled,
	}
	if tint then values.ModelColor1 = Color.New(tint[1], tint[2], tint[3], tint[4]) end
	if opts.PhysicsMeshId then
		values.PhysicsMeshId = opts.PhysicsMeshId
	elseif cfg.PhysicsMeshId and cfg.PhysicsMeshId ~= "" then
		values.PhysicsMeshId = cfg.PhysicsMeshId
	end
	if values.GravityEnabled == nil then
		values.GravityEnabled = true
	end
	if opts.LinearDamping then
		values.LinearDamping = opts.LinearDamping
	end
	if opts.AngularDamping then
		values.AngularDamping = opts.AngularDamping
	end

	local body = createUnit("WorldUnit", values)
	if not body then
		return nil, "body-create-failed"
	end

	local carrier = self:attach(body, opts)
	if not carrier then
		pcall(function()
			body:Destroy()
		end)
		return nil, "receiver-create-failed"
	end
	return carrier
end

---单点造成的伤害；业务调用必须带 MgrVitals 颁发的命中身份
function Mgr:Damage(carrier, damage, hit)
	if not carrier or carrier.Dead or not carrier.Controller
		or type(hit) ~= 'table' or type(hit.id) ~= 'number' then
		return false
	end
	if not isPositiveNumber(damage) then
		return false
	end
	local beforeOk, before = pcall(function() return carrier.Controller.Health end)
	if not beforeOk or type(before) ~= 'number' then return false end
	local ok, err = pcall(function() carrier.Controller:TakeDamage(damage) end)
	if not ok then
		print('[FishCarrier] 受击扣血失败', carrier.Body and carrier.Body.UnitId, tostring(err))
		return false
	end
	self:record_health(carrier)
	local afterOk, after = pcall(function() return carrier.Controller.Health end)
	if not afterOk or type(after) ~= 'number' or after >= before then return false end
	if after <= 0 then self:notify_died(carrier) end
	local actual = before - after
	if self.damage_listener then
		local notified, notifyErr = pcall(self.damage_listener, carrier, actual, hit)
		if not notified then print('[FishCarrier] 有效伤害通知失败', carrier.Body and carrier.Body.UnitId, tostring(notifyErr)) end
	end
	return true, actual
end

function Mgr:despawn(carrier)
	if not carrier then
		return
	end
	if carrier.HealthConn then
		carrier.HealthConn:Disconnect()
	end
	if carrier.DiedConn then
		carrier.DiedConn:Disconnect()
	end
	if carrier.Body and carrier.Body.UnitId then
		self.Carriers[carrier.Body.UnitId] = nil
	end
	pcall(function()
		if carrier.Receiver then
			carrier.Receiver:Destroy()
		end
	end)
	pcall(function()
		if carrier.Body then
			carrier.Body:Destroy()
		end
	end)
	carrier.Body = nil
	carrier.Receiver = nil
	carrier.Controller = nil
end

function Mgr:start()
end

function Mgr:on_player_added(player)
end

function Mgr:on_player_removing(player)
end

function Mgr:update(deltaTime)
	for _, carrier in pairs(self.Carriers) do
		if carrier.SkipNextAutoSync then carrier.SkipNextAutoSync = nil
		else syncReceiver(carrier) end
	end
end

return Mgr
