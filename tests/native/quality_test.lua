-- 质量工具的固定提交（#92 迁移自 tests/tooling/quality_test.lua）。
-- 案例顺序沿用旧入口的类名 + 方法名字典序。
-- `bootstrap.ensure("unknown4lua")` 只查登记表，不访问网络、不需要 .toolcache，跨平台可跑。
local bootstrap = require("tools.acceptance.bootstrap")

describe("TestQuality", function()
  it("test_fixed_commits_and_unknown_tool_failure", function()
    assert.are.equal("8dd107144a7635596d75e4fccfce35121dc67570", bootstrap.pins.acceptance4lua)
    assert.are.equal("1dd42d73116921cd54a00c7b132a9b097e4a288a", bootstrap.pins.dry4lua)
    -- ensure 返回 (nil, err)；先取第一个返回值，避免 err 被当成断言消息。
    local ok = bootstrap.ensure("unknown4lua")
    assert.is_nil(ok)
  end)
end)
