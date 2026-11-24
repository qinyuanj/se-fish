-- #139 [专项探针]：真实服务器上的成长、四类持续效果与十五件武器配置取证（已迁移至 Spoke ServerRuntime / PlayerTree）。
-- 用 exec -p server --file 执行；临时修改会话内成长计数后恢复，不代表真实存档重进验收。
-- 不自动发奖、不提交存档、不模拟多人；拾取/钓鱼/摆渡及真实枪击/挥砍另列真机遗留。
local cfg = require('common.game_cfg')
local ability = require('server.fish_ability')
local pd = require('server.player_data_host')
local ServerRuntime = require('server.world_host.server_runtime')
local players, task = game:GetService('Players'), game:GetService('Task')
local player = players:GetPlayers()[1]
local data = player and pd:get_data_inst(player)
local rt = ServerRuntime.current()
local pt = player and rt and rt:get_player_tree(player.UserId)
if not data or not pt or not player.Character or not player.Character.Controller then
    print('PRIZE139 ABORT 玩家、存档或 PlayerTree 未就绪') return
end
local function log(...) print('PRIZE139', '[专项探针]', ...) end
local growth = data.extra.growth.potions
local oldSpeed, oldBody = growth.item167, growth.item168
local life = rt.life
local oldWeak = pt:get_modifier_remaining('weak')
local controller = player.Character.Controller
local function attrs(label)
    log(label, 'speed=' .. tostring(controller.WalkSpeed), 'max_health=' .. tostring(controller.MaxHealth),
        'planScale=' .. tostring(ability:body_plan(player).Scale), 'canAct=' .. tostring(life:can_act(player)))
end
for n = 152, 166 do
    local id = 'item' .. tostring(n)
    local entry = cfg.Ability.MeleeWeapons[id] or cfg.Ability.Guns[id]
    log('武器配置', id, 'damage=' .. tostring(entry.Damage), 'interval=' .. tostring(entry.IntervalSec),
        'magazine=' .. tostring(entry.Magazine), 'effect=' .. tostring(entry.Effect and entry.Effect.Kind),
        'splash=' .. tostring(entry.Splash and entry.Splash.Damage))
end
task:Spawn(function()
    local ok, err = pcall(function()
        pt:clear_all_modifiers(false)
        growth.item167, growth.item168 = 20, 10
        ability:apply_growth(player)
        attrs('成长20/10')
        growth.item167, growth.item168 = 21, 11
        ability:apply_growth(player)
        attrs('夹值21/11（非饮用通道）')
        growth.item167, growth.item168 = 20, 10
        pt:apply_modifier('weak', { duration = 60 }); attrs('虚弱'); pt:clear_modifier('weak'); attrs('虚弱消退')
        for _ = 1, 6 do
            pt:apply_modifier('poison', { source = player })
            pt:apply_modifier('burn', { source = player })
        end
        log('层上限', 'poison=' .. tostring(pt:get_modifier_stacks('poison')), 'burn=' .. tostring(pt:get_modifier_stacks('burn')))
        pt:apply_modifier('frost', { source = player })
        pt:apply_modifier('frost', { source = player })
        attrs('霜冻重复')
        pt:apply_modifier('paralyze', { source = player })
        attrs('麻痹')
        task:Wait(0.7)
        attrs('麻痹到期')
        task:Wait(3)
        attrs('效果到期')
        local allCleared = pt:get_modifier_remaining('poison') == 0
            and pt:get_modifier_remaining('burn') == 0
            and pt:get_modifier_remaining('frost') == 0
            and pt:get_modifier_remaining('paralyze') == 0
        log('效果清理', tostring(allCleared))
    end)
    growth.item167, growth.item168 = oldSpeed, oldBody
    pt:clear_all_modifiers(false)
    if oldWeak > 0 then pt:apply_modifier('weak', { duration = oldWeak }) end
    ability:apply_growth(player)
    log('恢复完成', 'ok=' .. tostring(ok), 'error=' .. tostring(err))
end)
