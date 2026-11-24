-- 验收槽 CLI 的落盘替换：在进程内把当前目录切到临时假仓库，直接调 qa_slot.main，
-- 断言 game_cfg 文本、退出码与临时文件无残留。Windows 原生（#192）：不再拼 POSIX 命令串，
-- 也不再起 lua 子进程；配置路径相对当前目录，所以先 lfs.chdir 进假仓库，真仓库的 game_cfg 不被碰。
local lfs = require("lfs")
local slot = require("tools.qa_slot")

local SAMPLE = table.concat({
  "game_cfg.Save = {",
  "    Store = 'sefish_save_v1',",
  "    QaSlot = '',",
  "    MaxRetries = 3,",
  "}",
  "",
}, "\n")

local original_dir
local ROOT
local CONFIG
local TEMP

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

local function rmtree(path)
  local info = lfs.attributes(path)
  if not info then return end
  if info.mode == "directory" then
    local entries = {}
    for entry in lfs.dir(path) do
      if entry ~= "." and entry ~= ".." then entries[#entries + 1] = entry end
    end
    for _, entry in ipairs(entries) do rmtree(path .. "/" .. entry) end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

-- lfs.mkdtemp 在本机 LuaFileSystem 1.9 上不存在，用 TEMP + 唯一名 + lfs.mkdir 建临时根。
local function make_temp_root()
  local base = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
  math.randomseed(os.time() + math.floor(os.clock() * 1000000))
  for _ = 1, 100 do
    local name = string.format("%s/se-fish-qa-slot-%d-%06d",
      base, os.time(), math.random(0, 999999))
    if lfs.mkdir(name) then return (name:gsub("\\", "/")) end
  end
  error("无法创建临时目录")
end

-- 进程内调用 main：临时接管 print 与 io.stderr，收集两段输出，返回退出码与文本。
local function invoke(args)
  local out_lines, err_lines = {}, {}
  local real_print, real_stderr = _G.print, io.stderr
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    out_lines[#out_lines + 1] = table.concat(parts, "\t")
  end
  io.stderr = { write = function(_, s) err_lines[#err_lines + 1] = tostring(s) end }
  local ok, code = pcall(slot.main, args)
  io.stderr = real_stderr
  _G.print = real_print
  if not ok then error(code, 0) end
  return code, table.concat(out_lines, "\n"), table.concat(err_lines)
end

describe("TestQaSlotWrite", function()
  before_each(function()
    original_dir = assert(lfs.currentdir())
    ROOT = make_temp_root()
    assert(lfs.mkdir(ROOT .. "/common"))
    CONFIG = ROOT .. "/common/game_cfg.lua"
    TEMP = CONFIG .. ".qa-slot.tmp"
    local f = assert(io.open(CONFIG, "wb"))
    f:write(SAMPLE)
    f:close()
    assert(lfs.chdir(ROOT))
  end)

  after_each(function()
    assert(lfs.chdir(original_dir))
    rmtree(ROOT)
  end)

  it("test_set_and_off_replace_config_without_leaving_temp_file", function()
    local code, output = invoke({ "set", "qa121" })
    assert.are.equal(0, code, output)
    assert.are.equal((SAMPLE:gsub("QaSlot = ''", "QaSlot = 'qa121'")), slurp(CONFIG))
    assert.is_nil(slurp(TEMP))
    code, output = invoke({ "off" })
    assert.are.equal(0, code, output)
    assert.are.equal(SAMPLE, slurp(CONFIG))
    assert.is_nil(slurp(TEMP))
  end)

  it("test_set_succeeds_when_target_config_already_exists", function()
    -- 目标 game_cfg.lua 已存在（before_each 已建）：Windows 上 os.rename 不覆盖目标，
    -- 修复后必须先删目标再重命名，set 才能成功。
    assert.is_not_nil(slurp(CONFIG))
    local code, output = invoke({ "set", "qa122" })
    assert.are.equal(0, code, output)
    assert.are.equal((SAMPLE:gsub("QaSlot = ''", "QaSlot = 'qa122'")), slurp(CONFIG))
    assert.is_nil(slurp(TEMP))
  end)

  -- 删除目标之后的失败（os.rename 失败）：旧档已经没了，TEMP 就是完整的新档，
  -- 必须保留下来供人工恢复，不能连它一起删掉。
  it("test_rename_failure_keeps_new_config_in_temp_file", function()
    local real_rename = os.rename
    os.rename = function() return nil, "stub: rename failed" end
    local ok, code, output, err = pcall(invoke, { "set", "qa124" })
    os.rename = real_rename
    assert.is_true(ok, tostring(code))
    assert.are_not.equal(0, code, output .. err)
    local kept = slurp(TEMP)
    assert.is_not_nil(kept, "旧配置已删除，TEMP 必须保留为可恢复的新配置")
    assert.are.equal((SAMPLE:gsub("QaSlot = ''", "QaSlot = 'qa124'")), kept)
    assert.is_truthy(err:find("qa-slot.tmp", 1, true), "错误信息应写明新配置留在 " .. TEMP .. "：" .. err)
  end)

  it("test_set_reports_error_and_keeps_old_config_when_temp_file_exists", function()
    local stale = assert(io.open(TEMP, "wb"))
    stale:write("stale")
    stale:close()
    local code, output, err = invoke({ "set", "qa123" })
    assert.are_not.equal(0, code, output .. err)
    assert.are.equal(SAMPLE, slurp(CONFIG))
    assert.is_truthy(err:match("%S"), "应给出可读错误")
  end)
end)
