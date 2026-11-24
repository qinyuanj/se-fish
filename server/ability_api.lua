local ability_package_api = require("server.packages.ability_system.api")
local ability_api = { BehaviorServices = {} }

local packageCastAbility = ability_package_api.CastAbility
local castGuard
local extraGuards = {}
function ability_api.AddCastGuard(guard)
	if type(guard) ~= 'function' then error('[ability_api] CastGuard 必须是函数', 2) end
	extraGuards[#extraGuards + 1] = guard
end
function ability_api.SetCastGuard(guard)
    if guard ~= nil and type(guard) ~= 'function' then error('[ability_api] CastGuard 必须是函数', 2) end
    castGuard = guard
end
function ability_api.CastAbility(unit, abilityIndex, releasePoint, releaseDir, releaseTarget)
    if castGuard then
        local ok, allowed = pcall(castGuard, unit, abilityIndex)
        if not ok then print('[ability_api] 施法守卫失败', tostring(allowed)) end
        if not ok or allowed ~= true then return false end
    end
    for _, guard in ipairs(extraGuards) do
        local ok, allowed = pcall(guard, unit, abilityIndex)
        if not ok then print('[ability_api] 追加施法守卫失败', tostring(allowed)) end
        if not ok or allowed ~= true then return false end
    end
    return packageCastAbility(unit, abilityIndex, releasePoint, releaseDir, releaseTarget)
end

local body_scale = require("common.body_scale")
local carry_mount = require("common.carry_mount")

function ability_api.SetBodyScale(unit, factor)
	if not unit then return { Ok = false, Error = 'no-unit' } end
	local scale = body_scale.Sanitize(factor)
	if type(unit.SetScale) ~= 'function' then return { Ok = false, Error = 'no-set-scale', Scale = scale } end
	local ok, err = pcall(unit.SetScale, unit, Vector3.New(scale, scale, scale))
	if not ok then
		print('[ability_api] SetScale 失败', tostring(err))
		return { Ok = false, Error = tostring(err), Scale = scale }
	end
	return { Ok = true, Scale = scale, Derived = body_scale.Derive(scale) }
end

---挂点附着的落地接口：在宿主下建 SkeletalSocketMount。
---@param world any World 服务（业务侧注入，便于测试与复用）
---@param unit? any 被携带的单位（nil 表示只建挂点）
---@param host any 宿主单位（挂点的 Parent）
---@param socketName string 骨骼挂点名
---@param offset? table { x, y, z } 已净化的挂点位移
---@param rotation? any Quaternion 挂点旋转（缺省不写该字段，用预设默认）
---@return table { Ok, Mount?, Offset?, Error? }
function ability_api.AttachToSocket(world, unit, host, socketName, offset, rotation)
	if not host then return { Ok = false, Error = 'no-host' } end
	if type(socketName) ~= 'string' or socketName == '' then return { Ok = false, Error = 'no-socket' } end
	world = world or game:GetService('World')
	local pos = carry_mount.SafeOffset(offset or { x = 0, y = 0, z = 0 }, 0, 0).Offset
	local options = {
		Name = 'carry_mount_' .. tostring(host.Name or 'host'),
		Parent = host,
		SocketName = socketName,
		SocketOffset = Vector3.New(pos.x, pos.y, pos.z),
	}
	if rotation ~= nil then options.SocketRotation = rotation end
	local ok, mount = pcall(world.CreateUnit, world, 'SkeletalSocketMount', options)
	if not ok or not mount then
		print('[ability_api] 挂点创建失败', tostring(mount))
		return { Ok = false, Error = tostring(mount) }
	end
	if unit ~= nil then
		local parentOk, parentErr = pcall(function() unit.Parent = mount end)
		if not parentOk then
			pcall(function() mount:Destroy() end)
			print('[ability_api] 挂点挂载失败', tostring(parentErr))
			return { Ok = false, Error = tostring(parentErr) }
		end
	end
	return { Ok = true, Mount = mount, Offset = pos }
end

---@return boolean
function ability_api.DetachFromSocket(mount)
	if not mount then return false end
	local ok = pcall(function()
		if mount.Parent then mount.Parent = nil end
		mount:Destroy()
	end)
	if not ok then print('[ability_api] 挂点销毁失败') end
	return ok
end

local AnchorBehaviorLoaders = {
	eel_discharge = function() return require("server.ability_behaviors.eel_discharge") end,
	melee_hit = function() return require("server.ability_behaviors.melee_hit") end,
	active_cd = function() return require("server.packages.ability_system.anchors.active_cd") end,
	add_bind_diy_model = function() return require("server.packages.ability_system.anchors.add_bind_diy_model") end,
	bungee_cord = function() return require("server.packages.ability_system.anchors.bungee_cord") end,
	cast_face_target = function() return require("server.packages.ability_system.anchors.cast_face_target") end,
	caster_add_buff = function() return require("server.packages.ability_system.anchors.caster_add_buff") end,
	create_bullet_to_castangle = function() return require("server.packages.ability_system.anchors.create_bullet_to_castangle") end,
	create_landmine = function() return require("server.packages.ability_system.anchors.create_landmine") end,
	create_obstacle = function() return require("server.packages.ability_system.anchors.create_obstacle") end,
	create_teleportball = function() return require("server.packages.ability_system.anchors.create_teleportball") end,
	custom_event = function() return require("server.packages.ability_system.anchors.custom_event") end,
	destroy_ability = function() return require("server.packages.ability_system.anchors.destroy_ability") end,
	gravity_change = function() return require("server.packages.ability_system.anchors.gravity_change") end,
	play_body_animation = function() return require("server.packages.ability_system.anchors.play_body_animation") end,
	play_sfx = function() return require("server.packages.ability_system.anchors.play_sfx") end,
	play_vfx = function() return require("server.packages.ability_system.anchors.play_vfx") end,
	speed_add = function() return require("server.packages.ability_system.anchors.speed_add") end,
}

---把锚点单位挂到技能单位下（锚点应先 parent 到技能单位）
---@param anchorScript Script 锚点脚本单位
---@param behaviorModule string 锚点行为名（AnchorBehaviorLoaders 的键，如 "melee_hit"）
---@return boolean 是否已挂接
function ability_api.AttachAnchor(anchorScript, behaviorModule)
	if not anchorScript then
		return false
	end

	require("server.packages.ability_system.anchor_logic").Attach(anchorScript)

	if behaviorModule and behaviorModule ~= "" then
		local loadBehavior = AnchorBehaviorLoaders[behaviorModule]
		local behavior = loadBehavior and loadBehavior()
		if type(behavior) ~= "table" or type(behavior.Attach) ~= "function" then
			error("[ability_api] 锚点行为模块不可用: " .. tostring(behaviorModule), 2)
		end
		behavior.Attach(anchorScript, ability_api.BehaviorServices)
	end

	return true
end

return ability_api
