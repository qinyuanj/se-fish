-- #136 蟹湖真实试玩探针：只走公开请求与正常装备攻击，不加金币/库存、不改血量/时间/坐标。
-- 试玩就绪后：editor-cli exec -p server --file <本文件绝对路径> --json。
-- 持续输出每招、伤害前后血量和收招；需玩家正常钓出鱼并放到岸上，再站到目标鱼攻击距离内。
-- 若已拥有信物，在本区钓鱼佬旁选中信物后重跑会执行Feed；摆渡使用正常board请求。
local cfg = require('common.game_cfg')
local pd = require('server.player_data_host')
local ServerRuntime = require('server.world_host.server_runtime')
local runtime = ServerRuntime.current()
local units = (runtime and runtime.fish_host) or require('server.world_host.fish_tree')
local life = runtime and runtime.life
local ferry = runtime and runtime:get_world() and runtime:get_world().ferry
local function equippedWeapon(d)
    if not d then return nil end
    local held = d.Extra and d.Extra.inventory and d.Extra.inventory.selection
        and d.Extra.inventory.selection.held
    if type(held) == 'table' and held.kind == 'weapon' and d:WeaponCount(held.id) > 0 then
        return held.id
    end
    local selected = d.Data and d.Data.SelectedWeapon
    if selected and d:WeaponCount(selected) > 0 then return selected end
    return nil
end
local world, task = game:GetService('World'), game:GetService('Task')
local player = game:GetService('Players'):GetPlayers()[1]
if not player then print('CRAB136 ABORT 没有玩家') return end
local data = pd:get_data_inst(player)
if not data then print('CRAB136 ABORT 存档未就绪') return end
_G.Crab136 = _G.Crab136 or { token = 0, seq = 136000 }
local rt = _G.Crab136
rt.token, rt.seq = rt.token + 1, rt.seq + 1
local token = rt.token
local tag = 'C136-' .. tostring(math.floor(world:GetServerTime()))
local function log(...) print('CRAB136', tag, ...) end
local function ledger()
    log('库存', 'coin=' .. tostring(data.Data.FishCoin), 'zone=' .. tostring(data.Data.Zone),
        'shell=' .. data:ItemCount('item47'), 'eye=' .. data:ItemCount('item122'),
        'claw=' .. data:ItemCount('item48'), 'ticket=' .. data:ItemCount('item148'),
        'weapon=' .. tostring(equippedWeapon(data)))
end
ledger()
local snap = data:GetItemBarSnapshot()
local slot = snap.selectedSlot and snap.slots[snap.selectedSlot]
if slot and (slot.itemId == 'item47' or slot.itemId == 'item48') then
    log('兑换请求', slot.itemId)
    local runtime = ServerRuntime.current and ServerRuntime.current()
    if runtime then runtime:dispatch_interact(player, { target = 'fisherman', action = 'Feed', seq = rt.seq }) end
end
-- 外部选择rt.routeId后可重跑：日志记录实际航线与扣款，不默认移动玩家。
if rt.routeId then
    ferry:Handle(player, { action = 'Board', routeId = rt.routeId, seq = rt.seq + 1 })
    log('摆渡请求', rt.routeId)
    rt.routeId = nil
end
local last = {}
task:Spawn(function()
    local untilAt = world:GetServerTime() + 75
    while rt.token == token and world:GetServerTime() < untilAt do
        for id, fish in pairs(units.Fish) do
            if fish.FishId == 'fish23Elite' or fish.FishId == 'fish24Boss' then
                local move = fish.Move and fish.Move.Name or '-'
                local state = fish.State .. ':' .. move
                if last[id] ~= state then
                    log('招式', id, fish.FishId, state, 'health=' .. tostring(fish.Carrier.Health),
                        'wake=' .. tostring(fish.WakeAt), 'flee=' .. tostring(fish.FleeAt))
                    last[id] = state
                end
                local p, cp = fish.Carrier.Body.Position, player.Character and player.Character.Position
                local weaponId = equippedWeapon(data)
                local weapon = cfg.Ability.MeleeWeapons[weaponId]
                -- 自然购买的金币近战武器才计正常击杀；探针不装备或赠送武器。
                if weapon and p and cp and (p.x-cp.x)^2 + (p.z-cp.z)^2 <= weapon.Range^2 then
                    local before = fish.Carrier.Health
                    local ok = life and life:weapon_action(player, { action = 'attack' }) or false
                    if ok then log('正常攻击', fish.FishId, weaponId, 'before=' .. tostring(before)) end
                end
            end
        end
        for id in pairs(last) do
            if not units.Fish[id] then log('鱼已移除', id); last[id] = nil; ledger() end
        end
        log('玩家血量', player.Character and player.Character.Controller.Health)
        task:Wait(0.5)
    end
    ledger()
    log('观察结束')
end)
