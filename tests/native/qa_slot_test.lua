-- 验收槽 CLI 的配置文本替换与参数约束；测试不写真实 GameCfg。
-- 迁移自 tests/tooling/qa_slot_test.lua（#92，LuaUnit → 原生 Busted）；
-- 案例顺序沿用旧入口的类名 + 方法名字典序。
local slot = require('tools.qa_slot')

local sample = table.concat({
  "GameCfg.Save = {",
  "    Store = 'sefish_save_v1',",
  "    QaSlot = '',",
  "    MaxRetries = 3,",
  "}",
}, '\n')

describe("TestQaSlot", function()
  it("test_rejects_invalid_slots_and_ambiguous_config", function()
    for _, name in ipairs({ '../x', 'a b', 'a.b', string.rep('x', 41) }) do
      assert.is_false(slot.valid_slot(name))
    end
    assert.is_false(slot.valid_slot(''))
    assert.is_true(slot.valid_slot('qa-first'))
    assert.is_nil(slot.replace_slot('GameCfg.Save = {\n}\n', 'qa'))
    assert.is_nil(slot.replace_slot(sample:gsub('    MaxRetries', "    QaSlot = 'extra',\n    MaxRetries"), 'qa'))
    local commented = sample:gsub("    QaSlot = '',", "    -- QaSlot = 'old',\n    QaSlot = 'real',")
    assert.are.equal('real', slot.current_slot(commented))
    local updated = assert(slot.replace_slot(commented, 'next'))
    assert.matches("-- QaSlot = 'old'", updated, 1, true)
    assert.are.equal('next', slot.current_slot(updated))
    assert.is_nil(slot.replace_slot(sample:gsub("QaSlot = ''", 'QaSlot = "real"'), 'next'))
  end)

  it("test_replaces_only_save_slot_and_can_restore_off", function()
    local input = "local QaSlot = 'other'\n" .. sample
    local updated = assert(slot.replace_slot(input, 'qa-first'))
    assert.are.equal('other', updated:match("local QaSlot = '([^']*)'"))
    assert.are.equal('qa-first', slot.current_slot(updated))
    assert.are.equal(input, assert(slot.replace_slot(updated, '')))
  end)
end)
