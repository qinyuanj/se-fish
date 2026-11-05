-- #177 官方包升级试玩复测（试玩服务端）：走业务真实入口，核对升级后技能与效果（Buff）的可观测行为。
-- 技能：槽位 0 挥砍已装配；空手 MgrWeapon:Attack 经 server/AbilityAPI 守卫进包内 CastAbility，随后进入施法态。
-- 效果：MgrModifier 获得虚弱 20 秒、麻痹 3 秒、两次中毒；实体 RemoveMode=0；中毒叠到 2 层；
--       1 秒后虚弱余 ~19、麻痹生效；4 秒后麻痹与中毒到期；随后 Clear 移除虚弱。
-- 复跑：editor-cli exec --file tests/probes/package_upgrade_177_runtime.lua --platform server
--       约 5 秒后 editor-cli log grep PU177 --platform server --context 0
-- 会给第一个玩家挂效果（中毒扣少量血），只在试玩里跑。
local MARK = 'PU177'
local GameCfg = require('common.GameCfg')
local AbilityPackageAPI = require('server.packages.ability_system.api')
local Weapon = require('server.Mgr.MgrWeapon')
local Modifier = require('server.Mgr.MgrModifier')
local player = game:GetService('Players'):GetPlayers()[1]
assert(player and player.Character, MARK .. ': 没有玩家角色')
local character = player.Character
local function out(...) print(MARK .. '|' .. table.concat({ ... }, '|')) end
local function attr(unit, key)
  local ok, value = pcall(function() return unit:GetAttribute(key) end)
  return tostring(ok and value)
end

local slot = GameCfg.Ability.InitialAbilities[1].Index
local script = AbilityPackageAPI.GetAbility(character, slot)
out('ability', 'slot=' .. tostring(slot), 'found=' .. tostring(script ~= nil),
  'preset=' .. (script and attr(script, 'AbilityPresetKey') or 'nil'),
  'cd=' .. (script and attr(script, 'CdTime') or 'nil'), 'castTime=' .. (script and attr(script, 'CastTime') or 'nil'))
local handler = script and AbilityPackageAPI.GetAbilityByScript(script)
local reply = Weapon:Attack(player)
out('attack', 'ok=' .. tostring(reply and reply.ok), 'reason=' .. tostring(reply and reply.reason),
  'inCast=' .. tostring(handler and handler.getInCast and handler.getInCast()))

local function entity(kind)
  local st = Modifier.Targets
  for _, entry in pairs(st) do
    if entry.ref == player and entry.effects[kind] then return entry.effects[kind].entity end
  end
end
out('apply', 'weak=' .. tostring(Modifier:Apply(nil, player, 'weak', 20)),
  'paralyze=' .. tostring(Modifier:Apply(nil, player, 'paralyze', 3)),
  'poison1=' .. tostring(Modifier:Apply(nil, player, 'poison')),
  'poison2=' .. tostring(Modifier:Apply(nil, player, 'poison')))
local weak, poison = entity('weak'), entity('poison')
out('entity', 'weakRemoveMode=' .. (weak and attr(weak, 'RemoveMode') or 'nil'),
  'poisonCount=' .. (poison and attr(poison, 'CurrCount') or 'nil'))

local timers = game:GetService('TimerService')
local function snapshot(tag)
  out(tag, 'weak=' .. string.format('%.2f', Modifier:GetRemaining(player, 'weak')),
    'paralyze=' .. string.format('%.2f', Modifier:GetRemaining(player, 'paralyze')),
    'poison=' .. string.format('%.2f', Modifier:GetRemaining(player, 'poison')),
    'controlled=' .. tostring(Modifier:IsControlled(player)),
    'inCast=' .. tostring(handler and handler.getInCast and handler.getInCast()))
end
timers:CreateTimer(1, 1, false, function() snapshot('t1') end)
timers:CreateTimer(1, 4, false, function()
  snapshot('t4')
  Modifier:Clear(player, 'weak')
  timers:CreateTimer(1, 0.2, false, function() snapshot('cleared') end)
end)
