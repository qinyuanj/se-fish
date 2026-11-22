local Players = game:GetService("Players")
local World = game:GetService("World")
local GameCfg = require("common.GameCfg")
local Gesture = require("client.PressGesture")
local WeaponAim = require('client.WeaponAim')
local LocalAttackButton = {}

function LocalAttackButton.EquippedWeapon(state)
    local weapons = type(state) == "table" and type(state.weapons) == "table" and state.weapons or {}
    local held = type(state) == "table" and state.held or nil
    if type(held) == "table" and held.kind == "weapon" and (weapons[held.id] or 0) > 0 then
        return held.id
    end
    local selected = type(state) == "table" and state.selectedWeapon or nil
    if selected and (weapons[selected] or 0) > 0 then return selected end
    return nil
end

function LocalAttackButton:SetEquipped(state)
    self.EquippedId = LocalAttackButton.EquippedWeapon(state)
    self.EquippedGun = nil
    self.AutoFireGun = nil
    local gcfg = self.EquippedId and GameCfg.Ability.Guns[self.EquippedId] or nil
    if gcfg then
        self.EquippedGun = gcfg
        if gcfg.Auto then self.AutoFireGun = gcfg end
    end
    if self.Label then
        self.Label.Text = self.EquippedGun and "射击" or "攻击"
    end
end

function LocalAttackButton:Start(parent, rect)
    if self.Root == parent and self.Container then return end
    self:Destroy()
    self.Root = parent
    self.Gesture = Gesture.New({ LongPressSec = GameCfg.Ability.Throw.LongPressSec })
    local container = World:CreateUnit("EUILayout", {
        Parent = parent, Name = "AttackControl",
        Position = Vector2.New(rect.x, rect.y), Size = Vector2.New(rect.w, rect.h),
    })
    container.TouchEnabled = false
    container.SwallowTouchEnabled = false
    self.Container = container
    local btn = World:CreateUnit("EUIButton", {
        Parent = container, Name = "BtnAttack",
        Position = Vector2.New(rect.w / 2, rect.h / 2), Size = Vector2.New(rect.w, rect.h),
    })
    btn.ButtonText = ""
    btn.NormalImage = "official://image/10055"
    btn.PressImage = "official://image/10056"
    btn.DisableImage = "official://image/10055"
    btn.ButtonNormalColor = Color.New(245, 250, 242, 185)
    btn.ButtonPressColor = Color.New(210, 235, 185, 240)
    btn.ButtonDisableColor = Color.New(190, 195, 185, 100)
    self.BtnAttack = btn
    local label = World:CreateUnit("EUITextLabel", {
        Parent = container, Name = "AttackLabel",
        Position = Vector2.New(rect.w / 2, rect.h / 2), Size = Vector2.New(rect.w * 0.8, 70),
    })
    label.Text = "攻击"
    label.FontSize = 36
    label.TextColor = Color.New(48, 65, 44, 255)
    label.TextHorizontalAlignment = 1
    label.TextVerticalAlignment = 1
    label.LocalZOrder = 1
    label.TouchEnabled = false
    label.SwallowTouchEnabled = false
    self.Label = label
    self.PressConns = {}
    if btn.OnTouchBegan and btn.OnTouchEnded then
        self.PressConns[#self.PressConns + 1] = btn.OnTouchBegan:Connect(function() self:OnPressBegin() end)
        self.PressConns[#self.PressConns + 1] = btn.OnTouchEnded:Connect(function() self:OnPressEnd() end)
    else
        self.ClickConn = btn.OnClicked:Connect(function() self:RequestAttack() end)
    end
    local runService = game:GetService("RunService")
    if runService and runService.Heartbeat then
        self.HeartConn = runService.Heartbeat:Connect(function() self:Tick() end)
    end
    _G.MgrGameUI:SetCustomControlUI(container, true)
    self:SetOpen(false)
end

function LocalAttackButton:SetOpen(open)
    self.IsOpen = open == true
    if self.Container then self.Container.Visible = self.IsOpen end
    if self.BtnAttack then self.BtnAttack.TouchEnabled = self.IsOpen end
    if not self.IsOpen then self.Pressing = false end
end

function LocalAttackButton:Visible()
    return self.IsOpen and self.Container and self.Container.Visible
        and self.Root and self.Root.Visible
end

function LocalAttackButton:CanOperate()
    return self:Visible() and Players.LocalPlayer and Players.LocalPlayer.Character
end

function LocalAttackButton:OnPressBegin()
    self.Pressing = true
    self.AutoFired = false
    self.NextAutoFire = 0
    if self.Gesture then self.Gesture:Begin(World:GetServerTime()) end
end

function LocalAttackButton:OnPressEnd()
    self.Pressing = false
    if not self.Gesture then return end
    local result = self.Gesture:End(World:GetServerTime())
    if result == "tap" then
        if not self.AutoFired then self:RequestAttack() end
    elseif result == "long" and self.EquippedGun and not self.AutoFireGun then
        self:RequestReload()
    end
end

function LocalAttackButton:Tick()
    if not self.Pressing or not self:CanOperate() then return end
    local now = World:GetServerTime()
    if self.Gesture then self.Gesture:Update(now) end
    if self.AutoFireGun and now >= (self.NextAutoFire or 0) then
        self.NextAutoFire = now + (self.AutoFireGun.IntervalSec or 0.2)
        self.AutoFired = true
        self:RequestAttack()
    end
end

function LocalAttackButton:RequestAttack()
    if not self:CanOperate() then return end
    print("[LocalAttackButton] 请求攻击 equipped=" .. tostring(self.EquippedId))
    _G.REUtil:GetRE("WeaponAction"):FireServer(WeaponAim:AttackPayload())
end

function LocalAttackButton:RequestReload()
    if not self:CanOperate() then return end
    print("[LocalAttackButton] 请求换弹 equipped=" .. tostring(self.EquippedId))
    _G.REUtil:GetRE("WeaponAction"):FireServer({ action = "reload" })
end

function LocalAttackButton:Destroy()
    self.IsOpen = false
    self.Pressing = false
    if self.ClickConn then self.ClickConn:Disconnect() end
    if self.HeartConn then self.HeartConn:Disconnect() end
    for _, conn in ipairs(self.PressConns or {}) do conn:Disconnect() end
    if self.Container then
        _G.MgrGameUI:SetCustomControlUI(self.Container, nil)
        self.Container:Destroy()
    end
    self.ClickConn = nil
    self.HeartConn = nil
    self.PressConns = nil
    self.Container = nil
    self.BtnAttack = nil
    self.Label = nil
    self.Root = nil
    self.EquippedId = nil
    self.EquippedGun = nil
    self.AutoFireGun = nil
end

return LocalAttackButton
