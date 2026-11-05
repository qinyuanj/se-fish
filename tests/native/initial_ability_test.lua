-- 失败方式：非策划的加速示例重新进入初始技能，或攻击被绑定到数组下标而随技能删除错位。

local GameCfg = require("common.GameCfg")

describe("初始技能", function()
  it("只装备挥砍攻击，不装配加速示例", function()
    assert.are.equal(1, #GameCfg.Ability.InitialAbilities)
    assert.are.equal("melee_hit", GameCfg.Ability.InitialAbilities[1].AnchorBehavior)
    assert.are.equal(0, GameCfg.Ability.InitialAbilities[1].Index)
  end)

  it("GM 伤害基准读取挥砍行为，不依赖技能数组下标", function()
    local source = assert(io.open("server/Mgr/MgrGM.lua", "rb")):read("a")
    assert.is_nil(source:find("InitialAbilities[2]", 1, true))
    assert.matches("AnchorBehavior%s*==%s*'melee_hit'", source)
  end)
end)
