local GameCfg = require('common.GameCfg')
local BodyScale = require('common.BodyScale')
local REUtil = require('common.REUtil')

local LocalLoot = { Nodes = {}, Generation = 0 }

local Bubble = require('client.InteractionBubble')
local Players = game:GetService('Players')

function LocalLoot:EuiManager()
    local player = Players.LocalPlayer
    return player and player.PlayerGui and player.PlayerGui.EuiManager
end

function LocalLoot:Clear(id)
    local entry = self.Nodes[id]
    self.Nodes[id] = nil
    if not entry then return end
    local ok, err = pcall(function() entry.Node:Destroy() end)
    if not ok then print('[LocalLoot] 拾取文字泡销毁失败', id, tostring(err)) end
end

function LocalLoot:Create(loot)
    local eui = self:EuiManager()
    if not eui then return end
    local ok, node = pcall(eui.CreateSceneNodeAtPosition, eui,
        Vector3.New(loot.x, loot.y + GameCfg.Loot.BubbleHeight, loot.z))
    if not ok or not node then
        print('[LocalLoot] 拾取文字泡创建失败', loot.id, tostring(node))
        return
    end
    local btn = Bubble.CreateButton(node, 'BtnPickup_' .. tostring(loot.id), '拾取', 0, function()
        REUtil:GetRE('ItemBarAction'):FireServer({ action = 'Pickup', value = loot.id })
    end)
    if not btn then
        pcall(function() node:Destroy() end)
        return
    end
    node.Visible = false
    self.Nodes[loot.id] = { Node = node, Position = loot, Warning = loot.warn == true }
end

function LocalLoot:Show(list)
    local alive = {}
    for _, loot in ipairs(list or {}) do
        alive[loot.id] = true
        if not self.Nodes[loot.id] then self:Create(loot) end
        local entry = self.Nodes[loot.id]
        if entry then entry.Warning = loot.warn == true end
    end
    for id in pairs(self.Nodes) do
        if not alive[id] then self:Clear(id) end
    end
end

function LocalLoot:BlinkTick(entry, dt)
    local interval = GameCfg.Loot.FlashIntervalSec or 0.5
    entry.Blink = (entry.Blink or 0) + (dt or 0)
    return math.floor(entry.Blink / interval) % 2 == 0
end

function LocalLoot:Update(dt)
    local character = Players.LocalPlayer and Players.LocalPlayer.Character
    local pos = character and character.Position
    local radius = BodyScale.InteractionRadius(character, GameCfg.Loot.PickupRadius)
    for _, entry in pairs(self.Nodes) do
        local near = false
        if pos then
            local p = entry.Position
            local dx, dy, dz = pos.x - p.x, pos.y - p.y, pos.z - p.z
            near = dx * dx + dy * dy + dz * dz <= radius * radius
        end
        local visible = near
        if near and entry.Warning then visible = self:BlinkTick(entry, dt) end
        if entry.Visible ~= visible then
            entry.Visible = visible
            pcall(function() entry.Node.Visible = visible end)
        end
    end
end

function LocalLoot:Disconnect(connections)
    for index = #connections, 1, -1 do
        local connection = connections[index]
        connections[index] = nil
        if connection then pcall(function() connection:Disconnect() end) end
    end
end

function LocalLoot:Start()
    if self.Active then return end
    self.Generation = self.Generation + 1
    local generation = self.Generation
    local connections = {}
    local ok, err = pcall(function()
        connections[1] = REUtil:GetRE('LootState').OnClientEvent:Connect(function(list)
            if self.Generation ~= generation then return end
            self:Show(list)
        end)
        connections[2] = REUtil:GetRE('LootResult').OnClientEvent:Connect(function(result)
            if self.Generation ~= generation then return end
            if type(result) == 'table' and result.reason == 'full' and _G.LocalMsgNotice then
                _G.LocalMsgNotice('背包已满')
            end
        end)
        connections[3] = game:GetService('RunService').Heartbeat:Connect(function(dt)
            if self.Generation ~= generation then return end
            self:Update(dt)
        end)
        self.Generation = self.Generation + 1
        local requested, requestErr = pcall(function()
            REUtil:GetRE('RequestLoot'):FireServer()
        end)
        if requested then self.Generation = generation else error(requestErr, 0) end
    end)
    if not ok then
        self.Active = false
        self.Connections = nil
        self.Generation = self.Generation + 1
        self:Disconnect(connections)
        error(err, 0)
    end
    self.Connections = connections
    self.Active = true
end

return LocalLoot
