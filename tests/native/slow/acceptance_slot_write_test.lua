-- 验收槽 CLI 的落盘替换：真 Lua 子进程在临时假仓库里执行 set / off，断言 GameCfg 文本与临时文件。
-- 配置路径是相对当前目录的 common/GameCfg.lua，所以子进程 cd 进假仓库，LUA_PATH 指回本仓库；
-- 真仓库的 GameCfg 不被碰。开发端只在 WSL（#116）：替换不得依赖 PowerShell。
local interpreter = require("tests.support.interpreter")
local q = require("tests.support.sh_quote").q

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

local REPO = assert(io.popen("pwd")):read("l")
local ROOT = REPO .. "/tmp/acceptance-slot-write-test"
local CONFIG = ROOT .. "/common/GameCfg.lua"

local sample = table.concat({
  "GameCfg.Save = {",
  "    Store = 'sefish_save_v1',",
  "    AcceptanceSlot = '',",
  "    MaxRetries = 3,",
  "}",
  "",
}, "\n")

local function slot(...)
  local args = {}
  for _, value in ipairs({ ... }) do args[#args + 1] = string.format("%q", value) end
  local chunk = "os.exit(require('tools.acceptance_slot').main({" .. table.concat(args, ",") .. "}))"
  local command = "cd " .. q(ROOT) .. " && LUA_PATH=" .. q(REPO .. "/?.lua;" .. REPO .. "/?/init.lua;;")
    .. " " .. q(interpreter.path()) .. " -e " .. q(chunk) .. " 2>&1"
  local pipe = assert(io.popen(command))
  local output = pipe:read("a")
  local _, _, code = pipe:close()
  return code, output
end

describe("TestAcceptanceSlotWrite", function()
  before_each(function()
    os.execute("rm -rf " .. q(ROOT) .. " && mkdir -p " .. q(ROOT .. "/common"))
    local f = assert(io.open(CONFIG, "wb"))
    f:write(sample)
    f:close()
  end)

  after_each(function()
    os.execute("rm -rf " .. q(ROOT))
  end)

  it("test_set_and_off_replace_config_without_leaving_temp_file", function()
    local code, output = slot("set", "qa121")
    assert.are.equal(0, code, output)
    assert.are.equal((sample:gsub("AcceptanceSlot = ''", "AcceptanceSlot = 'qa121'")), slurp(CONFIG))
    assert.is_nil(slurp(CONFIG .. ".acceptance-slot.tmp"))
    code, output = slot("off")
    assert.are.equal(0, code, output)
    assert.are.equal(sample, slurp(CONFIG))
    assert.is_nil(slurp(CONFIG .. ".acceptance-slot.tmp"))
  end)
end)
