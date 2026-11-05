-- #172 出手动作客户端取证（试玩客户端，只读）：WINDOW 秒内每帧读本地角色 Animator:GetPlayingAnimationTracks，
-- 出手动画（ID 与 GameCfg.AttackAnim 一致，沙盒不能 require，故以字面量嵌入）首次出现时打一行，窗口结束打汇总
-- （最大播放进度、长度）。服务端轨道 IsPlaying 恒 false、Length=0（2026-11-04 实测），所以播放与否以客户端为准。
-- 复跑：试玩中先 exec 本文件（--platform client），窗口内再逐类跑 zone172_attack_anim_runtime.lua（server），
--       最后 editor-cli log grep AAC172 --platform client --context 0
local MARK = 'AAC172'
local WINDOW = 45
local WATCH = {
  ['official://animation/24318'] = '空手', ['official://animation/24315'] = '指虎',
  ['official://animation/24287'] = '匕首组', ['official://animation/24358'] = '斧组',
  ['official://animation/24322'] = '手枪组', ['official://animation/24323'] = '霰弹与狙击',
  ['official://animation/24324'] = '自动枪', ['official://animation/24325'] = '火箭筒',
  ['official://animation/26646'] = '投掷',
}
local seen = {}
local player = game:GetService('Players').LocalPlayer
local function animationId(track)
  local ok, id = pcall(function() return track.Animation.AnimationId end)
  return ok and id or nil
end
local connection
connection = game:GetService('RunService').Heartbeat:Connect(function()
  local character = player and player.Character
  local animator = character and character.Animator
  if not animator then return end
  local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
  if not ok or type(tracks) ~= 'table' then return end
  for _, track in ipairs(tracks) do
    local id = animationId(track)
    if id and WATCH[id] then
      local t = tonumber(track.TimePosition) or 0
      local entry = seen[id]
      if not entry then
        entry = { maxT = t, len = tonumber(track.Length) or 0 }
        seen[id] = entry
        print(MARK .. '|SEEN|' .. WATCH[id] .. '|' .. id .. '|len=' .. tostring(entry.len) .. '|filter=' .. tostring(track.FilterType))
      elseif t > entry.maxT then
        entry.maxT = t
      end
    end
  end
end)
game:GetService('TimerService'):CreateTimer(1, WINDOW, false, function()
  connection:Disconnect()
  for id, label in pairs(WATCH) do
    local entry = seen[id]
    print(MARK .. '|SUM|' .. label .. '|' .. (entry and string.format('maxT=%.3f|len=%.3f', entry.maxT, entry.len) or 'NOT_SEEN'))
  end
  print(MARK .. '|END')
end)
print(MARK .. '|START|window=' .. WINDOW)
