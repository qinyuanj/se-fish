local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local REUtil = require('common.REUtil')
local Util = require('common.Util')
local Dialogue = require('common.NpcDialogue')

local Bubble = require('client.InteractionBubble')
local OwnedUnits = require('common.OwnedUnits')
local LocalInteract = { Seq = 0, Bubbles = {}, Models = {}, RescueBubbles = {} }

local PulseFrames = 20
local PulseAmp = 0.2

local World = game:GetService('World')
local Players = game:GetService('Players')

local function notice(msg)
    if _G.LocalMsgNotice then _G.LocalMsgNotice(msg) end
end

function LocalInteract:Button(node, name, text, x, onClick)
    return Bubble.CreateButton(node, name, text, x, onClick)
end

function LocalInteract:Feed(index)
    self.Seq = self.Seq + 1
    self.FeedIndex = index
    REUtil:GetRE('InteractAction'):FireServer({ target = 'fisherman', action = 'Feed', seq = self.Seq })
end

function LocalInteract:Rescue(userId)
    self.Seq = self.Seq + 1
    REUtil:GetRE('InteractAction'):FireServer({ target = GameCfg.Rescue.Target, action = GameCfg.Rescue.Action,
        targetUserId = userId, seq = self.Seq })
end

function LocalInteract:EnsureRescueBubble(player)
    local userId = player.UserId
    if self.RescueBubbles[userId] then return self.RescueBubbles[userId] end
    local eui = Players.LocalPlayer and Players.LocalPlayer.PlayerGui and Players.LocalPlayer.PlayerGui.EuiManager
    local pos = player.Character and player.Character.Position
    if not eui or not pos then return nil end
    local ok, node = pcall(eui.CreateSceneNodeAtPosition, eui,
        Vector3.New(pos.x, pos.y + GameCfg.Rescue.BubbleHeight, pos.z))
    if not ok or not node then
        print('[LocalInteract] 抢救气泡创建失败', tostring(node))
        return nil
    end
    local button = self:Button(node, 'BtnRescue' .. userId, GameCfg.Rescue.PromptText, 0,
        function() self:Rescue(userId) end)
    if not button then
        local destroyed, err = pcall(function() node:Destroy() end)
        if not destroyed then
            print('[LocalInteract] 抢救气泡按钮创建失败后销毁根节点失败', tostring(userId), tostring(err))
        end
        return nil
    end
    node.Visible = false
    local entry = { Node = node, Position = pos }
    OwnedUnits.Track(entry, node)
    self.RescueBubbles[userId] = entry
    return entry
end

function LocalInteract:UpdateRescuePrompts()
    local me = Players.LocalPlayer
    local pos = me and me.Character and me.Character.Position
    local players = Players.GetPlayers and Players:GetPlayers() or {}
    local present = {}
    for _, player in ipairs(players) do
        present[player.UserId] = true
        local entry = self.RescueBubbles[player.UserId]
        local phase = player.GetAttribute and player:GetAttribute('SurvivalPhase') or nil
        local visible = false
        local downed = phase == 'downed' or phase == 'rescuing'
        if player ~= me and downed and pos then
            local target = player.Character and player.Character.Position
            if target then
                local dx, dz = pos.x - target.x, pos.z - target.z
                visible = dx * dx + dz * dz <= GameCfg.Rescue.Range * GameCfg.Rescue.Range
            end
        end
        if visible then
            entry = self:EnsureRescueBubble(player)
            if entry then
                local target = player.Character.Position
                entry.Position = target
                pcall(function() entry.Node.Position = Vector3.New(target.x,
                    target.y + GameCfg.Rescue.BubbleHeight, target.z) end)
            end
        end
        if entry then
            local ok, err = pcall(function() entry.Node.Visible = visible end)
            if not ok then print('[LocalInteract] 抢救气泡显隐失败', tostring(err)) end
        end
    end
    for userId, entry in pairs(self.RescueBubbles) do
        if not present[userId] then
            local ok, err = pcall(function() entry.Node.Visible = false end)
            if not ok then print('[LocalInteract] 抢救气泡离场隐藏失败', userId, tostring(err)) end
            OwnedUnits.Clear(entry)
            self.RescueBubbles[userId] = nil
        end
    end
end

function LocalInteract:Create(anchor, suffix, zoneId, index)
    local cfg = GameCfg.Interact.Fisherman
    local player = Players.LocalPlayer
    local eui = player and player.PlayerGui and player.PlayerGui.EuiManager
    local center = anchor.Position
    if not eui or not center then return end
    local ok, node = pcall(eui.CreateSceneNodeAtPosition, eui,
        Vector3.New(center.x, center.y + cfg.BubbleHeight, center.z))
    if not ok or not node then
        print('[LocalInteract] 钓鱼佬文字泡创建失败', tostring(node))
        return
    end
    local offset = (GameCfg.InteractionBubble.Width + GameCfg.InteractionBubble.Gap) / 2
    self:Button(node, 'BtnFishermanTalk' .. suffix, '对话', -offset,
        function()
            local lines = Dialogue.Lines(zoneId)
            local main = _G.MgrGameUI and _G.MgrGameUI:GetScreen('ScreenMain')
            if main and lines then
                main:ShowDialogue({ title = '钓鱼佬', lines = lines })
            else
                notice(Dialogue.Describe(zoneId) or cfg.DialogText)
            end
        end)
    self:Button(node, 'BtnFishermanFeed' .. suffix, '喂食', offset, function() self:Feed(index) end)
    node.Visible = false
    self.Bubbles[#self.Bubbles + 1] = { Node = node, Center = center, Visible = false }
end

function LocalInteract:StartPulse()
    local entry = self.FeedIndex and self.Models[self.FeedIndex]
    if not entry then return end
    self.Pulse = entry
    self.PulseLeft = PulseFrames
end

function LocalInteract:UpdatePulse()
    if not self.PulseLeft then return end
    local entry = self.Pulse
    if not entry then
        self.PulseLeft = nil
        return
    end
    local factor = 1
    if self.PulseLeft > 1 then
        local progress = 1 - self.PulseLeft / PulseFrames
        factor = 1 + PulseAmp * math.sin(math.pi * progress)
    end
    local base = entry.BaseScale
    local ok, err = pcall(function()
        entry.Model.Scale = Vector3.New(base.x * factor, base.y * factor, base.z * factor)
    end)
    if not ok then
        print('[LocalInteract] 钓鱼佬缩放脉冲失败，放弃表现', tostring(err))
        self.PulseLeft = nil
        self.Pulse = nil
        for index, other in pairs(self.Models) do
            if other == entry then self.Models[index] = nil end
        end
        return
    end
    self.PulseLeft = self.PulseLeft - 1
    if self.PulseLeft <= 0 then self.PulseLeft = nil end
end

function LocalInteract:Update()
    self:UpdatePulse()
    self:UpdateRescuePrompts()
    local character = Players.LocalPlayer and Players.LocalPlayer.Character
    local pos = character and character.Position
    local radius = BodyScale.InteractionRadius(character, GameCfg.Interact.Fisherman.Radius)
    for _, bubble in ipairs(self.Bubbles) do
        local visible = false
        if pos then
            local dx, dz = pos.x - bubble.Center.x, pos.z - bubble.Center.z
            visible = dx * dx + dz * dz <= radius * radius
        end
        if bubble.Visible ~= visible then
            bubble.Visible = visible
            local ok, err = pcall(function() bubble.Node.Visible = visible end)
            if not ok then print('[LocalInteract] 气泡显隐失败', tostring(err)) end
        end
    end
end

function LocalInteract:OnResult(result)
    if type(result) ~= 'table' then return end
    if result.action == GameCfg.Rescue.Action then
        if not result.ok and result.reason == 'busy' then notice(GameCfg.Rescue.BusyText) end
        return
    end
    self:OnFishermanResult(result)
end

function LocalInteract:OnFishermanResult(result)
    if result.ok then
        if result.achievement then
            local achievement = GameCfg.Achievements[result.achievement]
            notice('达成' .. (achievement and achievement.Name or tostring(result.achievement)))
        elseif type(result.exchange) == 'table' then
            local defs = GameCfg.Items.Definitions
            local from = defs[result.exchange.from]
            local to = defs[result.exchange.to]
            notice('用' .. (from and from.Name or tostring(result.exchange.from))
                .. '换得' .. (to and to.Name or tostring(result.exchange.to)) .. ' x1')
        else
            notice('钓鱼佬吃得很香，金币 +' .. tostring(result.coins))
        end
        self:StartPulse()
    elseif result.reason == 'nothing' then
        notice('先选中要喂的鱼获或鱼饵')
    elseif result.reason == 'full' then
        notice('格子满了，钓鱼佬不肯换')
    end
end

function LocalInteract:Start()
    REUtil:GetRE('InteractResult').OnClientEvent:Connect(function(result)
        self:OnResult(result)
    end)
    for index, npc in ipairs(GameCfg.Interact.Fishermen) do
        for _, name in ipairs(npc.AnchorNames) do
            local anchor = Util:WaitForChild(World, name)
            if anchor then
                self:Create(anchor, index .. '_' .. name, npc.ZoneId, index)
            else
                print('[LocalInteract] 找不到钓鱼佬单位', npc.ZoneId, name)
            end
        end
    end
    game:GetService('RunService').Heartbeat:Connect(function() self:Update() end)
    for index, npc in ipairs(GameCfg.Interact.Fishermen) do self:BindModel(index, npc) end
end

function LocalInteract:BindModel(index, npc)
    local model = npc.ModelName and Util:WaitForChild(World, npc.ModelName)
    if not model then
        print('[LocalInteract] 找不到钓鱼佬模型，跳过吃动作', npc.ZoneId, tostring(npc.ModelName))
        return
    end
    local ok, scale = pcall(function() return model.Scale end)
    if ok and scale then
        self.Models[index] = { Model = model, BaseScale = scale }
    else
        print('[LocalInteract] 钓鱼佬模型读 Scale 失败，跳过吃动作', npc.ZoneId, tostring(scale))
    end
end

return LocalInteract
