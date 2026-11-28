
local SwingRegistry = require("server.swing_registry")
local HostSignal = require("common.host_signal")
local SpokeEggy = require("common.packages.spoke_eggy.api")

local M = { services = {} }

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

local function _applyDamage(target, damage, _owner, hit)
	if not damage or damage == 0.0 or not hit then
		return false
	end
	if M.services.FishCarrier:resolve_carrier(target) then
		return (M.services.Vitals:apply_hit(hit, target, damage))
	end
	local players = game:GetService("Players")
	local targetPlayer = players and players.GetPlayerFromCharacter and players:GetPlayerFromCharacter(target)
	if targetPlayer then
		return (M.services.Vitals:apply_hit(hit, targetPlayer, damage))
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

-- ===== 拆分前 M.Attach 体内的闭包：提到模块级，依赖显式传入 =====
-- 拆分前这些逻辑是 Attach 体内的 upvalue 闭包（捕获 anchor_script / state / swing_dock）；
-- 现在拆成模块级函数：run 是「每次挂接的运行期上下文」，state 是「每次挥砍的状态」，
-- 依赖一律显式传参。对外入口 M.Attach 的名字与签名不变，挂接顺序与拆分前一致。

local function new_run(anchor_script, swing_dock)
	return { anchor_script = anchor_script, swing_dock = swing_dock, state = nil }
end

-- 回收一次挥砍占用的进入连接、触发器与武器挂载（拆分前的 _cleanup）。
local function clear_run(run)
	run.swing_dock:drop("active")
	local state = run.state
	if not state then
		return
	end
	if state.enter_conn then
		pcall(function()
			state.enter_conn:Disconnect()
		end) -- 触发器或信号可能已先卸载
		state.enter_conn = nil
	end
	for _, field in ipairs({ "tu", "weapon_mount", "weapon_unit" }) do
		local unit = state[field]
		if unit and unit.UnitId then
			pcall(function()
				unit:Destroy()
			end)
		end
		state[field] = nil
	end
	run.state = nil
end

-- 锚点脚本 → ability_script → manager → owner，再解出挥砍玩家。
local function resolve_swing_owner(anchor_script)
	local ability_script = anchor_script.Parent
	local manager = ability_script and ability_script.Parent
	local owner = manager and manager.Parent
	if not owner or not owner.UnitId then
		return nil, nil
	end
	return owner, game:GetService("Players"):GetPlayerFromCharacter(owner)
end

-- 取玩家本次挥砍的服务端登记（射程/伤害/特效）；缺失时只播表现、不结算伤害。
local function take_swing(player)
	if not player then
		return nil
	end
	local swing = SwingRegistry.take_swing(player.UserId)
	if not swing then
		print("[melee_hit] 玩家挥砍缺少服务端登记，只播表现不结算伤害 uid=" .. tostring(player.UserId))
	end
	return swing
end

-- 命中盒参数：玩家挥砍按服务端登记覆盖；玩家无登记时返回 nil 表示中止本次结算。
local function resolve_hit_box(anchor_script, player, swing)
	local hit_box = {
		offset = anchor_script:GetAttribute("ABILITY_ANOSTATE_HITBOX_OFFSET") or Vector3.New(0, 1, 0),
		scale = _safeScale(anchor_script:GetAttribute("ABILITY_ANOSTATE_HITBOX_SCALE"), Vector3.New(2, 2, 2)),
		damage = anchor_script:GetAttribute("ABILITY_ANOSTATE_BULLET_DAMAGE") or 0.0,
	}
	if not player then
		return hit_box
	end
	if not swing then
		return nil
	end
	hit_box.offset = Vector3.New(0, 1, swing.range / 2)
	hit_box.scale = Vector3.New(2, 2, swing.range)
	hit_box.damage = swing.damage
	hit_box.effect = swing.effect
	return hit_box
end

-- 是否让命中盒跟随锚点朝向：属性缺省为同步朝向。
local function sync_facing_of(anchor_script)
	local sync_facing = anchor_script:GetAttribute("ABILITY_ANOSTATE_FACE_SYNC")
	if sync_facing == nil then
		return true
	end
	return sync_facing
end

-- 武器单位在挂载点上的可见性与碰撞设置：只有 ModelVisible 打开，其余逐项关闭（顺序沿用拆分前）。
local WEAPON_UNIT_FLAGS = { "ModelVisible", "PhysicsActive", "CanCollide", "CanTouch", "CanTrigger", "CanQuery" }

local function configure_weapon_unit(unit, scale)
	unit.Scale = scale
	for _, flag in ipairs(WEAPON_UNIT_FLAGS) do
		if unit[flag] ~= nil then
			unit[flag] = flag == "ModelVisible"
		end
	end
end

-- 按锚点属性生成武器挂载与武器单位（拆分前 weapon_prefab ~= "" 分支）。
local function spawn_weapon(anchor_script, owner, swing_seq, state)
	local prefab = anchor_script:GetAttribute("ABILITY_ANOSTATE_USE_PERFAB") or ""
	if prefab == "" then
		return
	end
	local World = game:GetService("World")
	local mount = World:CreateUnit("SkeletalSocketMount", {
		Name = "ToolMount_" .. tostring(owner.UnitId) .. "_" .. tostring(swing_seq),
		Parent = owner,
		SocketName = anchor_script:GetAttribute("ABILITY_ANOSTATE_BINDSOCKET") or "origin",
		SocketOffset = anchor_script:GetAttribute("ABILITY_ANOSTATE_OFFSET") or Vector3.New(0, 0, 0),
		SocketRotation = _eulerDegToQuat(anchor_script:GetAttribute("ABILITY_ANOSTATE_QUD")),
	})
	if not mount then
		print("[melee_hit] WARNING: CreateUnit SkeletalSocketMount failed")
		return
	end
	local assets = World:CreateAsset(prefab)
	if not assets or not assets[1] then
		pcall(function()
			mount:Destroy()
		end)
		print("[melee_hit] WARNING: CreateAsset failed:", prefab)
		return
	end
	local weapon_unit = assets[1]
	local bind_scale = _safeScale(anchor_script:GetAttribute("ABILITY_ANOSTATE_SCALE"), Vector3.New(1, 1, 1))
	weapon_unit.Parent = mount
	configure_weapon_unit(weapon_unit, bind_scale)
	state.weapon_unit = weapon_unit
	state.weapon_mount = mount
end

-- 播放挥砍动画（拆分前 anim_id ~= "" and owner.Animator 分支）。
local function play_swing_anim(owner, anim_id)
	if anim_id == "" or not owner.Animator then
		return
	end
	pcall(function()
		local track = owner.Animator:LoadAnimation(anim_id)
		if track then
			track.FilterType = 30
			track.Looped = false
			track:Play(0.05, 1, 1)
		end
	end)
end

-- 建命中触发盒：中心点解析失败或创建失败都返回 nil（拆分前两处提前 return）。
local function create_hit_box(owner, hit_box, swing_seq, sync_facing)
	local center, yaw = _getAreaTransform(owner, hit_box.offset, sync_facing)
	if not center then
		return nil
	end
	local tu = game:GetService("World"):CreateUnit("TriggerUnit", {
		PhysicsMeshId = TRIGGER_BOX_PREFAB_ID,
		Scale = hit_box.scale,
		Position = center,
		Rotation = Quaternion.FromEulerAngles(0, yaw, 0),
		Name = "MeleeHitBox_" .. tostring(owner.UnitId) .. "_" .. tostring(swing_seq),
	})
	if not tu then
		print("[melee_hit] WARNING: failed to create trigger unit")
		return nil
	end
	return tu
end

-- 一次挥砍的命中上下文：拆分前是 process_hit 闭包捕获的 upvalue（hit_map / hit_damage / state）。
local function new_hit(anchor_script, owner, player, state, hit_box)
	return {
		anchor_script = anchor_script,
		owner = owner,
		player = player,
		state = state,
		damage = hit_box.damage,
		power = anchor_script:GetAttribute("ABILITY_ANOSTATE_HITPOWER") or 0.0,
		hit_map = {},
	}
end

-- 过滤与去重：返回本次可结算的目标 ID；无效目标、自身、武器单位、重复命中返回 nil。
local function claim_target(hit, target)
	local state = hit.state
	if not target or not target.UnitId or not _isHittable(target) or _isSelf(target, hit.owner) then
		return nil
	end
	if state and state.weapon_unit and target == state.weapon_unit then
		return nil
	end
	if hit.hit_map[target.UnitId] then
		return nil
	end
	hit.hit_map[target.UnitId] = true
	return target.UnitId
end

-- 武器特效结算（拆分前 process_hit 内的 Modifier 分支）。
local function apply_weapon_effect(hit, target)
	local modifier = M.services.Modifier
	local player, state = hit.player, hit.state
	if not (player and state and state.effect and modifier and modifier.apply_weapon_effect) then
		return
	end
	local ok, err = pcall(modifier.apply_weapon_effect, modifier, player, target, state.effect)
	if not ok then
		print("[melee_hit] 武器特效应用失败", tostring(err))
	end
end

-- 结算单个目标：伤害、击退、命中特效与武器特效。
local function land_hit(hit, target, tid)
	if not _applyDamage(target, hit.damage, hit.owner, hit.state and hit.state.hit) then
		return
	end
	print("[melee_hit] 命中 uid=" .. tostring(hit.player and hit.player.UserId or hit.owner.UnitId),
		"target=" .. tostring(tid), "damage=" .. tostring(hit.damage))
	_applyHitPower(target, hit.power, hit.owner)
	_createHitSfx(hit.anchor_script, target)
	apply_weapon_effect(hit, target)
end

local function process_hit(hit, target)
	local tid = claim_target(hit, target)
	if tid then
		land_hit(hit, target, tid)
	end
end

-- 触碰进入：每次挥砍把 OnTriggerEnter 接进当前挥砍作用域（拆分前 swing_dock:effect）。
local function wire_hit_trigger(run, hit, tu)
	run.swing_dock:effect("active", function(swing_scope)
		hit.state.enter_conn = HostSignal.connect(swing_scope, tu.OnTriggerEnter, function(other_unit)
			process_hit(hit, other_unit)
		end)
	end)
end

-- 建盒当帧已在盒内的单位直接结算一次（拆分前 PhysicsService 扫描）。
local function scan_initial_hits(tu, hit)
	local physics = game:GetService("PhysicsService")
	if not physics or not physics.GetPartsInPart then
		return
	end
	local units = physics:GetPartsInPart(tu)
	if type(units) ~= "table" then
		return
	end
	for _, unit in ipairs(units) do
		process_hit(hit, unit)
	end
end

-- 一次挥砍：清理上一轮 → 解析登记 → 武器/动画/命中盒 → 触碰接线与初始扫描。
local function start_swing(run)
	clear_run(run)
	local state = {}
	run.state = state
	local anchor_script = run.anchor_script
	SwingSeq = SwingSeq + 1
	local swing_seq = SwingSeq
	local owner, player = resolve_swing_owner(anchor_script)
	if not owner then
		return
	end
	local swing = take_swing(player)
	if player and not swing then
		return
	end
	local hit_box = resolve_hit_box(anchor_script, player, swing)
	if not hit_box then
		return
	end
	if player then
		state.effect = hit_box.effect
		hit_box.damage = M.services.GM:get_melee_damage(player, hit_box.damage)
	end
	state.hit = M.services.Vitals:new_hit(player or owner, "weapon")
	spawn_weapon(anchor_script, owner, swing_seq, state)
	play_swing_anim(owner, anchor_script:GetAttribute("ABILITY_ANOSTATE_ANIMKEY") or "")
	local tu = create_hit_box(owner, hit_box, swing_seq, sync_facing_of(anchor_script))
	if not tu then
		return
	end
	state.tu = tu
	local hit = new_hit(anchor_script, owner, player, state, hit_box)
	wire_hit_trigger(run, hit, tu)
	scan_initial_hits(tu, hit)
end

function M.Attach(anchor_script, services)
	if services then M.services = services end
	for _, name in ipairs({ 'Vitals', 'FishCarrier', 'GM', 'Modifier' }) do
		assert(M.services[name], '[melee_hit] 缺少行为依赖: ' .. name)
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
		local run = new_run(anchor_script, scope:dock("MeleeSwing"))

		scope:on_cleanup(function()
			clear_run(run)
		end)
		HostSignal.connect(scope, start_sig, function()
			start_swing(run)
		end)

		for _, name in ipairs({ "AnchorEnd", "AnchorBreak", "AnchorStop" }) do
			local sig = anchor_script:FindFirstChild(name)
			if sig then
				HostSignal.connect(scope, sig, function()
					clear_run(run)
				end)
			end
		end
	end, { name = "melee_hit" })
end

return M
