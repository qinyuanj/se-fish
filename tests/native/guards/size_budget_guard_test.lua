-- token 预算门禁（ADR-0041）：口径、范围、基线与棘轮语义的不变量。
-- 失败方式先列：
--   1. 口径漂移（常数被悄悄调大/调小）→ 预算名存实亡，所以把 LIMIT 与几个计数钉死；
--   2. 范围写错（把 packages 或 server/data 算进预算）→ 上游整包与引擎导出会让门禁常红，最后被静音；
--   3. 基线解析把 `--` 注释当条目 → 棘轮凭空多个豁免；
--   4. 门禁把基线内的存量文件误报成新超限 → 存量文件一改就被挡住，人只会去改预算。
local budget = require("tools.size_budget")

local function tokens_of(path, tokens)
  return { path = path, tokens = tokens }
end

describe("token 预算门禁", function()
  it("test_budget_limit_and_tokenizer_are_pinned", function()
    assert.are.equal(5500, budget.LIMIT)
    assert.are.equal("se-fish-budget-v1", budget.TOKENIZER)
  end)

  it("test_count_is_deterministic_and_matches_documented_rules", function()
    assert.are.equal(0, budget.count(""))
    -- local a = 1：三个词元（local / a / 1）加一个 =；行内空格不计。
    assert.are.equal(4, budget.count("local a = 1"))
    -- 12 字节的标识符：前 10 字节 1 个，剩下 2 字节按 8 字节一档，进位到 2 个。
    assert.are.equal(2, budget.count("aaaaaaaaaaaa"))
    -- 中文按码点各记 1 个；含换行的空白段 1 个。
    assert.are.equal(2, budget.count("钓鱼"))
    assert.are.equal(5, budget.count("-- 钓鱼\n"))
  end)

  it("test_count_grows_with_source", function()
    local sample = "local fish = require(\"common.fish_catch\")\n-- 钓鱼\n"
    assert.is_true(budget.count(sample) > 0)
    assert.is_true(budget.count(sample .. sample) >= budget.count(sample) * 2 - 2)
  end)

  it("test_scope_excludes_packages_data_trigger_tests", function()
    assert.is_true(budget.in_scope("client/main.lua"))
    assert.is_true(budget.in_scope("common/cfg/fish.lua"))
    assert.is_true(budget.in_scope("server/world_host/player_life.lua"))
    assert.is_false(budget.in_scope("client/packages/modifier_system/modifier_system.lua"))
    assert.is_false(budget.in_scope("server/data/player_data.lua"))
    assert.is_false(budget.in_scope("common/_trigger/anchor.lua"))
    assert.is_false(budget.in_scope("client/tests/foo.lua"))
    assert.is_false(budget.in_scope("tools/size_budget.lua"))
  end)

  it("test_parse_baseline_skips_comments_and_blank_lines", function()
    local set = budget.parse_baseline("-- 文件头\n\nclient/big.lua:6000\nserver/big.lua:9000\n")
    assert.are.equal(6000, set["client/big.lua"])
    assert.are.equal(9000, set["server/big.lua"])
    assert.is_nil(set["-- 文件头"])
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    assert.are.equal(2, count)
  end)

  it("test_check_only_flags_new_offenders", function()
    local rows = {
      tokens_of("client/small.lua", 5500),
      tokens_of("client/over.lua", 5501),
      tokens_of("client/baselined.lua", 16000),
    }
    local baseline = { ["client/baselined.lua"] = 16000 }
    local over, new = budget.check(rows, baseline)
    assert.are.equal(2, #over)
    assert.are.equal(1, #new)
    assert.are.equal("client/over.lua", new[1].path)
  end)

  it("test_size_is_wired_into_cli_route", function()
    local cli = require("tools.cli")
    local found = false
    for _, command in ipairs(cli.commands) do
      if command.name == "size" then found = true end
    end
    assert.is_true(found)
  end)
end)
