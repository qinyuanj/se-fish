-- 迁移失败方式：DRY 不能把业务源码解析失败当成成功报告。
-- 迁移自 tests/tooling/slow/quality_report_test.lua（#92，LuaUnit → 原生 Busted）。
-- 子进程用 POSIX sh 起（开发端只在 WSL，#116）；解释器取启动本 runner 的那个
-- （tests/support/interpreter.lua），不走 PATH 猜 `lua`——WSL 上裸 `lua` 可能是 5.1。
-- 依赖 `tools/quality/project install` 建好的 .toolcache（dry4lua / luacheck / acceptance4lua）：
-- 缓存缺失时 report.lua 在 require 处失败，日志里不会出现 broken.lua，本案例照样红。
local interpreter = require("tests.support.interpreter")
local q = require("tests.support.sh_quote").q

local ROOT = "tmp/quality-report-test"

local function write(path, body)
  local f = assert(io.open(path, "wb"))
  f:write(body)
  f:close()
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

-- 跑一条 sh 命令，stdout+stderr 落 ROOT/run.log，返回退出码与日志。
local function capture(cmd)
  local log = ROOT .. "/run.log"
  local _, _, code = os.execute(cmd .. " > " .. q(log) .. " 2>&1")
  return code, read(log) or ""
end

describe("TestQualityReport", function()
  before_each(function()
    os.execute("rm -rf " .. q(ROOT) .. " && mkdir -p " .. q(ROOT))
  end)
  after_each(function()
    os.execute("rm -rf " .. q(ROOT))
  end)

  it("test_invalid_source_does_not_publish_dry_report", function()
    local source, manifest, output = ROOT .. "/broken.lua", ROOT .. "/sources.txt", ROOT .. "/dry.json"
    write(source, "local function broken(\n")
    write(manifest, source .. "\n")
    -- report.lua 已自包含工具路径，只需调用脚本本身。
    local code, log = capture(q(interpreter.path()) .. " tools/quality/report.lua " .. q(manifest) .. " " .. q(output))
    assert.are_not.equal(0, code, log)
    assert.matches("broken.lua", log, 1, true)
    assert.is_nil(read(output))
  end)
end)
