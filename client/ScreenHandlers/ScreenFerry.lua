local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')
local Util = require('common.Util')

local Bubble = require('client.InteractionBubble')

local World = game:GetService('World')
local Players = game:GetService('Players')

local ScreenFerry = { Seq = 0, Legs = {}, Countdowns = {}, CountdownOperations = {} }

local COUNTDOWN_OWNER = {}
ScreenFerry.CountdownOwner = COUNTDOWN_OWNER

local COUNTDOWN_RETRY_INTERVAL = 5

local function notice(msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

function ScreenFerry:ZoneName(routeId, action)
    local route = GameCfg.Ferry.Route(routeId)
    if not route then return '目的地' end
    local zoneId = action == 'Return' and route.FromZoneId or route.ToZoneId
    for _, zone in ipairs(GameCfg.Zones) do
        if zone.Id == zoneId then return zone.Name end
    end
    return zoneId
end

function ScreenFerry:Send(action, routeId)
    self.Seq = self.Seq + 1
    REUtil:GetRE('FerryAction'):FireServer({ action = action, routeId = routeId, seq = self.Seq })
end

function ScreenFerry:CreateLeg(key, routeId, legCfg, action, buttonText)
    local anchor = Util:WaitForChild(World, legCfg.AnchorName)
    local player = Players.LocalPlayer
    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager
    if not anchor or not eui then
        print('[ScreenFerry] 摆渡锚点或 EUI 未就绪', legCfg.AnchorName)
        return
    end
    local center = anchor.Position
    local ok, node = pcall(eui.CreateSceneNodeAtPosition, eui,
        Vector3.New(center.x, center.y + legCfg.BubbleHeight, center.z))
    if not ok or not node then
        print('[ScreenFerry] 文字泡创建失败', legCfg.AnchorName, tostring(node))
        return
    end
    Bubble.CreateButton(node, 'BtnFerry' .. legCfg.AnchorName, buttonText, 0,
        function() self:Send(action, routeId) end)
    node.Visible = false
    self.Legs[key] = { Node = node, Center = center, Radius = legCfg.Radius, Visible = false }
end

function ScreenFerry:UpdateLegs()
    local character = Players.LocalPlayer and Players.LocalPlayer.Character
    local pos = character and character.Position
    for _, leg in pairs(self.Legs) do
        local visible = false
        if pos then
            local dx, dz = pos.x - leg.Center.x, pos.z - leg.Center.z
            local radius = BodyScale.InteractionRadius(character, leg.Radius)
            visible = dx * dx + dz * dz <= radius * radius
        end
        if leg.Visible ~= visible then
            leg.Visible = visible
            pcall(function() leg.Node.Visible = visible end)
        end
    end
end

function ScreenFerry:ShowCountdown()
    if self.CountdownLabel then return self.CountdownLabel end
    if (self.CountdownRetryIn or 0) > 0 then return nil end
    local eui = Players.LocalPlayer and Players.LocalPlayer.PlayerGui
        and Players.LocalPlayer.PlayerGui.EuiManager
    local root = eui and eui:GetRootNode()
    if not root then return nil end
    local resolution = eui:GetDeviceResolution()
    local ok, label = pcall(World.CreateUnit, World, 'EUITextLabel', {
        Parent = root, Name = 'FerryCountdown',
        Position = Vector2.New(resolution.x / 2, resolution.y - 120),
        Size = Vector2.New(360, 60), Text = '', FontSize = 36,
        TextColor = Color.New(255, 255, 255, 255),
    })
    if not ok or not label then
        print('[ScreenFerry] 倒计时条创建失败，' .. COUNTDOWN_RETRY_INTERVAL .. ' 秒后重试', tostring(label))
        self.CountdownRetryIn = COUNTDOWN_RETRY_INTERVAL
        return nil
    end
    label.Visible = false
    label.TouchEnabled = false
    label.SwallowTouchEnabled = false
    self.CountdownLabel = OwnedUnits.Track(COUNTDOWN_OWNER, label)
    return self.CountdownLabel
end

function ScreenFerry:HideCountdown()
    if not self.CountdownLabel then return end
    local label = self.CountdownLabel
    self.CountdownLabel = nil
    pcall(function() label.Visible = false end)
    OwnedUnits.Clear(COUNTDOWN_OWNER)
end

function ScreenFerry:UpdateCountdown(dt)
    local step = type(dt) == 'number' and dt or 0
    if self.CountdownRetryIn then
        self.CountdownRetryIn = self.CountdownRetryIn - step
        if self.CountdownRetryIn <= 0 then self.CountdownRetryIn = nil end
    end
    local soonest, soonestLeft
    for routeId, left in pairs(self.Countdowns) do
        local remaining = left - step
        if remaining <= 0 then
            self.Countdowns[routeId] = nil
            self.CountdownOperations[routeId] = nil
        else
            self.Countdowns[routeId] = remaining
            if not soonestLeft or remaining < soonestLeft then soonest, soonestLeft = routeId, remaining end
        end
    end
    if not soonest then
        self:HideCountdown()
        return
    end
    local label = self:ShowCountdown()
    if not label then return end
    pcall(function()
        label.Visible = true
        label.Text = string.format('前往%s %d 秒', self:ZoneName(soonest), math.ceil(soonestLeft))
    end)
end

function ScreenFerry:OnState(state)
    if type(state) ~= 'table' then return end
    local routeId = state.routeId
    if type(routeId) ~= 'string' then
        print('[ScreenFerry] 摆渡状态缺少航线 id，忽略', tostring(state.phase))
        return
    end
    if state.phase == 'countdown' then
        self.Countdowns[routeId] = tonumber(state.seconds) or 5
        self.CountdownOperations[routeId] = state.operation
    elseif state.phase == 'departed' or state.phase == 'cancelled' then
        if self.CountdownOperations[routeId] ~= state.operation then return end
        self.Countdowns[routeId] = nil
        self.CountdownOperations[routeId] = nil
    end
end

function ScreenFerry:OnResult(result)
    if type(result) ~= 'table' then return end
    if result.ok then
        if result.action == 'Board' then
            if result.seconds == nil then
                notice('已经到' .. self:ZoneName(result.routeId) .. '了')
            else
                notice('船票已交，' .. tostring(result.seconds) .. ' 秒后开船')
            end
        elseif result.action == 'Return' then
            notice('已经回到' .. self:ZoneName(result.routeId, 'Return') .. '，金币 -' .. tostring(result.price))
        end
        return
    end
    local reasons = {
        route = '找不到这条航线，请重进本图',
        ticket = '需要本区船票（本区首领信物喂钓鱼佬可换）',
        coin = '金币不够，船家不开船',
        range = '离船太远了',
        sailing = '这条航线已经在倒计时了，等下一班',
        pending = '上一趟摆渡还没结清，稍后再试',
        teleport = result.action == 'Board' and '传送失败，船票已退' or '传送失败，金币已退',
        not_aboard = '没赶上船，船票已退',
        anchor = '航班取消，船票已退',
        interrupted = '上次航班已取消，船票已退',
    }
    notice(reasons[result.reason] or '摆渡暂时不可用')
end

function ScreenFerry:Start()
    for index, route in ipairs(GameCfg.Ferry.Routes) do
        self:CreateLeg(index .. ':out', route.Id, route.Outbound, 'Board', '乘船')
        self:CreateLeg(index .. ':return', route.Id, route.Return, 'Return', '返程')
    end
    REUtil:GetRE('FerryResult').OnClientEvent:Connect(function(result) self:OnResult(result) end)
    REUtil:GetRE('FerryState').OnClientEvent:Connect(function(state) self:OnState(state) end)
    game:GetService('RunService').Heartbeat:Connect(function(dt)
        self:UpdateLegs()
        self:UpdateCountdown(dt)
    end)
end

return ScreenFerry
