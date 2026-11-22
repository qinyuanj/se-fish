local GameCfg = require('common.GameCfg')
local OwnedUnits = require('common.OwnedUnits')
local REUtil = require('common.REUtil')

local Panel = {}
Panel.__index = Panel

local function hud() return GameCfg.Party.HUD end

local function notice(message)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(message) end
end

local function create(nodes, kind, parent, name, x, y, width, height, props)
    props = props or {}
    props.Parent = parent
    props.Name = name
    props.Position = Vector2.New(x, y)
    props.Size = Vector2.New(width, height)
    local node = game:GetService('World'):CreateUnit(kind, props)
    if not node then error('队伍界面节点创建失败：' .. name) end
    nodes[#nodes + 1] = node
    node.TouchEnabled = false
    node.SwallowTouchEnabled = false
    return node
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

function Panel:Clear()
    for _, connection in ipairs(self.Connections) do
        local ok, err = pcall(function() connection:Disconnect() end)
        if not ok then print('[ScreenParty] 断开监听失败', tostring(err)) end
    end
    self.Connections = {}
    OwnedUnits.Clear(self)
    self.Root, self.InvitePanel, self.Rows = nil, nil, {}
    self.PartyState, self.PartyId, self.Teammates = 'none', nil, {}
    self.InviteFrom, self.InviteUntil = nil, nil
end

function Panel:Now()
    local ok, now = pcall(function() return game:GetService('World'):GetServerTime() end)
    if not ok then
        print('[ScreenParty] 读取服务器时间失败', tostring(now))
        return 0
    end
    return tonumber(now) or 0
end

function Panel:Send(action, extra)
    local payload = { action = action }
    for key, value in pairs(extra or {}) do payload[key] = value end
    local ok, err = pcall(function() REUtil:GetRE('PartyAction'):FireServer(payload) end)
    if not ok then print('[ScreenParty] 行动请求发送失败', tostring(action), tostring(err)) end
end

local NOTICE = {}
local REASON = {}
local UnavailableText = ''

function Panel:NoteNotice(code)
    local text = NOTICE[code]
    if text and text ~= '' then notice(text) end
end

function Panel:NoteResult(result)
    if type(result) ~= 'table' or result.ok then return false end
    local text = REASON[result.reason]
    if text == nil then text = UnavailableText end
    if text ~= '' then notice(text) end
    return true
end

function Panel:NoteState(state)
    if type(state) ~= 'table' then return false end
    if state.state ~= 'none' and state.state ~= 'party' then return false end
    if type(state.members) ~= 'table' then return false end
    local teammates = {}
    for _, member in ipairs(state.members) do
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
    local ok, err = pcall(function()
        panel.Root.Visible = visible
        if visible then
            panel.Text.Text = (self.InviteFrom or '队友') .. hud().InviteText
            panel.Countdown.Text = tostring(left) .. hud().InviteCountdownText
        end
    end)
    if not ok then print('[ScreenParty] 邀请提示渲染失败', tostring(err)) end
end

function Panel:Render()
    if not self.Root then return end
    local teammates = self.Teammates
    local shown, showErr = pcall(function() self.Root.Visible = self.PartyState == 'party' end)
    if not shown then print('[ScreenParty] 队友栏显隐失败', tostring(showErr)) end
    for index, row in ipairs(self.Rows) do
        local member = teammates[index]
        local visible = member ~= nil and self.PartyState == 'party'
        local ok, err = pcall(function()
            row.Root.Visible = visible
            if not visible then return end
            row.Name.Text = member.name
            row.Health.Text = healthText(member)
            row.Fill.Size = Vector2.New(healthWidth(member), hud().BarHeight)
        end)
        if not ok then print('[ScreenParty] 队友行渲染失败', index, tostring(err)) end
    end
    self:RenderInvite()
end

function Panel:Tick()
    if not self.InviteUntil then return end
    if self:InviteRemaining() <= 0 then
        self.InviteUntil = nil
        self.InviteFrom = nil
    end
    self:RenderInvite()
end

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
        ['save-failed'] = hud().UnavailableText,
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
    local okRoot, root, resolution = pcall(function()
        local eui = game:GetService('Players').LocalPlayer.PlayerGui.EuiManager
        return eui and eui:GetRootNode(), eui and eui:GetDeviceResolution()
    end)
    if not okRoot or not root then
        if #self.Connections == 0 then self:Clear() end
        print('[ScreenParty] EUI 未就绪，跳过建面板', tostring(root))
        return
    end
    resolution = resolution or { x = 1920, y = 1080 }
    local width, height = hud().RowWidth, hud().RowHeight
    local candidate = { Nodes = {} }
    local built, buildErr = pcall(function()
        candidate.Root = create(candidate.Nodes, 'EUILayout', root, 'PartyRoot',
            resolution.x - width - hud().MarginRight, hud().MarginTop, width, height * hud().MaxRows, { Visible = false })
        candidate.Rows = {}
        for index = 1, hud().MaxRows do
            local top = (index - 1) * height
            local row = create(candidate.Nodes, 'EUILayout', candidate.Root, 'PartyMember' .. index, 0, top, width, height, { Visible = false })
            local name = create(candidate.Nodes, 'EUITextLabel', row, 'PartyMember' .. index .. 'Name', 0, 0, width, 24, {
                Text = '', FontSize = 20, TextColor = Color.New(235, 235, 235, 255), LocalZOrder = 1 })
            local bar = create(candidate.Nodes, 'EUILayout', row, 'PartyMember' .. index .. 'Bar', 0, 28, hud().BarWidth, hud().BarHeight, {
                Visible = true })
            local fill = create(candidate.Nodes, 'EUIImage', bar, 'PartyMember' .. index .. 'Fill', 0, 0, 0, hud().BarHeight, {
                Image = hud().ColorBlockImage, Color = Color.New(230, 60, 60, 255), LocalZOrder = 1 })
            local health = create(candidate.Nodes, 'EUITextLabel', row, 'PartyMember' .. index .. 'Health',
                hud().BarWidth + 8, 24, width - hud().BarWidth - 8, 24, {
                    Text = '', FontSize = 20, TextColor = Color.New(235, 235, 235, 255), LocalZOrder = 1 })
            candidate.Rows[index] = { Root = row, Name = name, Bar = bar, Fill = fill, Health = health }
        end
        local invite = create(candidate.Nodes, 'EUILayout', root, 'PartyInvite',
            (resolution.x - hud().InviteWidth) / 2, hud().InviteTop, hud().InviteWidth, hud().InviteHeight, { Visible = false })
        local inviteText = create(candidate.Nodes, 'EUITextLabel', invite, 'PartyInviteText', 0, 0, hud().InviteWidth, 48, {
            Text = hud().InviteText, FontSize = 24, TextColor = Color.New(255, 255, 255, 255), LocalZOrder = 1 })
        local countdown = create(candidate.Nodes, 'EUITextLabel', invite, 'PartyInviteCountdown', 0, 32, hud().InviteWidth, 24, {
            Text = '', FontSize = 20, TextColor = Color.New(255, 220, 140, 255), LocalZOrder = 1 })
        local accept = create(candidate.Nodes, 'EUIButton', invite, 'PartyInviteAccept', hud().InviteWidth - 180, 56, 80, 32, {
            ButtonText = hud().AcceptText, NormalImage = hud().ColorBlockImage, PressImage = hud().ColorBlockImage,
            Color = Color.New(60, 150, 90, 255) })
        local decline = create(candidate.Nodes, 'EUIButton', invite, 'PartyInviteDecline', hud().InviteWidth - 90, 56, 80, 32, {
            ButtonText = hud().DeclineText, NormalImage = hud().ColorBlockImage, PressImage = hud().ColorBlockImage,
            Color = Color.New(150, 60, 60, 255) })
        candidate.InvitePanel = { Root = invite, Text = inviteText, Countdown = countdown }
        candidate.Buttons = { accept, decline }
    end)
    if not built then
        for _, node in ipairs(candidate.Nodes) do pcall(function() node:Destroy() end) end
        print('[ScreenParty] 建面板失败，保留上一轮', tostring(buildErr))
        return
    end
    self:Clear()
    self.Root, self.InvitePanel, self.Rows = candidate.Root, candidate.InvitePanel, candidate.Rows
    for _, node in ipairs(candidate.Nodes) do OwnedUnits.Track(self, node) end
    candidate.Nodes = {}
    self.Connections[#self.Connections + 1] =
        REUtil:GetRE('PartyState').OnClientEvent:Connect(function(state) self:NoteState(state) end)
    self.Connections[#self.Connections + 1] =
        REUtil:GetRE('PartyResult').OnClientEvent:Connect(function(result) self:NoteResult(result) end)
    self.Connections[#self.Connections + 1] =
        game:GetService('RunService').Heartbeat:Connect(function() self:Tick() end)
    local accept, decline = candidate.Buttons[1], candidate.Buttons[2]
    for _, button in ipairs({ accept, decline }) do
        button.TouchEnabled = true
        if button.OnClicked then
            local action = button == accept and 'Accept' or 'Decline'
            self.Connections[#self.Connections + 1] =
                button.OnClicked:Connect(function() self:Send(action) end)
        end
    end
    local okSync, syncErr = pcall(function() REUtil:GetRE('PartyStateRequest'):FireServer() end)
    if not okSync then print('[ScreenParty] 队伍状态请求发送失败', tostring(syncErr)) end
end

return setmetatable({ Teammates = {}, PartyState = 'none', Rows = {}, Connections = {} }, Panel)
