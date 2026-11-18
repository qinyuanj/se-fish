-- 运行期单位归属登记（common/OwnedUnits.lua，#207）：纯 Lua、无引擎依赖，直接 require 模块即可验证。
-- 失败方式（先列后写）：
--   1. 登记不返回单位本身 → 「建并登记」一行写不成，调用方拿不到节点；
--   2. 清空不销毁名下单位、清空后计数不清零 → 节点留在场上，登记表成泄漏源；
--   3. 同一单位重复登记被算成两个 → 计数虚高，同一节点被销毁两次；
--   4. 单个单位销毁失败打断整次清空 → 其余单位无人回收；
--   5. 销毁失败的单位留在登记表里 → 计数永远清不掉；
--   6. 清空不幂等（第二次调用报错）或误伤别的所有者名下的单位。
-- seam：只有对外三件事 Track / Clear / Count；所有者每次用新的表或字符串，用例之间不共享状态。
local OwnedUnits = require("common.OwnedUnits")

--- 自带销毁标记的单位；Destroys 用来抓「同一单位被销毁两次」。
local function unit()
  local node = { Destroyed = false, Destroys = 0 }
  node.Destroy = function(self)
    self.Destroyed = true
    self.Destroys = self.Destroys + 1
  end
  return node
end

describe("运行期单位归属登记（common/OwnedUnits）", function()
  local logs, printBackup

  -- 失败日志是清空契约的一部分（失败信息落一条日志），逐例抓取并原样还回全局。
  before_each(function()
    logs = {}
    -- 被测模块读的是 _G 上的真 print；测试文件里的名字赋值进不了 _G（Busted 环境按 _G 回退），替身要显式写 _G。
    printBackup = _G.print
    _G.print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      logs[#logs + 1] = table.concat(parts, " ")
    end
  end)

  after_each(function()
    _G.print = printBackup
  end)

  it("test_track_returns_the_unit_and_counts_it", function()
    local owner = {}
    local first, second = unit(), unit()
    assert.equal(first, OwnedUnits.Track(owner, first))
    assert.same(1, OwnedUnits.Count(owner))
    assert.equal(second, OwnedUnits.Track(owner, second))
    assert.same(2, OwnedUnits.Count(owner))
    assert.same({}, logs)
  end)

  it("test_duplicate_track_counts_once_and_destroys_once", function()
    -- 所有者可以是字符串标识；反复登记同一单位只算一个、只销毁一次。
    local node = unit()
    OwnedUnits.Track("ScreenX", node)
    OwnedUnits.Track("ScreenX", node)
    assert.same(1, OwnedUnits.Count("ScreenX"))
    OwnedUnits.Clear("ScreenX")
    assert.same(1, node.Destroys)
    assert.is_true(node.Destroyed)
    assert.same(0, OwnedUnits.Count("ScreenX"))
  end)

  it("test_clear_destroys_only_its_own_units_and_is_idempotent", function()
    local mine, other = {}, {}
    local a, b, theirs = unit(), unit(), unit()
    OwnedUnits.Track(mine, a)
    OwnedUnits.Track(mine, b)
    OwnedUnits.Track(other, theirs)
    OwnedUnits.Clear(mine)
    assert.is_true(a.Destroyed)
    assert.is_true(b.Destroyed)
    assert.is_false(theirs.Destroyed) -- 别人的单位不动
    assert.same(0, OwnedUnits.Count(mine))
    assert.same(1, OwnedUnits.Count(other))
    OwnedUnits.Clear(mine) -- 幂等：重复清空不报错
    assert.same(0, OwnedUnits.Count(mine))
    assert.same({}, logs)
  end)

  it("test_one_failed_destroy_does_not_block_the_rest_and_still_clears_the_record", function()
    local owner = {}
    local broken = { Destroy = function() error("boom") end }
    local survivor = unit()
    OwnedUnits.Track(owner, broken)
    OwnedUnits.Track(owner, survivor)
    OwnedUnits.Clear(owner)
    assert.is_true(survivor.Destroyed, "单个单位销毁失败不应阻断其余单位")
    assert.same(0, OwnedUnits.Count(owner), "销毁失败的单位也要从登记表摘掉")
    assert.same(1, #logs)
    assert.matches("boom", logs[1], nil, true)
  end)
end)
