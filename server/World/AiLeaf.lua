-- 官方 AI 包的单向输出叶子（ADR-0032 / #309）。
-- 仇恨与阶段真源在 FishTree。本叶子只把当前指令写进官方包，并在清理时对称注销。
-- 不持有玩法计时，不反向依赖旧管理器。

local AiLeaf = {}

function AiLeaf.attach(scope, opts)
  opts = opts or {}
  local ai = opts.ai
  local started = false
  if type(ai) == "table" and type(ai.start) == "function" then
    local ok = ai.start(ai, opts.fish_id, opts.unit)
    started = ok ~= false
  end
  local leaf = {
    stop = function(self)
      if not started then return end
      started = false
      if type(ai) == "table" and type(ai.stop) == "function" then
        ai.stop(ai, opts.fish_id, opts.unit)
      end
    end,
  }
  if scope and type(scope.on_cleanup) == "function" then
    scope:on_cleanup(function()
      leaf:stop()
    end)
  end
  return leaf
end

return AiLeaf
