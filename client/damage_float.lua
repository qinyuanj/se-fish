local GameCfg = require('common.game_cfg')
local DamageFloat = { active = {}, pool = {}, sequence = {}, pending_cleanup = {} }
local cfg = GameCfg.DamageFloat

function DamageFloat.display_amount(amount)
    return math.max(1, math.floor(amount + 0.5))
end

function DamageFloat:clear()
    local pending = {}
    local function destroy(node)
        local ok, err = pcall(function() node:Destroy() end)
        if not ok then
            print('[DamageFloat] 清理节点失败', tostring(err))
            pending[#pending + 1] = node
        end
    end
    for _, node in ipairs(self.pending_cleanup) do destroy(node) end
    self.pending_cleanup = pending
    for _, entry in ipairs(self.active) do destroy(entry.node) end
    for _, node in ipairs(self.pool) do destroy(node) end
    self.active, self.pool, self.sequence = {}, {}, {}
    self.root, self.resolution = nil, nil
end

function DamageFloat:bind(root, resolution)
    if self.root == root then return end
    self:clear()
    self.root, self.resolution = root, resolution
end

local function valid(payload)
    local p = type(payload) == 'table' and payload.position
    return type(payload) == 'table' and type(payload.target_type) == 'string'
        and type(payload.target_id) == 'number' and type(payload.amount) == 'number'
        and payload.amount > 0 and payload.amount < math.huge and type(p) == 'table'
        and type(p.x) == 'number' and p.x == p.x and math.abs(p.x) < math.huge
        and type(p.y) == 'number' and p.y == p.y and math.abs(p.y) < math.huge
        and type(p.z) == 'number' and p.z == p.z and math.abs(p.z) < math.huge
end

function DamageFloat:project(position, height)
    local camera = game:GetService('CameraService')
    if not camera or not camera.MainCamera or not self.resolution then return nil end
    local screen, visible = camera:WorldToViewportPoint(Vector3.New(
        position.x, position.y + (height or cfg.HeadHeight), position.z))
    if not screen or not visible or screen.z <= 0 then return nil end
    return screen.x, self.resolution.y - screen.y
end

function DamageFloat:show(payload)
    if not self.root or not valid(payload) then return end
    local x, y = self:project(payload.position, payload.height)
    if not x then return end
    local node = table.remove(self.pool)
    if not node then
        node = game:GetService('World'):CreateUnit('EUITextLabel', {
            Parent = self.root, Name = 'DamageFloat',
            Position = Vector2.New(0, 0), Size = Vector2.New(cfg.Width, cfg.Height),
        })
    end
    if not node then return end
    local key = payload.target_type .. ':' .. tostring(payload.target_id)
    local sequence = (self.sequence[key] or 0) + 1
    self.sequence[key] = sequence
    local spread = ((sequence - 1) % 3 - 1) * cfg.SpreadPixels
    local critical = payload.critical == true
    local color = critical and cfg.CriticalColor or cfg.NormalColor
    node.Text = tostring(self.display_amount(payload.amount))
    node.TextColor = Color.New(color[1], color[2], color[3], color[4])
    node.FontSize = critical and cfg.CriticalFontSize or cfg.NormalFontSize
    node.TouchEnabled = false
    node.SwallowTouchEnabled = false
    node.Position = Vector2.New(x + spread, y)
    node.Opacity = 1
    node.Visible = true
    node.LocalZOrder = 10
    local entry = { node = node, start = game:GetService('World'):GetServerTime(),
        position = payload.position, height = payload.height, spread = spread }
    self.active[#self.active + 1] = entry
end

function DamageFloat:update()
    if not self.root then return end
    if #self.pending_cleanup > 0 then
        local pending = self.pending_cleanup
        self.pending_cleanup = {}
        for _, node in ipairs(pending) do
            local ok, err = pcall(function() node:Destroy() end)
            if not ok then
                print('[DamageFloat] 重试清理失败', tostring(err))
                self.pending_cleanup[#self.pending_cleanup + 1] = node
            end
        end
    end
    local now = game:GetService('World'):GetServerTime()
    for i = #self.active, 1, -1 do
        local entry = self.active[i]
        local progress = math.max(0, (now - entry.start) / cfg.DurationSec)
        if progress >= 1 then
            entry.node.Visible = false
            entry.node.Opacity = 1
            table.remove(self.active, i)
            if #self.pool < cfg.PoolSize then
                self.pool[#self.pool + 1] = entry.node
            else
                entry.node:Destroy()
            end
        else
            local x, y = self:project(entry.position, entry.height)
            entry.node.Visible = x ~= nil
            if x then
                entry.node.Position = Vector2.New(x + entry.spread, y + cfg.RisePixels * progress)
                entry.node.Opacity = 1 - progress
            end
        end
    end
end

return DamageFloat
