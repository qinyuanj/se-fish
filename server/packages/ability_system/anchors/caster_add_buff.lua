--技能系统 - server锚点逻辑：caster_add_buff（Constant：施法者添加效果，EffectDuration 独立配置）
-- 语义：点火时按属性读效果预设，给施法者添加效果（modifier_system 包），持续时间使用独立参数 EffectDuration；
-- 锚点 Duration 只控制锚点排程，不参与效果时长。
-- 效果生命周期交由效果系统管理（到期自灭，叠加/覆盖语义由效果预设配置决定），锚点结束/打断不主动移除。
-- 效果系统为地图可选依赖：未导入时软失败（打印并跳过），不阻断锚点框架。

local M = {}

function M.Attach(anchor_script)
	local RunService = game:GetService("RunService")
	if not RunService:IsServer() then
		return
	end
	local ok_api, api = pcall(require, "server.packages.modifier_system.api")
	if not ok_api then
		print("[caster_add_buff] modifier_system package unavailable, skip: " .. tostring(api))
		return
	end
	local CreateResult = api.Enums.CreateResult
	local start_sig = anchor_script:FindFirstChild("AnchorStart")
	if not start_sig then
		return
	end
	start_sig:Connect(function()
		local ability_script = anchor_script.Parent
		local manager = ability_script and ability_script.Parent
		local owner = manager and manager.Parent
		local asset_id = anchor_script:GetAttribute("ABILITY_ANOSTATE_NEW_BUFF")
		if not owner or not asset_id or asset_id == "" then
			print("[caster_add_buff] BEGIN: owner or modifier preset missing, skip")
			return
		end
		local add_config = { source = owner }
		-- 效果持续时间使用独立参数 EffectDuration，与锚点 Duration 解耦；<=0 时回落效果预设自身默认时长
		local duration = anchor_script:GetAttribute("EffectDuration")
		if duration and duration > 0 then
			add_config.duration = duration
		else
			print("[caster_add_buff] EffectDuration <= 0, fallback to preset duration")
		end
		local ok_call, result = pcall(function()
			return api.AddModifier(owner, asset_id, add_config)
		end)
		if not ok_call then
			print("[caster_add_buff] AddModifier err: " .. tostring(result))
			return
		end
		if result ~= CreateResult.Added and result ~= CreateResult.Reobtained then
			print("[caster_add_buff] AddModifier not applied: " .. tostring(result))
		end
	end)
end

return M
