local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')

local Panel = { Seq = 0, Phase = 'alive', EndsAt = nil, WeakUntil = nil, PlatformPending = nil }

local ColorBlockImage = 'official://image/11017'

local function notice(msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

local function create(kind, parent, name, x, y, width, height, props)
    props = props or {}
    props.Parent = parent
    props.Name = name
    props.Position = Vector2.New(x, y)
    props.Size = Vector2.New(width, height)
    local node = game:GetService('World'):CreateUnit(kind, props)
    if not node then error('生存界面节点创建失败：' .. name) end
    node.TouchEnabled = false
    node.SwallowTouchEnabled = false
    return OwnedUnits.Track(Panel, node)
end

function Panel:Clear()
    OwnedUnits.Clear(self)
    self.Banner = nil
    self.Title = nil
    self.AdrenalineBtn = nil
    self.AdReviveBtn = nil
    self.PaidReviveBtn = nil
    self.WeakLabel = nil
end

function Panel:Send(action, mode)
    self.Seq = self.Seq + 1
    REUtil:GetRE('SurvivalAction'):FireServer({ action = action, mode = mode, seq = self.Seq })
end

local RESULT_TEXT = {}
local REVIVE_TEXT = {}

function Panel:Tick()
    if self.Phase == 'downed' or self.Phase == 'rescuing' or self.Phase == 'dead' then
        local left = math.max(0, math.ceil((self.EndsAt or 0) - self:Now()))
        local key = self.Phase == 'dead' and 'DeadTitle' or 'DownedTitle'
        local base = self.Phase == 'rescuing' and GameCfg.Rescue.RescuingTitle or GameCfg.Survival[key]
        local text = base .. '（' .. left .. ' 秒）'
        if self.PlatformPending and (self.Phase == 'dead' or self.Phase == 'downed') then
            text = GameCfg.Survival.PlatformWaitText
        end
        if self.Title then pcall(function() self.Title.Text = text end) end
    end
    if self.WeakUntil then
        local left = math.max(0, math.ceil(self.WeakUntil - self:Now()))
        if self.WeakLabel then
            pcall(function()
                self.WeakLabel.Visible = left > 0
                self.WeakLabel.Text = GameCfg.Survival.WeakText .. '（' .. left .. ' 秒）'
            end)
        end
        if left <= 0 then self.WeakUntil = nil end
    end
end

function Panel:Now()
    local ok, now = pcall(function() return game:GetService('World'):GetServerTime() end)
    return ok and tonumber(now) or 0
end

function Panel:SetPhase(state)
    local phase = state and state.phase or 'alive'
    local enteringDead = phase == 'dead' and self.Phase ~= 'dead'
    self.Phase = phase
    self.EndsAt = tonumber(state and state.endsAt) or nil
    self.WeakUntil = tonumber(state and state.weakUntil) or nil
    self.PlatformPending = state and state.platformPending or nil
    local downed = phase == 'downed' or phase == 'rescuing' or phase == 'dead'
    if self.Banner then pcall(function() self.Banner.Visible = downed end) end
    if self.Title then
        pcall(function()
            self.Title.Visible = downed
            self.Title.Text = phase == 'rescuing' and GameCfg.Rescue.RescuingTitle
                or GameCfg.Survival[phase == 'dead' and 'DeadTitle' or 'DownedTitle']
        end)
    end
    if self.AdrenalineBtn then
        pcall(function()
            self.AdrenalineBtn.Visible = phase == 'downed' and not self.PlatformPending
        end)
    end
    local canRevive = (phase == 'downed' or phase == 'dead') and not self.PlatformPending
    if self.AdReviveBtn then
        pcall(function()
            self.AdReviveBtn.Position = Vector2.New(phase == 'downed' and 330 or 10, 20)
            self.AdReviveBtn.Visible = canRevive
        end)
    end
    if self.PaidReviveBtn then
        pcall(function() self.PaidReviveBtn.Visible = canRevive and phase == 'dead' end)
    end
    if enteringDead then notice(GameCfg.Survival.CallHelpText) end
    self:Tick()
end

function Panel:OnResult(result)
    if type(result) ~= 'table' then return end
    if result.action == 'FullRevive' then
        if result.ok then return end
        local text = REVIVE_TEXT[result.reason]
        if text == nil then text = GameCfg.Survival.UnavailableText end
        if text ~= '' then notice(text) end
        return
    end
    if result.ok then
        if result.reason then notice(result.reason) end
        return
    end
    local text = RESULT_TEXT[result.reason]
    if text == nil then text = GameCfg.Survival.UnavailableText end
    if text ~= '' then notice(text) end
end

function Panel:Start()
    RESULT_TEXT = {
        ['busy'] = GameCfg.Survival.AdrenalineText,
        ['no-adrenaline'] = GameCfg.Survival.NoAdrenalineText,
        ['not-downed'] = '',
        ['replay'] = '',
    }
    REVIVE_TEXT = {
        ['unavailable'] = GameCfg.Survival.PlatformPendingText,
        ['not_open'] = GameCfg.Platform.NotOpenText,
        ['busy'] = GameCfg.Survival.PlatformWaitText,
        ['cancel'] = GameCfg.Survival.PlatformResumeText,
        ['fail'] = GameCfg.Survival.PlatformResumeText,
        ['timeout'] = GameCfg.Survival.PlatformResumeText,
        ['not-dead'] = '',
        ['not-revivable'] = '',
    }
    local okRoot, root, resolution = pcall(function()
        local eui = game:GetService('Players').LocalPlayer.PlayerGui.EuiManager
        return eui and eui:GetRootNode(), eui and eui:GetDeviceResolution()
    end)
    if not okRoot or not root then
        print('[ScreenSurvival] EUI 未就绪，跳过建面板')
        return
    end
    self:Clear()
    resolution = resolution or { x = 1920, y = 1080 }
    local cx, cy = resolution.x / 2, resolution.y / 2
    local banner = create('EUIImage', root, 'SurvivalBanner', cx - 320, cy - 90, 640, 180, {
        Color = Color.New(0, 0, 0, 160), Image = ColorBlockImage, Visible = false })
    self.Banner = banner
    self.Title = create('EUITextLabel', banner, 'SurvivalTitle', 0, -80, 640, 80, {
        Text = '', FontSize = 48, TextColor = Color.New(255, 80, 80, 255), LocalZOrder = 1 })
    local btn = create('EUIButton', banner, 'SurvivalAdrenaline', 10, 20, 300, 80, {
        ButtonText = '', NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
        Color = Color.New(230, 120, 40, 255), Visible = false })
    btn.TouchEnabled = true
    self.AdrenalineBtn = btn
    create('EUITextLabel', btn, 'SurvivalAdrenalineText', 0, 0, 300, 80, {
        Text = GameCfg.Survival.AdrenalineText, FontSize = 32,
        TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
    if btn.OnClicked then
        btn.OnClicked:Connect(function() self:Send('UseAdrenaline') end)
    end
    local function reviveButton(name, x, text, color, mode)
        local node = create('EUIButton', banner, name, x, 20, 300, 80, {
            ButtonText = '', NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
            Color = color, Visible = false })
        node.TouchEnabled = true
        create('EUITextLabel', node, name .. 'Text', 0, 0, 300, 80, {
            Text = text, FontSize = 30, TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
        if node.OnClicked then node.OnClicked:Connect(function() self:Send('FullRevive', mode) end) end
        return node
    end
    self.AdReviveBtn = reviveButton('SurvivalAdRevive', 10, GameCfg.Survival.AdReviveText,
        Color.New(60, 150, 90, 255), 'ad')
    self.PaidReviveBtn = reviveButton('SurvivalPaidRevive', 330, GameCfg.Survival.PaidReviveText,
        Color.New(210, 160, 40, 255), 'goods')
    self.WeakLabel = create('EUITextLabel', root, 'SurvivalWeak', cx - 320, resolution.y - 200, 640, 60, {
        Text = '', FontSize = 30, TextColor = Color.New(200, 200, 255, 255), Visible = false })
    REUtil:GetRE('SurvivalState').OnClientEvent:Connect(function(state) self:SetPhase(state) end)
    REUtil:GetRE('SurvivalResult').OnClientEvent:Connect(function(result) self:OnResult(result) end)
    game:GetService('RunService').Heartbeat:Connect(function() self:Tick() end)
end

return Panel
