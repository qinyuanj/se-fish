-- #135 独立战斗夹具：从真实SpawnLanded/Drop入口生成指定600/1200血鱼，用于招式表现取证。
-- 明确不作为自然抽鱼/从零经济证明；不修改血量、时间、玩家库存或奖励裁决。
local ServerRuntime = require('server.World.ServerRuntime')
local runtime = ServerRuntime.current()
local units = (runtime and runtime.fish_host) or require('server.World.FishTree')
local life = runtime and runtime.life
local player = game:GetService('Players'):GetPlayers()[1]
if not player or not player.Character then return end
local id = _G.Shrimp135Species or 'fish15Elite'
_G.Shrimp135CombatToken = (_G.Shrimp135CombatToken or 0) + 1
local runId = _G.Shrimp135CombatToken
local p = player.Character.Position
local fish, err = units:SpawnLanded(player, { fishId = id, mult = 1 }, Vector3.New(p.x, p.y, p.z + 2))
print('SHRIMP135_FIXTURE', id, fish and fish.Id, err)
if fish then
    game:GetService('Task'):Delay(2, function()
        if _G.Shrimp135CombatToken == runId and units.Fish[fish.Id] == fish then
            units:Drop(player)
            print('SHRIMP135_RELEASE', fish.Id, fish.State, fish.Carrier.Health, fish.Carrier.Body.Position)
            if _G.Shrimp135Observe then
                local task = game:GetService('Task')
                task:Spawn(function()
                    local world = game:GetService('World')
                    local started, last = world:GetServerTime(), nil
                    while _G.Shrimp135CombatToken == runId and units.Fish[fish.Id] == fish and world:GetServerTime() - started < 45 do
                        local move = fish.Move
                        local name = move and move.Name or fish.State
                        if name ~= last then
                            print('SHRIMP135_BEHAVIOR', fish.Id, name, player.Character.Controller.Health,
                                fish.WakeAt, world:GetServerTime() - started)
                            last = name
                        end
                        if life and life:CanAct(player) then
                            local fp = fish.Carrier.Body.Position
                            if name == 'rain' then
                                player.Character.Position = Vector3.New(fp.x + 12, fp.y, fp.z)
                            elseif name == 'dive' then
                                local dest = move.Destination
                                player.Character.Position = Vector3.New(dest.x, move.Center.y, dest.z)
                            elseif fish.State ~= 'stunned' then
                                local forward = fish.Carrier.Body.Rotation:GetForward()
                                player.Character.Position = Vector3.New(fp.x - forward.x * 1.5, fp.y, fp.z - forward.z * 1.5)
                            end
                        end
                        task:Wait(0.1)
                    end
                    print('SHRIMP135_BEHAVIOR_END', fish.Id, player.Character.Controller.Health)
                end)
            end
            if _G.Shrimp135Attack then
                local data = require('server.PlayerDataHost'):GetDataInst(player)
                local world, task = game:GetService('World'), game:GetService('Task')
                local started = world:GetServerTime()
                print('SHRIMP135_INPUT', '主动定位并面向目标；真实攻击，不改血量/时间', data:WeaponDamageScale('melee'))
                task:Spawn(function()
                    while _G.Shrimp135CombatToken == runId and units.Fish[fish.Id] == fish and world:GetServerTime() - started < 100 do
                        local fp = fish.Carrier.Body.Position
                        local forward = fish.Carrier.Body.Rotation:GetForward()
                        local character = player.Character
                        if character and character.Controller and life and life:CanAct(player) then
                            character.Position = Vector3.New(fp.x - forward.x * 1.5, fp.y, fp.z - forward.z * 1.5)
                            character.Rotation = fish.Carrier.Body.Rotation
                        end
                        local before = fish.Carrier.Health
                        local ok = life and life:WeaponAction(player, { action = 'attack' }) or false
                        print('SHRIMP135_ATTACK', fish.Id, before, ok, character and character.Controller and character.Controller.Health,
                            world:GetServerTime() - started)
                        task:Wait(0.5)
                    end
                    print('SHRIMP135_END', fish.Id, fish.State, fish.Carrier.Health, world:GetServerTime() - started)
                end)
            end
        end
    end)
end
