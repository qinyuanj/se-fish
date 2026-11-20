-- 队伍界面（#253，§9 多人规则「队伍界面：在 HUD 上显示本队队友及每名队友的当前血量」
-- 「收到组队邀请时的界面提示与 10 秒倒计时展示」）。
-- 只按服务端 PartyState 快照渲染：队友名单、当前血量与邀请剩余秒数全部来自服务端，
-- 上行只发意图（接受 / 拒绝 / 离队 / 拉一次状态），本地不做任何入队、解散或免伤判定。
-- 布局数值集中在 GameCfg.Party.HUD（[未查证]，见 docs/to-questionnaire-策划案内部矛盾.md）。
local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')

local Panel = { Teammates = {}, PartyState = 'none', Rows = {}, Connections = {} }

local ColorBlockImage = 'official://image/11017' -- 官方正方形纯色块（ScreenSurvival 同款约定）

local function hud() return GameCfg.Party.HUD end

local function notice(message)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(message) end
end

local function create(kind, parent, name, x, y, width, height, props)
    props = props or {}
    props.Parent = parent
    props.Name = name
    props.Position = Vector2.New(x, y)
    props.Size = Vector2.New(width, height)
    local node = game:GetService('World'):CreateUnit(kind, props)
    if not node then error('队伍界面节点创建失败：' .. name) end
    node.TouchEnabled = false
    node.SwallowTouchEnabled = false
    return OwnedUnits.Track(Panel, node)
end

local function healthText(member)
    local health, maxHealth = member.health, member.maxHealth
    if type(health) ~= 'number' or type(maxHealth) ~= 'number' or maxHealth <= 0 then return '—' end
    return string.format('%d/%d', math.max(0, health), maxHealth)
end

local function healthWidth(member)
    local maxHealth = member.maxHealth
    if type(maxHealth) ~= 'number' or maxHealth <= 0 then return 0 end
    local ratio = (type(member.health) == 'number' and member.health or 0) / maxHealth
    return hud().BarWidth * math.max(0, math.min(1, ratio))
end

---销毁上一轮建的全部节点并复位自持引用（幂等）。
function Panel:Clear()
    OwnedUnits.Clear(self)
    self.Root, self.InvitePanel, self.Rows = nil, nil, {}
end

function Panel:Now()
    local ok, now = pcall(function() return game:GetService('World'):GetServerTime() end)
    return ok and tonumber(now) or 0
end

function Panel:Send(action, extra)
    local payload = { action = action }
    for key, value in pairs(extra or {}) do payload[key] = value end
    pcall(function() REUtil:GetRE('PartyAction'):FireServer(payload) end)
end

local NOTICE = {}   -- 服务端一次性事件 → 界面文案，未映射的安静跳过
local REASON = {}   -- 请求被拒的原因 → 界面文案，未映射的给通用失败文案
local UnavailableText = ''

function Panel:NoteNotice(code)
    local text = NOTICE[code]
    if text and text ~= '' then notice(text) end
end

---服务端回执：成功不打扰玩家（状态会自己推过来），失败给一句能照做的原因。
function Panel:NoteResult(result)
    if type(result) ~= 'table' or result.ok then return false end
    local text = REASON[result.reason]
    if text == nil then text = UnavailableText end
    if text ~= '' then notice(text) end
    return true
end

---收服务端快照：结构不对整包拒绝，绝不用坏包清掉上一份可信状态。
function Panel:NoteState(state)
    if type(state) ~= 'table' then return false end
    if state.state ~= 'none' and state.state ~= 'party' then return false end
    if type(state.members) ~= 'table' then return false end
    local teammates = {}
    for _, member in ipairs(state.members) do
        -- 血量允许缺失（队友还没出生时服务端没有读数）：名单照常收下，血量显示占位。
        if type(member) ~= 'table' or type(member.userId) ~= 'number' or type(member.name) ~= 'string'
            or (member.health ~= nil and type(member.health) ~= 'number')
            or (member.maxHealth ~= nil and type(member.maxHealth) ~= 'number') then return false end
        if member.self ~= true then
            teammates[#teammates + 1] = { userId = member.userId, name = member.name,
                health = member.health, maxHealth = member.maxHealth }
        end
    end
    if state.state == 'party' and (type(state.partyId) ~= 'number' or #state.members < 1) then return false end
    local invite = state.invite
    if invite ~= nil then
        if type(invite) ~= 'table' or type(invite.fromUserId) ~= 'number'
            or type(invite.expiresInSec) ~= 'number' or invite.expiresInSec < 0 then return false end
    end
    self.PartyState, self.PartyId = state.state, state.partyId
    self.Teammates = teammates
    self.InviteFrom = invite and invite.fromName or nil
    self.InviteUntil = invite and (self:Now() + invite.expiresInSec) or nil
    if state.notice then self:NoteNotice(state.notice) end
    self:Render()
    return true
end

function Panel:InviteRemaining()
    if not self.InviteUntil then return nil end
    return math.max(0, math.ceil(self.InviteUntil - self:Now()))
end

function Panel:RenderInvite()
    local panel = self.InvitePanel
    if not panel then return end
    local left = self:InviteRemaining()
    local visible = left ~= nil and left > 0
    pcall(function()
        panel.Root.Visible = visible
        if visible then
            panel.Text.Text = (self.InviteFrom or '队友') .. hud().InviteText
            panel.Countdown.Text = tostring(left) .. hud().InviteCountdownText
        end
    end)
end

function Panel:Render()
    if not self.Root then return end
    local teammates = self.Teammates
    pcall(function() self.Root.Visible = self.PartyState == 'party' end)
    for index, row in ipairs(self.Rows) do
        local member = teammates[index]
        local visible = member ~= nil and self.PartyState == 'party'
        pcall(function()
            row.Root.Visible = visible
            if not visible then return end
            row.Name.Text = member.name
            row.Health.Text = healthText(member)
            row.Fill.Size = Vector2.New(healthWidth(member), hud().BarHeight)
        end)
    end
    self:RenderInvite()
end

---倒计时按服务端剩余秒数本地走；到 0 立即撤板，等服端下一次快照确认按拒绝结算。
function Panel:Tick()
    if not self.InviteUntil then return end
    if self:InviteRemaining() <= 0 then
        self.InviteUntil = nil
        self.InviteFrom = nil
    end
    self:RenderInvite()
end

---公开显示快照：界面当前展示的队友与邀请，供探针与条款断言读取，不改任何状态。
function Panel:View()
    local rows = {}
    for index, member in ipairs(self.Teammates) do
        rows[index] = { userId = member.userId, name = member.name, health = member.health,
            maxHealth = member.maxHealth, healthText = healthText(member),
            width = healthWidth(member) }
    end
    local left = self:InviteRemaining()
    local invite
    if left and left > 0 then invite = { fromName = self.InviteFrom, remainingSec = left } end
    return { state = self.PartyState, partyId = self.PartyId, rows = rows, invite = invite,
        inviteVisible = invite ~= nil, countdownText = invite and (tostring(left) .. hud().InviteCountdownText) or nil }
end

function Panel:Start()
    NOTICE = {
        ['disbanded'] = hud().DisbandText,
        ['left'] = hud().LeftText,
        ['restored'] = hud().RestoredText,
        ['full'] = hud().RestoreFullText,
        ['joined'] = '',
    }
    REASON = {
        ['too-far'] = hud().TooFarText,
        ['full'] = hud().FullText,
        ['offline'] = hud().OfflineText,
        ['target-in-party'] = hud().TargetInPartyText,
        ['no-invite'] = hud().NoInviteText,
        ['expired'] = hud().NoInviteText,
        ['invalid-target'] = hud().NoInviteText,
        ['unknown-action'] = '',
    }
    UnavailableText = hud().UnavailableText
    local okRoot, root = pcall(function()
        local eui = game:GetService('Players').LocalPlayer.PlayerGui.EuiManager
        return eui and eui:GetRootNode(), eui and eui:GetDeviceResolution()
    end)
    if not okRoot or not root then
        print('[ScreenParty] EUI 未就绪，跳过建面板')
        return
    end
    -- 重建前先清空上一轮节点：Start 重入不叠第二套队友栏。
    self:Clear()
    local resolution = root[2] or { x = 1920, y = 1080 }
    local width, height = hud().RowWidth, hud().RowHeight
    -- 右侧竖排，避开左上角自身血量（布局参数见 GameCfg.Party.HUD）。
    self.Root = create('EUILayout', root[1], 'PartyRoot',
        resolution.x - width - hud().MarginRight, hud().MarginTop, width, height * hud().MaxRows, { Visible = false })
    for index = 1, hud().MaxRows do
        local top = (index - 1) * height
        local row = create('EUILayout', self.Root, 'PartyMember' .. index, 0, top, width, height, { Visible = false })
        local name = create('EUITextLabel', row, 'PartyMember' .. index .. 'Name', 0, 0, width, 24, {
            Text = '', FontSize = 20, TextColor = Color.New(235, 235, 235, 255), LocalZOrder = 1 })
        local bar = create('EUILayout', row, 'PartyMember' .. index .. 'Bar', 0, 28, hud().BarWidth, hud().BarHeight, {
            Visible = true })
        local fill = create('EUIImage', bar, 'PartyMember' .. index .. 'Fill', 0, 0, 0, hud().BarHeight, {
            Image = ColorBlockImage, Color = Color.New(230, 60, 60, 255), LocalZOrder = 1 })
        local health = create('EUITextLabel', row, 'PartyMember' .. index .. 'Health',
            hud().BarWidth + 8, 24, width - hud().BarWidth - 8, 24, {
                Text = '', FontSize = 20, TextColor = Color.New(235, 235, 235, 255), LocalZOrder = 1 })
        self.Rows[index] = { Root = row, Name = name, Bar = bar, Fill = fill, Health = health }
    end
    local invite = create('EUILayout', root[1], 'PartyInvite',
        (resolution.x - hud().InviteWidth) / 2, hud().InviteTop, hud().InviteWidth, hud().InviteHeight, { Visible = false })
    local inviteText = create('EUITextLabel', invite, 'PartyInviteText', 0, 0, hud().InviteWidth, 48, {
        Text = hud().InviteText, FontSize = 24, TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
    local countdown = create('EUITextLabel', invite, 'PartyInviteCountdown', 0, 32, hud().InviteWidth, 24, {
        Text = '', FontSize = 20, TextColor = Color.New(255, 220, 140, 255), LocalZOrder = 1 })
    local accept = create('EUIButton', invite, 'PartyInviteAccept', hud().InviteWidth - 180, 56, 80, 32, {
        ButtonText = '接受', NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
        Color = Color.New(60, 150, 90, 255) })
    local decline = create('EUIButton', invite, 'PartyInviteDecline', hud().InviteWidth - 90, 56, 80, 32, {
        ButtonText = '拒绝', NormalImage = ColorBlockImage, PressImage = ColorBlockImage,
        Color = Color.New(150, 60, 60, 255) })
    for _, button in ipairs({ accept, decline }) do
        button.TouchEnabled = true
        if button.OnClicked then
            local action = button == accept and 'Accept' or 'Decline'
            button.OnClicked:Connect(function() self:Send(action) end)
        end
    end
    self.InvitePanel = { Root = invite, Text = inviteText, Countdown = countdown }
    self.Connections = self.Connections or {}
    self.Connections[#self.Connections + 1] =
        REUtil:GetRE('PartyState').OnClientEvent:Connect(function(state) self:NoteState(state) end)
    self.Connections[#self.Connections + 1] =
        REUtil:GetRE('PartyResult').OnClientEvent:Connect(function(result) self:NoteResult(result) end)
    self.Connections[#self.Connections + 1] =
        game:GetService('RunService').Heartbeat:Connect(function() self:Tick() end)
    -- ready/snapshot 握手：进图、重连与界面重开都主动拉一次当前归属，迟到的客户端也能补齐。
    pcall(function() REUtil:GetRE('PartyStateRequest'):FireServer() end)
end

return Panel
