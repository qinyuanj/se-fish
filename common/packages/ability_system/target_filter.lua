--技能系统 - common技能目标筛选系统
-- 双端共享，纯逻辑函数（不直接依赖 ScriptUnit/@type）

local TargetFilter = {}

---验证目标是否有效（3 层筛选：距离 → 类型 → Tag）
---@param handler table AbilityItem handler 引用（需暴露 getReleaseDistance/Point/etc + getOwner）
---@param target table 候选目标 Unit
---@param owner table 施法者 Unit
---@return boolean
function TargetFilter.isValidTarget(handler, target, owner)
	if not target or not owner then
		return false
	end

	-- 1. 距离校验
	local maxDist = handler.getReleaseDistance and handler.getReleaseDistance() or 10.0
	local ownerPos = owner.Position
	if ownerPos then
		local distVec = target.Position - ownerPos
		if distVec:Length() > maxDist then
			return false
		end
	end

	-- 2. 目标类型筛选 (TargetFilterType，数组多选，任一命中即通过)
	-- 兼容旧版单值 ""（按不筛选处理）
	local filterTypes = handler._getRawAttribute and handler._getRawAttribute("TargetFilterType")
		or nil
	local filterEntries = {}
	if type(filterTypes) == "table" then
		for _, filterType in ipairs(filterTypes) do
			if filterType ~= "" then
				table.insert(filterEntries, filterType)
			end
		end
	end
	if #filterEntries > 0 then
		local matched = false
		for _, filterType in ipairs(filterEntries) do
			if target:IsA(filterType) then
				matched = true
				break
			end
		end
		if not matched then
			return false
		end
	end

	-- 3a. 必须标签 (TargetRequiredTags)
	local requiredTags = handler._getRawAttribute and handler._getRawAttribute("TargetRequiredTags")
		or nil
	if requiredTags and type(requiredTags) == "table" and #requiredTags > 0 then
		for _, tag in ipairs(requiredTags) do
			if not target:HasTag(tag) then
				return false
			end
		end
	end

	-- 3b. 忽略标签 (TargetIgnoredTags)
	local ignoredTags = handler._getRawAttribute and handler._getRawAttribute("TargetIgnoredTags")
		or nil
	if ignoredTags and type(ignoredTags) == "table" and #ignoredTags > 0 then
		for _, tag in ipairs(ignoredTags) do
			if target:HasTag(tag) then
				return false
			end
		end
	end

	return true
end

---获取施法范围内有效目标（根据 PointerType 执行矩形 / 圆形 / 扇形区域查询）
---@param handler table AbilityItem handler 引用
---@param owner table 施法者 Unit
---@param height number 可选，查询高度（默认 10.0）
---@return table 有效目标列表
function TargetFilter.getValidTargetsInRange(handler, owner, height)
	height = height or 10.0
	local validTargets = {}
	if not owner then
		return validTargets
	end

	local World = game:GetService("World")
	local PhysicsService = game:GetService("PhysicsService")
	local pointerType = handler._getRawAttribute and handler._getRawAttribute("PointerType") or 0
	local releasePoint = handler.getReleasePoint and handler.getReleasePoint()
	local units = {}

	if pointerType == 1 then
		-- Rectangle 矩形
		local ownerPos = owner.Position
		local releaseDir = handler.getReleaseDirection and handler.getReleaseDirection()
			or Vector3.New(0, 0, 1)
		local length = handler._getRawAttribute and handler._getRawAttribute("ReleaseDistance")
			or 10.0
		local width = handler._getRawAttribute and handler._getRawAttribute("AffectWidth") or 1.0
		local center = ownerPos + releaseDir * (length * 0.5)
		local cf = CFrame.LookAlong(center, releaseDir, Vector3.New(0, 1, 0))
		units = PhysicsService:GetPartBoundsInBox(cf, Vector3.New(width, height, length))
	elseif pointerType == 2 then
		-- Circle 圆形
		local radius = handler._getRawAttribute and handler._getRawAttribute("ReleaseRadius") or 3.0
		units = PhysicsService:GetPartBoundsInRadius(releasePoint or owner.Position, radius)
	elseif pointerType == 3 then
		-- Sector 扇形
		local radius = handler._getRawAttribute and handler._getRawAttribute("ReleaseRadius") or 3.0
		local releaseDir = handler.getReleaseDirection and handler.getReleaseDirection()
			or Vector3.New(0, 0, 1)
		local centralAngle = handler._getRawAttribute and handler._getRawAttribute("SectorAngle")
			or 90.0
		local ownerPos = owner.Position
		local cosMin = math.cos(math.rad(centralAngle * 0.5))
		local dirLen = math.sqrt(releaseDir.x * releaseDir.x + releaseDir.y * releaseDir.y + releaseDir.z * releaseDir.z)
		units = {}
		if dirLen > 0 then
			local nx, ny, nz = releaseDir.x / dirLen, releaseDir.y / dirLen, releaseDir.z / dirLen
			for _, unit in ipairs(PhysicsService:GetPartBoundsInRadius(ownerPos, radius)) do
				local offset = unit.Position - ownerPos
				local len = math.sqrt(offset.x * offset.x + offset.y * offset.y + offset.z * offset.z)
				if len > 0 then
					local dot = (offset.x * nx + offset.y * ny + offset.z * nz) / len
					if dot >= cosMin then
						table.insert(units, unit)
					end
				end
			end
		end
	else
		-- None / Parabola: 不进行范围查询
		return validTargets
	end

	-- 逐项筛选
	for _, unit in ipairs(units or {}) do
		if unit ~= owner and TargetFilter.isValidTarget(handler, unit, owner) then
			table.insert(validTargets, unit)
		end
	end

	return validTargets
end

return TargetFilter
