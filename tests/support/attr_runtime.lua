-- 离线属性边界：驱动真实 AttrLeaf + AttrModel + BodyScale + 官方包 attr_rule.api，仅引擎单位与 World 为替身。
local AttrLeaf = require('server.World.AttrLeaf')
local Model = require('common.AttrModel')
local BodyScale = require('common.BodyScale')
local GameCfg = require('common.GameCfg')

local M = {}

function M.New(playerData, multiplier, opts)
    opts = type(opts) == 'table' and opts or {}
    local cache, all, prepared = {}, {}, {}
    local function prepare(unit, prefab)
        unit.attrs = unit.attrs or {}
        unit.GetAttribute = unit.GetAttribute or function(self, k) return self.attrs[k] end
        unit.SetAttribute = unit.SetAttribute or function(self, k, v) self.attrs[k] = v end
        if not prepared[unit] then
            prepared[unit] = true
            local original = unit.GetChildren
            unit.GetChildren = function(self)
                local children, seen = {}, {}
                for _, child in ipairs(original and original(self) or {}) do
                    children[#children + 1], seen[child] = child, true
                end
                for _, child in ipairs(all) do
                    if child.Parent == self and not seen[child] then children[#children + 1] = child end
                end
                return children
            end
        end
        unit.IsA = unit.IsA or function() return true end
        unit.FindFirstChildOfClass = unit.FindFirstChildOfClass or function(_, kind)
            if prefab and kind == 'PresetLink' then return { GetAttribute = function() return prefab end } end
        end
        unit.Destroy = unit.Destroy or function(self) self.Parent = nil self.destroyed = true end
        return unit
    end
    local world = { CreateAsset = function()
        local unit = prepare({}, 'AttrUnit')
        all[#all + 1] = unit
        return { unit }
    end }
    local env = setmetatable({
        game = { GetService = function() return world end },
        Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end },
    }, { __index = _G })
    env.require = function(name)
        if cache[name] then return cache[name] end
        cache[name] = assert(loadfile(name:gsub('%.', '/') .. '.lua', 't', env))()
        return cache[name]
    end

    local attrAPI = env.require('server.packages.attr_rule.api')
    local logFn = opts.log or print

    local mgr = {
        AttrAPI = attrAPI,
        States = {},
        PlayerData = playerData,
        MoveMultiplierProvider = multiplier,
    }

    function mgr:State(player)
        if player and player.Character then prepare(player.Character) end
        local state = self.States[player.UserId]
        if not state then
            state = { player = player }
            self.States[player.UserId] = state
        end
        if state.character ~= player.Character then
            if state.unit and state.owned then state.unit:Destroy() end
            state.character, state.unit, state.baseSpeed = player.Character, nil, nil
            state.owned = false
        end
        return state
    end

    function mgr:CaptureBaseSpeed(player)
        local state = self:State(player)
        if state.baseSpeed then return end
        local controller = state.character and state.character.Controller
        local speed = controller and controller.WalkSpeed
        state.baseSpeed = type(speed) == 'number' and speed > 0 and speed < math.huge and speed or GameCfg.Ability.MoveSpeed.Base
    end

    function mgr:Input(player)
        self:CaptureBaseSpeed(player)
        local data = self.PlayerData and self.PlayerData:GetDataInst(player)
        local mult = self.MoveMultiplierProvider and self.MoveMultiplierProvider(player) or 1
        return {
            bodyPotions = data and data:PotionCount(GameCfg.Ability.BodyScale.PotionItem) or 0,
            speedPotions = data and data:PotionCount(GameCfg.Ability.SpeedPotion.Item) or 0,
            baseSpeed = self:State(player).baseSpeed,
            moveMultiplier = mult,
        }
    end

    function mgr:Project(player, key, components)
        local state = self:State(player)
        if not state.character then return false, 'no-character' end
        local cfgOk, cfgErr = AttrLeaf.validate_config(self.AttrAPI, key)
        if not cfgOk then return false, cfgErr end
        if not state.unit then
            local okEx, existing = pcall(self.AttrAPI.Funcs.GetAttrUnit, state.character) -- 兼容测试注入 GetChildren 故障
            if not okEx then return false, tostring(existing) end
            local okEn, unit, err = pcall(self.AttrAPI.Funcs.EnsureAttrUnit, state.character) -- 兼容测试注入创建故障
            if not okEn or not unit then return false, tostring(okEn and err or unit) end
            state.unit, state.owned = unit, existing == nil
        end
        return AttrLeaf.project_components(self.AttrAPI, state.character, key, components)
    end

    function mgr:Plan(player)
        return Model.Plan(self:Input(player))
    end

    function mgr:BodyPlan(player)
        local plan = self:Plan(player)
        local ok, scale = self:Project(player, 'PlayerBodyScale', plan.Attributes.PlayerBodyScale)
        if not ok then return nil, scale end
        plan.Body.Scale = BodyScale.Sanitize(scale)
        return plan.Body
    end

    function mgr:MaxHealth(player)
        local plan = self:Plan(player)
        local ok, value = self:Project(player, 'PlayerMaxHealth', plan.Attributes.PlayerMaxHealth)
        if not ok then error('[AttrLeaf] 血量上限投影失败: ' .. tostring(value)) end
        return math.max(1, math.min(GameCfg.Ability.BodyScale.HealthMax, value))
    end

    function mgr:RefreshMoveSpeed(player)
        local plan = self:Plan(player)
        local ok, speed = self:Project(player, 'PlayerWalkSpeed', plan.Attributes.PlayerWalkSpeed)
        if not ok then return false, speed end
        local okWrite, err = AttrLeaf.apply_walk_speed(player.Character, speed)
        if not okWrite then
            logFn('[AttrLeaf] 移速写入失败', player.UserId, tostring(err))
            return false, tostring(err)
        end
        return true
    end

    function mgr:ApplyBodyScale(player)
        local plan, err = self:BodyPlan(player)
        if not plan then return { Ok = false, Error = err } end
        local ok, derivedOrErr = AttrLeaf.apply_body_presentation(player.Character, plan.Scale, plan.Capped)
        if not ok then logFn('[AttrLeaf] 体型写入失败', player.UserId, tostring(derivedOrErr)) end
        return {
            Ok = ok,
            Error = not ok and tostring(derivedOrErr) or nil,
            Scale = plan.Scale,
            Health = self:MaxHealth(player),
            Capped = plan.Capped,
            Derived = ok and derivedOrErr or BodyScale.Derive(plan.Scale),
        }
    end

    function mgr:ApplyGrowth(player)
        local applied = self:ApplyBodyScale(player)
        local errors = {}
        if not applied.Ok then errors[#errors + 1] = tostring(applied.Error) end
        if self.Vitals and (not self.Vitals.GetState or self.Vitals:GetState(player)) then
            local called, ok, err = pcall(self.Vitals.RefreshMaxHealth, self.Vitals, player) -- 隔离测试替身 Vitals 异常
            if not called or not ok then errors[#errors + 1] = 'MaxHealth:' .. tostring(called and err or ok) end
        end
        local ok, err = self:RefreshMoveSpeed(player)
        if not ok then errors[#errors + 1] = tostring(err) end
        applied.Ok = #errors == 0
        if not applied.Ok then applied.Error = table.concat(errors, '; ') end
        return applied
    end

    function mgr:ProjectHunger(player, value)
        local ok, result = self:Project(player, 'PlayerHunger', Model.Plan({ hunger = value }).Attributes.PlayerHunger)
        if not ok then return false, result end
        return true, math.max(0, math.min(GameCfg.Vitals.MaxHunger, math.floor(result)))
    end

    function mgr:WeaponDamageScale(player, kind)
        if kind ~= 'melee' and kind ~= 'ranged' and kind ~= 'explosive' then return 1 end
        local data = self.PlayerData and self.PlayerData:GetDataInst(player)
        local components = Model.WeaponComponents(kind, data and data:ShopUpgradeLevel(kind) or 0)
        local ok, result = self:Project(player, 'PlayerWeaponDamage_' .. kind, components)
        if not ok then error('[AttrLeaf] 武器属性投影失败: ' .. tostring(result)) end
        return result
    end

    function mgr:RefreshAfterRevive(player)
        local ok, result = pcall(self.ApplyGrowth, self, player) -- 兼容复活时角色未就绪
        if not ok or not result.Ok then
            self:State(player).pending = true
            logFn('[AttrLeaf] 复活属性待重试', player.UserId, tostring(ok and result.Error or result))
            return false
        end
        return true
    end

    function mgr:OnPlayerAdded(player)
        local ok, err = pcall(self.ApplyGrowth, self, player) -- 兼容入图时角色未就绪
        if not ok or not err.Ok then
            logFn('[AttrLeaf] 初始化待重试', player.UserId, tostring(ok and err.Error or err))
            self:State(player).pending = true
        end
    end

    function mgr:OnPlayerRemoving(player)
        local state = self.States[player.UserId]
        if not state then return end
        if state.unit and state.owned then state.unit:Destroy() end
        self.States[player.UserId] = nil
    end

    function mgr:Update()
        for _, state in pairs(self.States) do
            if state.pending then
                local ok, result = pcall(self.ApplyGrowth, self, state.player) -- 隔离重试异常，仅在错误变化时记录
                if ok and type(result) == 'table' and result.Ok then
                    state.pending, state.lastError = nil, nil
                else
                    local reason = tostring(ok and type(result) == 'table' and result.Error or result)
                    if state.lastError ~= reason then
                        logFn('[AttrLeaf] 属性重试失败', state.player.UserId, reason)
                        state.lastError = reason
                    end
                end
            end
        end
    end

    function mgr:Start() end
    return mgr, world, all
end

return M
