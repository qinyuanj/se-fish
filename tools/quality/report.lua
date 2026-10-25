-- DRY 与 CRAP 共用配置生成的三端业务清单；这里仅负责重复代码报告。
-- 自包含路径：无论调用方是否设置 LUA_PATH，都从脚本位置加载固定工具。
-- 加载的固定工具源码目录（相对仓库根），唯一来源：
-- tests/native/slow/quality_report_test.lua 经 require("tools.quality.report") 取同一份做缺失预检。
local TOOLCACHE_SOURCES = { ".toolcache/dry4lua/src", ".toolcache/luacheck/src", ".toolcache/acceptance4lua/src" }
-- 被 require 时只导出常量，不当脚本执行（作为脚本运行时 ... 是命令行参数）。
if ... == "tools.quality.report" then return { TOOLCACHE_SOURCES = TOOLCACHE_SOURCES } end

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = script_dir .. "/../.."
local search = {}
for _, dir in ipairs(TOOLCACHE_SOURCES) do
  search[#search + 1] = root .. "/" .. dir .. "/?.lua;" .. root .. "/" .. dir .. "/?/init.lua;"
end
package.path = table.concat(search) .. package.path
local json = require("acceptance4lua.json")
local dry = require("dry4lua.analysis")
local ast = require("dry4lua.ast")

local manifest, report = arg[1], arg[2]
assert(manifest and report, "用法：lua tools/quality/report.lua <业务源码清单> <DRY JSON 输出>")
local files = {}
local handle = assert(io.open(manifest, "rb"))
for line in handle:lines() do
  line = line:gsub("\r$", "")
  if line ~= "" then files[#files + 1] = line end
end
handle:close()
assert(#files > 0, "没有可分析的业务 Lua 源码")
table.sort(files)
-- 上游遇到解析失败会静默跳过，先显式校验以免发布不完整报告。
for _, path in ipairs(files) do
  local parsed, err = ast.parse_file(path)
  assert(parsed, path .. ": " .. tostring(err))
end

-- Windows 原生 Lua 的 io.popen 使用 cmd.exe；用统一清单替换上游 POSIX find。
local original_popen = io.popen
io.popen = function(cmd, mode)
  if cmd:sub(1, 5) == "find " then
    local index = 0
    return {
      lines = function()
        return function()
          index = index + 1
          return files[index]
        end
      end,
      close = function() return true end,
    }
  end
  return original_popen(cmd, mode)
end
local ok, candidates = pcall(dry.find_duplicates, { paths = { "." } })
io.popen = original_popen
assert(ok, candidates)
local out = assert(io.open(report, "wb"))
-- 通用 writer 将无元素的 table 视为对象；候选清单固定输出 JSON 数组。
local encoded_candidates = #candidates == 0 and "[]" or json.encode(candidates)
out:write('{"source_count":' .. tostring(#files) .. ',"candidates":' .. encoded_candidates .. '}')
out:close()
print(string.format("DRY 分析完成：%d 个业务 Lua 文件，%d 对重复候选；仅报告、不设门槛。", #files, #candidates))
