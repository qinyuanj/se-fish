-- 离线基线（#82 接共享配置基线）：Busted helper tests/native/helper.lua 从这里取基线，
-- 避免同一份配置在两处各写一遍（改一处忘另一处会让结果不可比）。
-- 只修改本测试进程的配置：业务默认保持关闭调试，编辑器验收槽不影响离线用例。
-- 专门验证关闭调试/切换槽的用例仍在自己的 set_up 或测试体里覆盖并恢复这些字段。
local M = {}

local GameCfg = require("common.game_cfg")
local ZoneFixtures = require("tests.support.zone_fixtures")

ZoneFixtures.apply(GameCfg)

function M.apply()
  GameCfg.Debug = { Enabled = true, InitialGrants = GameCfg.Debug.InitialGrants }
  GameCfg.Save.QaSlot = ""
  return GameCfg
end

function M.snapshot()
  return { Debug = GameCfg.Debug, QaSlot = GameCfg.Save.QaSlot }
end

-- 部分 setup 失败时也要能恢复：调用方（tests/native/helper.lua 的 after_each）
-- 不依赖测试体是否跑过。
function M.restore(snapshot)
  if not snapshot then
    return M.apply()
  end
  GameCfg.Debug = snapshot.Debug
  GameCfg.Save.QaSlot = snapshot.QaSlot
  return GameCfg
end

return M
