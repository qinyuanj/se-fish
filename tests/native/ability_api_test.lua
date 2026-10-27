-- 锚点补挂仍依赖包内框架；实际挂接行为由 static_require_test 覆盖。
describe("TestAbilityPackage", function()
  it("test_anchor_framework_module_exists", function()
    local handle = assert(io.open("server/packages/ability_system/anchor_logic.lua", "rb"))
    handle:close()
  end)
end)
