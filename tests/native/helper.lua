-- Busted 共享初始化（#81 建立，#82 接共享配置基线）：由 .busted 的 helper 在任何案例文件发现/加载前执行；
-- helper 失败则整个运行退出。基线来自 tests/support/baseline.lua，避免同一份配置在两处各写一遍。
-- 返回的函数注册根级 before_each/after_each：每案例快照并在 after_each 恢复共享配置。
-- before_each 失败时 Busted 仍从失败层向上执行 after_each，因此部分 setup 失败也完成清理，修改不泄漏到后续案例。
-- 逐例快照/还原 GameCfg.Debug 与 Save.QaSlot 的语义与旧 LuaUnit 套件一致：旧入口只在进程启动时设一次基线，
-- 但每个旧测试文件自己 set_up 存、tear_down 还原这两个字段，实际效果就是逐例隔离，这里换的只是钩子名，没引入新行为。
-- 边际差别是更稳：after_each 无条件执行，旧 tear_down 在断言提前失败时会跳过还原。
-- 本 helper 只做上述逐例快照，不负责跨文件隔离：跨文件靠 .busted 显式开启的 auto-insulate（#135），
-- 它在每个文件结束后按键还原 _G 与 package.loaded；对已加载表的原地字段修改不在其还原范围内。

package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

-- 引擎 Vector3 是生产公开类型；测试进程未启动编辑器时由共享夹具提供同形构造器。
if rawget(_G, "Vector3") == nil then
  local vector_mt = {
    __add = function(a, b) return _G.Vector3.New(a.x + b.x, a.y + b.y, a.z + b.z) end,
    __sub = function(a, b) return _G.Vector3.New(a.x - b.x, a.y - b.y, a.z - b.z) end,
    __mul = function(a, b)
      if type(a) == "number" then return _G.Vector3.New(a * b.x, a * b.y, a * b.z) end
      return _G.Vector3.New(a.x * b, a.y * b, a.z * b)
    end,
  }
  vector_mt.__index = { Length = function(self) return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end }
  _G.Vector3 = { New = function(x, y, z) return setmetatable({ x = x, y = y, z = z }, vector_mt) end }
end

local baseline = require("tests.support.baseline")
baseline.apply()

-- 复用模块源码的编译结果：夹具重建世界时清掉 package.loaded 再 require，模块表照样全新，
-- 只是不再逐例重新解析源码（ferry_test 的世界宿主 35 个模块：18.6 ms 里 14.6 ms 是编译）。
require("tests.support.module_cache").install()

return function(busted)
  local snapshot
  busted.executors.before_each(function()
    snapshot = baseline.snapshot()
  end)
  busted.executors.after_each(function()
    baseline.restore(snapshot)
    snapshot = nil
  end)
  return true
end
