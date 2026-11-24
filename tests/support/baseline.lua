-- 离线基线（#82 接共享基线接缝）：Busted helper tests/native/helper.lua 从这里取基线，
-- 避免同一份配置在两处各写一遍（改一处忘另一处会让结果不可比）。
-- 只修改本测试进程的配置：业务默认保持关闭调试，编辑器验收槽不影响离线用例。
-- 专门验证关闭调试/切换槽的用例仍在自己的 setUp 或测试体里覆盖并恢复这些字段。
local M = {}

local game_cfg = require("common.game_cfg")
local zone_fixtures = require("tests.support.zone_fixtures")

zone_fixtures.Apply(game_cfg)

function M.apply()
  game_cfg.Debug = { Enabled = true, InitialGrants = game_cfg.Debug.InitialGrants }
  game_cfg.Save.QaSlot = ""
  return game_cfg
end

function M.snapshot()
  return { Debug = game_cfg.Debug, QaSlot = game_cfg.Save.QaSlot }
end

-- 部分 setup 失败时也要能恢复：调用方（tests/native/helper.lua 的 after_each）
-- 不依赖测试体是否跑过。
function M.restore(snapshot)
  if not snapshot then
    return M.apply()
  end
  game_cfg.Debug = snapshot.Debug
  game_cfg.Save.QaSlot = snapshot.QaSlot
  return game_cfg
end

return M
