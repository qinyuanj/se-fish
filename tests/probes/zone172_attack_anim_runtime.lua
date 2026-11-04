-- #172 出手动作试玩复测（试玩服务端）：给第一个玩家发放并手持 WEAPON（'unarmed' 为空手，'throw' 为投掷鞭炮），
-- 走 MgrWeapon 真实出手入口，0.15 秒后读该动画 track 的 IsPlaying / TimePosition / Length。
-- 复跑：把 WEAPON 改成要测的一类（unarmed、item134 指虎、item135 匕首、item136 斧头、item137 手枪、item138 霰弹、
--       item139 冲锋枪、item142 火箭筒、throw）后
--       editor-cli exec --file tests/probes/zone172_attack_anim_runtime.lua --platform server
--       editor-cli log grep AAR172 --platform server --context 0
-- 会改动试玩存档（发放武器），只在试玩里跑。画面证据另用 screenshot game 截连帧。
local WEAPON = 'unarmed'
-- PHASE：'hold' 只换手持（换武器模型本身会改画面）、'fire' 只出手、'both' 两步连做；截连帧取证时先 hold 再 fire
local PHASE = 'both'
local MARK = 'AAR172'
local GameCfg = require('common.GameCfg')
local Weapon = require('server.Mgr.MgrWeapon')
local player = game:GetService('Players'):GetPlayers()[1]
assert(player and player.Character, MARK .. ': 没有玩家角色')
local data = _G.MgrPlayerData:GetDataInst(player)
local ability = GameCfg.Ability
local anim
if PHASE ~= 'fire' and WEAPON ~= 'throw' then
  -- HoldWeapon 对已握的同一把再调会收起：空手时借此收起；武器已握时跳过。
  -- 空手不调 HoldWeapon(nil)：PlayerData isWeapon 对非字符串参数会索引 false 报错（2026-11-04 试玩实测）。
  local held = data.Extra.inventory.selection.held
  if WEAPON == 'unarmed' then
    if held.kind == 'weapon' then data:HoldWeapon(held.id) end
  elseif not (held.kind == 'weapon' and held.id == WEAPON) then
    data:GrantWeapon(WEAPON, 1)
    data:HoldWeapon(WEAPON)
  end
  -- 枪械清掉弹匣状态，下次出手按满匣重建（火箭筒只有 1 发，复跑时常是空匣）
  if ability.Guns[WEAPON] then Weapon:GetState(player.UserId).mags[WEAPON] = nil end
  print(MARK .. '|' .. WEAPON .. '|held=' .. tostring(held.id))
end
if PHASE == 'hold' then return end
if WEAPON == 'throw' then
  anim = ability.Throw.Anim
  Weapon:Launch(player, 'item143', nil)
  print(MARK .. '|' .. WEAPON .. '|launch')
else
  local row = WEAPON == 'unarmed' and ability.Unarmed or ability.MeleeWeapons[WEAPON] or ability.Guns[WEAPON]
  anim = row and row.Anim
  local reply = Weapon:Attack(player)
  print(MARK .. '|' .. WEAPON .. '|attack ok=' .. tostring(reply and reply.ok) .. ' reason=' .. tostring(reply and reply.reason)
    .. ' weapon=' .. tostring(reply and reply.weapon))
end
-- exec 里 Task:Wait 会让后续语句静默不执行（2026-11-04 实测），延时读取改走 TimerService
local character = player.Character
game:GetService('TimerService'):CreateTimer(1, 0.15, false, function()
  local tracks = Weapon.AnimTracks[character]
  local track = tracks and tracks[anim]
  if not track then
    print(MARK .. '|' .. WEAPON .. '|anim=' .. tostring(anim) .. '|NO_TRACK')
    return
  end
  local function read(key) local ok, v = pcall(function() return track[key] end); return tostring(ok and v) end
  print(MARK .. '|' .. WEAPON .. '|anim=' .. tostring(anim) .. '|playing=' .. read('IsPlaying') .. '|t=' .. read('TimePosition')
    .. '|len=' .. read('Length') .. '|filter=' .. read('FilterType') .. '|priority=' .. read('Priority'))
end)
