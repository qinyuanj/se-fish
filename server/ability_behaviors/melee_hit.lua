
local SwingRegistry = require("server.swing_registry")
local HostSignal = require("common.host_signal")
local SpokeEggy = require("common.packages.spoke_eggy.api")

local M = { Services = {} }

local SwingSeq = 0

local TRIGGER_BOX_PREFAB_ID = 57450
local HIT_SFX_LIFETIME = 1.0
local HITTABLE_UNIT_TYPES = {
	EggyUnit = true,
	HumanUnit = true,
	pet_unit = true,
	PhysicsUnit = true,
}

local function _getPosition(unit)
	if not unit then
		return nil
	end
	if unit.GetPosition then
		return unit:GetPosition()
	end
	return unit.Position
end

local function _getYaw(unit)
	if not unit then
		return 0.0
	end
	if unit.GetYaw then
		return unit:GetYaw() or 0.0
	end
	return 0.0
end

local function _rotateYaw(vec, yaw)
	local c = math.cos(yaw)
	local s = math.sin(yaw)
	return Vector3.New(vec.x * c + vec.z * s, vec.y, -vec.x * s + vec.z * c)
end

local function _getAreaTransform(owner, offset, sync_facing)
	local owner_pos = _getPosition(owner)
	if not owner_pos then
		return nil, 0.0
	end
	local yaw = 0.0
	if sync_facing then
		yaw = _getYaw(owner)
	end
	return owner_pos + _rotateYaw(offset, yaw), yaw
end

local function _safeScale(scale, fallback)
	if not scale then
		return fallback
	end
	if scale.x <= 0.0 or scale.y <= 0.0 or scale.z <= 0.0 then
		return fallback
	end
	return scale
end

local function _eulerDegToQuat(v)
	if not v then
		return Quaternion.FromEulerAngles(0, 0, 0)
	end
	return Quaternion.FromEulerAngles(math.rad(v.x), math.rad(v.y), math.rad(v.z))
end

local function _isHittable(unit)
	if not unit then
		return false
	end
	local ut = unit.UnitType
	if ut ~= nil then
		if HITTABLE_UNIT_TYPES[ut] == true then
			return true
		end
		if ut == "WorldUnit" then
			return unit.PhysicsActive == true
		end
		return false
	end
	return unit.Controller ~= nil
end

local function _isSelf(unit, owner)
	if unit == owner then
		return true
	end
	if not owner then
		return false
	end
	if owner.UnitId and unit.UnitId and owner.UnitId == unit.UnitId then
		return true
	end
	return false
end

local function _applyDamage(target, damage, owner, hit)
	if not damage or damage == 0.0 or not hit then
		return false
	end
	if M.Services.FishCarrier:resolve_carrier(target) then
		return (M.Services.Vitals:apply_hit(hit, target, damage))
	end
	local players = game:GetService("Players")
	local targetPlayer = players and players.GetPlayerFromCharacter and players:GetPlayerFromCharacter(target)
	if targetPlayer then
		return (M.Services.Vitals:apply_hit(hit, targetPlayer, damage))
	end
	return false
end

local function _applyHitPower(target, power, owner)
	if not power or power == 0.0 then
		return
	end
	local owner_pos = _getPosition(owner)
	local target_pos = _getPosition(target)
	if not owner_pos or not target_pos then
		return
	end
	local dx = target_pos.x - owner_pos.x
	local dz = target_pos.z - owner_pos.z
	local len = math.sqrt(dx * dx + dz * dz)
	local dir
	if len < 0.0001 then
		local yaw = _getYaw(owner)
		dir = Vector3.New(math.sin(yaw), 0.0, math.cos(yaw))
	else
		dir = Vector3.New(dx / len, 0.0, dz / len)
	end
	local force = Vector3.New(dir.x * power, power, dir.z * power)

	local ctrl = target.Controller
	if ctrl and ctrl.ApplyForce then
		ctrl:ApplyForce(force)
		return
	end
	if target.ApplyImpulse then
		target:ApplyImpulse(force)
		return
	end
	if target.ApplyForceToCenterOfMass then
		target:ApplyForceToCenterOfMass(force)
	end
end

local function _createHitSfx(anchor_script, target)
	local prefab = anchor_script:GetAttribute("ABILITY_ANOSTATE_HIT_SFX")
	if not prefab or prefab == "" then
		return
	end
	local pos = _getPosition(target)
	if not pos then
		return
	end
	local scale =
		_safeScale(anchor_script:GetAttribute("ABILITY_ANOSTATE_HIT_SFX_SCALE"), Vector3.New(1, 1, 1))
	local rotation = _eulerDegToQuat(anchor_script:GetAttribute("ABILITY_ANOSTATE_HIT_SFX_ROTATION"))
	local offset =
		anchor_script:GetAttribute("ABILITY_ANOSTATE_BULLET_HITSFXOFFSET") or Vector3.New(0, 0, 0)
	local units = game:GetService("World"):LoadUnitAssetByRPS(prefab, pos + offset, rotation, scale)
	if units and units[1] then
		local sfx = units[1]
		game:GetService("TimerService"):CreateTimer(1, HIT_SFX_LIFETIME, false, function()
			pcall(function()
				sfx:Destroy()
			end)
		end)
	end
end

function M.Attach(anchor_script, services)
	if services then M.Services = services end
	for _, name in ipairs({ 'Vitals', 'FishCarrier', 'GM', 'Modifier' }) do
		assert(M.Services[name], '[melee_hit] 缺少行为依赖: ' .. name)
	end
	local RunService = game:GetService("RunService")
	if not RunService:IsServer() then
		return
	end
	if (anchor_script:GetAttribute("Duration") or 0) <= 0 then
		print("[melee_hit] WARNING: Duration 必须 > 0（命中盒随锚点生命周期回收）")
		return
	end
	local start_sig = anchor_script:FindFirstChild("AnchorStart")
	if not start_sig then
		return
	end

	return SpokeEggy.behaviour(anchor_script, function(scope)
	local state = nil
	local swing_dock = scope:dock("MeleeSwing")

	local function _cleanup()
		swing_dock:drop("active")
		if not state then
			return
		end
		if state.enter_conn then
			pcall(function()
				state.enter_conn:Disconnect()
			end) -- 触发器或信号可能已先卸载
			state.enter_conn = nil
		end
		if state.tu and state.tu.UnitId then
			pcall(function()
				state.tu:Destroy()
			end)
		end
		state.tu = nil
		if state.weapon_mount and state.weapon_mount.UnitId then
			pcall(function()
				state.weapon_mount:Destroy()
			end)
		end
		state.weapon_mount = nil
		if state.weapon_unit and state.weapon_unit.UnitId then
			pcall(function()
				state.weapon_unit:Destroy()
			end)
		end
		state.weapon_unit = nil
		state = nil
	end

	scope:on_cleanup(_cleanup)
	HostSignal.connect(scope, start_sig, function()
		_cleanup()
		state = {}
		SwingSeq = SwingSeq + 1
		local swing_seq = SwingSeq
		local ability_script = anchor_script.Parent
		local manager = ability_script and ability_script.Parent
		local owner = manager and manager.Parent
		if not owner or not owner.UnitId then
			return
		end

		local player = game:GetService("Players"):GetPlayerFromCharacter(owner)
		local swing = nil
		if player then
			swing = SwingRegistry.take_swing(player.UserId)
			if not swing then
				print("[melee_hit] 玩家挥砍缺少服务端登记，只播表现不结算伤害 uid=" .. tostring(player.UserId))
			end
		end

		local hit_box_offset = anchor_script:GetAttribute("ABILITY_ANOSTATE_HITBOX_OFFSET")
			or Vector3.New(0, 1, 0)
		local hit_box_scale =
			_safeScale(anchor_script:GetAttribute("ABILITY_ANOSTATE_HITBOX_SCALE"), Vector3.New(2, 2, 2))
		local hit_damage = anchor_script:GetAttribute("ABILITY_ANOSTATE_BULLET_DAMAGE") or 0.0
		if player then
			if not swing then
				return
			end
			hit_box_offset = Vector3.New(0, 1, swing.range / 2)
			hit_box_scale = Vector3.New(2, 2, swing.range)
			hit_damage = swing.damage
			state.effect = swing.effect
		end
		if player then
			hit_damage = M.Services.GM:get_melee_damage(player, hit_damage)
		end
		state.hit = M.Services.Vitals:new_hit(player or owner, "weapon")
		local hit_power = anchor_script:GetAttribute("ABILITY_ANOSTATE_HITPOWER") or 0.0
		local weapon_prefab = anchor_script:GetAttribute("ABILITY_ANOSTATE_USE_PERFAB") or ""
		local anim_id = anchor_script:GetAttribute("ABILITY_ANOSTATE_ANIMKEY") or ""
		local bind_socket = anchor_script:GetAttribute("ABILITY_ANOSTATE_BINDSOCKET") or "origin"
		local bind_offset = anchor_script:GetAttribute("ABILITY_ANOSTATE_OFFSET") or Vector3.New(0, 0, 0)
		local bind_rotation = _eulerDegToQuat(anchor_script:GetAttribute("ABILITY_ANOSTATE_QUD"))
		local bind_scale =
			_safeScale(anchor_script:GetAttribute("ABILITY_ANOSTATE_SCALE"), Vector3.New(1, 1, 1))
		local sync_facing = anchor_script:GetAttribute("ABILITY_ANOSTATE_FACE_SYNC")
		if sync_facing == nil then
			sync_facing = true
		end

		local World = game:GetService("World")

		if weapon_prefab ~= "" then
			local weapon_mount = World:CreateUnit("SkeletalSocketMount", {
				Name = "ToolMount_" .. tostring(owner.UnitId) .. "_" .. tostring(swing_seq),
				Parent = owner,
				SocketName = bind_socket,
				SocketOffset = bind_offset,
				SocketRotation = bind_rotation,
			})
			if weapon_mount then
				local assets = World:CreateAsset(weapon_prefab)
				if assets and assets[1] then
					local weapon_unit = assets[1]
					weapon_unit.Parent = weapon_mount
					weapon_unit.Scale = bind_scale
					if weapon_unit.ModelVisible ~= nil then
						weapon_unit.ModelVisible = true
					end
					if weapon_unit.PhysicsActive ~= nil then
						weapon_unit.PhysicsActive = false
					end
					if weapon_unit.CanCollide ~= nil then
						weapon_unit.CanCollide = false
					end
					if weapon_unit.CanTouch ~= nil then
						weapon_unit.CanTouch = false
					end
					if weapon_unit.CanTrigger ~= nil then
						weapon_unit.CanTrigger = false
					end
					if weapon_unit.CanQuery ~= nil then
						weapon_unit.CanQuery = false
					end
					state.weapon_unit = weapon_unit
					state.weapon_mount = weapon_mount
				else
					pcall(function()
						weapon_mount:Destroy()
					end)
					print("[melee_hit] WARNING: CreateAsset failed:", weapon_prefab)
				end
			else
				print("[melee_hit] WARNING: CreateUnit SkeletalSocketMount failed")
			end
		end

		if anim_id ~= "" and owner.Animator then
			pcall(function()
					local track = owner.Animator:LoadAnimation(anim_id)
					if track then
						track.FilterType = 30
						track.Looped = false
						track:Play(0.05, 1, 1)
				end
			end)
		end

		local hit_map = {}
		local center, yaw = _getAreaTransform(owner, hit_box_offset, sync_facing)
		if not center then
			return
		end
		local tu = World:CreateUnit("TriggerUnit", {
			PhysicsMeshId = TRIGGER_BOX_PREFAB_ID,
			Scale = hit_box_scale,
			Position = center,
			Rotation = Quaternion.FromEulerAngles(0, yaw, 0),
			Name = "MeleeHitBox_" .. tostring(owner.UnitId) .. "_" .. tostring(swing_seq),
		})
		if not tu then
			print("[melee_hit] WARNING: failed to create trigger unit")
			return
		end
		state.tu = tu

		local function process_hit(target)
			if not target or not target.UnitId then
				return
			end
			if not _isHittable(target) then
				return
			end
			if _isSelf(target, owner) then
				return
			end
			if state and state.weapon_unit and target == state.weapon_unit then
				return
			end
			local tid = target.UnitId
			if tid and hit_map[tid] then
				return
			end
			if tid then
				hit_map[tid] = true
			end
			if _applyDamage(target, hit_damage, owner, state and state.hit) then
				print("[melee_hit] 命中 uid=" .. tostring(player and player.UserId or owner.UnitId),
					"target=" .. tostring(tid), "damage=" .. tostring(hit_damage))
				_applyHitPower(target, hit_power, owner)
				_createHitSfx(anchor_script, target)
				local modifier = M.Services.Modifier
				if player and state and state.effect and modifier and modifier.apply_weapon_effect then
					local ok, err = pcall(modifier.apply_weapon_effect, modifier, player, target, state.effect)
					if not ok then print("[melee_hit] 武器特效应用失败", tostring(err)) end
				end
			end
		end

		swing_dock:effect("active", function(swing_scope)
			state.enter_conn = HostSignal.connect(swing_scope, tu.OnTriggerEnter, function(other_unit)
				process_hit(other_unit)
			end)
		end)

		local Physics = game:GetService("PhysicsService")
		if Physics and Physics.GetPartsInPart then
			local init_units = Physics:GetPartsInPart(tu)
			if init_units and type(init_units) == "table" then
				for _, u in ipairs(init_units) do
					process_hit(u)
				end
			end
		end
	end)

	for _, name in ipairs({ "AnchorEnd", "AnchorBreak", "AnchorStop" }) do
		local sig = anchor_script:FindFirstChild(name)
		if sig then
			HostSignal.connect(scope, sig, _cleanup)
		end
	end
	end, { name = "melee_hit" })
end

return M
