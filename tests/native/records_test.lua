-- 原生 Busted（#87 迁移自 tests/gameplay/records_test.lua 的 TestRecordsCore / TestRecordsService /
-- TestRecordsIntegration）。
-- #149 T28 全服纪录。失败方式（先列后写）：
--   1. 重量两位小数被截成整数或写成浮点，放大/还原不对称，误差随写入放大；
--   2. 更小的重量覆盖了更大纪录；同重量两次请求按到达顺序抖动，跨服竞态下谁保持不确定；
--   3. 重量与保持者错配：重量更新了名字还是旧的，或纪录只有重量没有身份；
--   4. 盲盒/抽奖解锁一条鱼也提交纪录；
--   5. 平台失败/限流时把「读不到」当成「没有纪录」，或显示上一次的错值冒充当前值；
--   6. 延迟重试把过期候选盖到更新的纪录上；写频随上岸次数线性增长。
--   7. 平台字符串身份被拒收，读回丢失类型或混合历史数字身份时决胜报错；
--   8. 不同字符串玩家的查询序号/存档串扰，客户端伪造身份或重量污染权威纪录。
-- 迁移说明：三个旧类按 LuaUnit 实际执行序（类名字典序 Core → Integration → Service，
--   类内方法字典序）注册为三个 describe / 逐个 it；lu.assertNotEquals 是深不等，映射为 assert.are_not.same。
local GameCfg = require("common.GameCfg")
local Records = require("common.Records")
local PlayerData = require("server.Data.PlayerData")
local RandomGuard = require("tests.support.random_guard")

local function readSource(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  return text
end

describe("全服纪录纯逻辑（common/Records）", function()
  after_each(RandomGuard.restore)

  it("test_entry_keeps_weight_and_holder_together", function()
    -- 身份与重量写在同一条记录里：读回时要么两者都在，要么整条不算纪录
    local entry = Records.Entry(1234, 42, "张三")
    assert.same({ w = 1234, u = 42, n = "张三" }, entry)
    assert.is_nil(Records.Valid({ w = 1234 }))
    assert.is_nil(Records.Valid({ u = 42, n = "张三" }))
    assert.same({ w = 1234, u = "42" }, Records.Valid({ w = 1234, u = "42" }))
    assert.is_nil(Records.Valid("1234"))
    -- 名字超长只降级名字（退兜底），不整条丢掉重量与身份
    local longName = Records.Valid({ w = 1234, u = 42, n = string.rep("x", 200) })
    assert.same({ w = 1234, u = 42, n = nil }, longName)
    local nameless = Records.Valid({ w = 1234, u = 42 })
    assert.is_nil(nameless.n)
    assert.same("玩家42", Records.Holder(nameless), "显示名缺失退成玩家ID，不拿 ID 冒充名字")
    assert.same("张三", Records.Holder(Records.Entry(1234, 42, "张三")))
  end)

  it("test_equal_weight_tiebreak_is_order_independent", function()
    local a = Records.Entry(300, 5, "甲")
    local b = Records.Entry(300, 3, "乙")
    local first = Records.Wins(a, nil) and a or nil
    if Records.Wins(b, first) then
      first = b
    end
    local second = Records.Wins(b, nil) and b or nil
    if Records.Wins(a, second) then
      second = a
    end
    assert.same(3, first.u, "先到 5 后到 3 与先到 3 后到 5 结果必须一致")
    assert.same(first, second)
    assert.same("乙", first.n)
  end)

  it("test_heavier_wins_and_lighter_never_overwrites", function()
    -- 决胜：更大者胜；同重量按 UserID 升序（小者保持）；与到达顺序无关
    local held = Records.Entry(200, 7, "甲")
    assert.is_true(Records.Wins(Records.Entry(201, 9, "乙"), held))
    assert.is_false(Records.Wins(Records.Entry(199, 1, "丙"), held))
    assert.is_false(Records.Wins(Records.Entry(200, 7, "甲"), held))
    assert.is_true(Records.Wins(Records.Entry(200, 7, "甲"), nil))
    assert.is_true(Records.Wins(Records.Entry(200, 7, "甲"), { w = "x" }))
  end)

  it("test_illegal_and_overflow_weights_are_rejected", function()
    -- 非法值不猜：非数字、非正、NaN、无穷与超越上限都拒绝，绝不四舍五入成假纪录
    for _, bad in ipairs({ nil, "x", {}, true, 0, -1, 0 / 0, math.huge, -math.huge }) do
      local scaled, reason = Records.Scale(bad)
      assert.is_nil(scaled, tostring(bad))
      assert.same("invalid", reason, tostring(bad))
    end
    local over = GameCfg.Records.MaxScaled / GameCfg.Records.Scale + 1
    assert.is_nil(Records.Scale(over))
    assert.same("overflow", select(2, Records.Scale(over)))
  end)

  it("test_platform_string_identity_round_trips_without_coercion", function()
    for _, id in ipairs({ "aU5A95JB9rit0DUl", "00042", "9007199254740993", "arxYUgj/dKsUU0QL", "42" }) do
      local entry = Records.Entry(1234, id, nil)
      assert.same({ w = 1234, u = id }, entry)
      assert.same(entry, Records.Valid(entry))
      assert.same(id, Records.State(entry).userId)
      assert.same("玩家" .. id, Records.Holder(entry))
    end
    assert.same({ w = 1234, u = 42 }, Records.Valid({ w = 1234, u = 42 }), "历史数字保持者原样兼容")
    for _, id in ipairs({ "", false, {}, 0, -1, 1.5, 0 / 0, math.huge, -math.huge }) do
      assert.is_nil(Records.Entry(1234, id))
      assert.is_nil(Records.Valid({ w = 1234, u = id }))
    end
  end)

  it("test_state_and_text_never_fabricate_a_record", function()
    -- 文案：有纪录/没有纪录/读不到三态在 state 上分开；13-08、13-17 要求后两种对玩家都只显示「未取得数据」
    local ok = Records.State(Records.Entry(1234, 42, "张三"))
    assert.same("ok", ok.state)
    assert.same(12.34, ok.weight)
    assert.same("全服纪录：12.34 kg（张三）", Records.Describe(ok))
    assert.same({ state = "missing" }, Records.State(nil))
    assert.same("全服纪录：未取得数据", Records.Describe({ state = "missing" }))
    assert.same("全服纪录：未取得数据", Records.Describe({ state = "unavailable" }))
    assert.same("全服纪录：未取得数据", Records.Describe(nil), "未知状态按未取得数据展示，不展示纪录")
  end)

  it("test_string_and_legacy_identity_tiebreak_has_a_stable_total_order", function()
    -- 历史数字仍按数值升序；数字排在字符串前；字符串按原始字节序，不转换数字串。
    local ids = { 2, 10, "002", "10", "2", "aU5A95JB9rit0DUl", "bU5A95JB9rit0DUl" }
    for i, left in ipairs(ids) do
      for j, right in ipairs(ids) do
        assert.same(i < j, Records.Wins(Records.Entry(300, left), Records.Entry(300, right)))
      end
    end
  end)

  it("test_weight_scales_to_integer_and_round_trips", function()
    -- 重量 → 整数：定标因子 100（两位小数），读出还原后与写入值逐位相等
    -- 期望值取自「两位小数放大 100 倍」的定义，与实现写法无关
    for _, pair in ipairs({
      { 0.01, 1 }, { 0.2, 20 }, { 0.12, 12 }, { 1, 100 }, { 0.5, 50 },
      { 12.34, 1234 }, { 99.99, 9999 }, { 1234.56, 123456 },
    }) do
      assert.same(pair[2], Records.Scale(pair[1]), "重量 " .. tostring(pair[1]))
      assert.same(pair[1], Records.Unscale(pair[2]), "还原必须与写入一致")
    end
    assert.same(100, GameCfg.Records.Scale)
    -- 两位小数是存储精度上限：第三位不参与存储，不产生「读回比写入更精确」的假象
    assert.same(13, Records.Scale(0.125))
  end)
end)
