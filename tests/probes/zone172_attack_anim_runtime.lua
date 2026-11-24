-- #172 出手动作试玩复测（试玩服务端）：给第一个玩家发放并手持 WEAPON（'unarmed' 为空手，'throw' 为投掷鞭炮），
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
local ServerRuntime = require('server.World.ServerRuntime')
local PlayerDataHost = require('server.PlayerDataHost')
local REUtil = require('common.REUtil')
local runtime = assert(ServerRuntime.current(), MARK .. ': ServerRuntime 未启动')
local life = assert(runtime.life, MARK .. ': ServerRuntime.life 不可用')
local player = game:GetService('Players'):GetPlayers()[1]
assert(player and player.Character, MARK .. ': 没有玩家角色')
local data = assert(PlayerDataHost:GetDataInst(player), MARK .. ': 存档未就绪')
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
  PlayerDataHost:SyncPlayerTree(player, true)
  print(MARK .. '|' .. WEAPON .. '|held=' .. tostring(held.id))
end
if PHASE == 'hold' then return end
local function captureWeaponAction(payload)
  local event = REUtil:GetRE('WeaponResult')
  local original = event and event.FireClient
  local reply
  if event and original then
    event.FireClient = function(self, target, body)
      if target == player then reply = body end
      return original(self, target, body)
    end
  end
  local ok, accepted = pcall(life.WeaponAction, life, player, payload)
  if event and original then event.FireClient = original end
  if not ok then error(accepted) end
  return accepted, reply
end
if WEAPON == 'throw' then
  anim = ability.Throw.Anim
  local barId = GameCfg.Items.ContainerId.ItemBar
  local bar = data.Data.Containers[barId]
  local slot
  for s = 1, data:ItemBarCapacity() do
    local e = bar[s]
    if e and e.itemId == 'item143' and e.count > 0 then slot = s break end
  end
  if not slot then
    data:AddItem('item143')
    for s = 1, data:ItemBarCapacity() do
      local e = bar[s]
      if e and e.itemId == 'item143' and e.count > 0 then slot = s break end
    end
    if not slot then
      local bp = data.Data.Containers[GameCfg.Items.ContainerId.Backpack]
      for i = 1, data:BackpackCapacity() do
        if bp[i] and bp[i].itemId == 'item143' and bp[i].count > 0 then
          data:MoveSlot(GameCfg.Items.ContainerId.Backpack, i, barId, 1)
          slot = 1
          break
        end
      end
    end
  end
  assert(slot, MARK .. ': 无法把 item143 放入道具栏')
  if data.Data.SelectedSlot ~= slot then data:SelectSlot(slot) end
  PlayerDataHost:SyncPlayerTree(player, true)
  _G.AAR172Seq = (_G.AAR172Seq or 0) + 1
  local accepted, reply = captureWeaponAction({ action = 'throw', slot = slot, seq = _G.AAR172Seq })
  print(MARK .. '|' .. WEAPON .. '|launch accepted=' .. tostring(accepted)
    .. ' ok=' .. tostring(reply and reply.ok) .. ' reason=' .. tostring(reply and reply.reason))
else
  local row = WEAPON == 'unarmed' and ability.Unarmed or ability.MeleeWeapons[WEAPON] or ability.Guns[WEAPON]
  anim = row and row.Anim
  local accepted, reply = captureWeaponAction({ action = 'attack' })
  print(MARK .. '|' .. WEAPON .. '|attack accepted=' .. tostring(accepted)
    .. ' ok=' .. tostring(reply and reply.ok) .. ' reason=' .. tostring(reply and reply.reason)
    .. ' weapon=' .. tostring(reply and reply.weapon))
end
-- exec 里 Task:Wait 会让后续语句静默不执行（2026-11-04 实测），延时读取改走 TimerService
local character = player.Character
game:GetService('TimerService'):CreateTimer(1, 0.15, false, function()
  local animator = character and character.Animator
  local ok, tracks = pcall(function() return animator and animator:GetPlayingAnimationTracks() end)
  local track
  if ok and type(tracks) == 'table' then
    for _, candidate in ipairs(tracks) do
      local idOk, id = pcall(function() return candidate.Animation and candidate.Animation.AnimationId end)
      if idOk and id == anim then track = candidate break end
    end
  end
  if not track then
    print(MARK .. '|' .. WEAPON .. '|anim=' .. tostring(anim) .. '|NO_TRACK')
    return
  end
  local function read(key) local okRead, v = pcall(function() return track[key] end); return tostring(okRead and v) end
  print(MARK .. '|' .. WEAPON .. '|anim=' .. tostring(anim) .. '|playing=' .. read('IsPlaying') .. '|t=' .. read('TimePosition')
    .. '|len=' .. read('Length') .. '|filter=' .. read('FilterType') .. '|priority=' .. read('Priority'))
end)
