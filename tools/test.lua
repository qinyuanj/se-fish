-- test 子命令：按测试车道跑 busted（#145）。`lua5.4 tools/cli.lua test [fast|full] [-- <busted 参数>...]`。
-- 车道名与 .busted 的任务名同名，始终显式传 --run=<车道>（不依赖 .busted 的 default）；
-- 在仓库根执行 busted，进程调用经 WSL 接缝层的 which / execute，fast 车道用桩替换。
-- 退出码：busted 的退出码原样透传；未知车道或参数 2；busted 不在 PATH 上 3。
local seam = require("tools.wsl_seam")

local M = {}

M.LANES = {
  { name = "fast", summary = "日常车道：tests/native" },
  { name = "full", summary = "收尾车道：fast 加 tests/native/slow" },
}
M.DEFAULT_LANE = "fast"

local function lane_names()
  local names = {}
  for i, l in ipairs(M.LANES) do names[i] = l.name end
  return table.concat(names, ", ")
end

function M.usage()
  local lines = {
    "用法: lua5.4 tools/cli.lua test [fast|full] [-- <busted 参数>...]",
    "",
    "在仓库根按测试车道跑 busted（显式 --run=<车道>），退出码透传 busted。缺省车道 " .. M.DEFAULT_LANE .. "。",
    "",
    "车道（与 .busted 任务同名）：",
  }
  for _, l in ipairs(M.LANES) do
    lines[#lines + 1] = string.format("  %-6s %s", l.name, l.summary)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- 之后的参数原样追加给 busted，例如: lua5.4 tools/cli.lua test fast -- --filter=<用例名>"
  lines[#lines + 1] = "busted 不在 PATH 上时退出码 3。"
  return table.concat(lines, "\n") .. "\n"
end

local function is_lane(name)
  for _, l in ipairs(M.LANES) do
    if l.name == name then return true end
  end
  return false
end

-- 解析参数；用法错误返回 nil, 原因。
local function parse(args)
  local opts = { lane = M.DEFAULT_LANE, rest = {} }
  local seen_lane = false
  for i = 1, #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do opts.rest[#opts.rest + 1] = args[j] end
      break
    elseif a == "--help" or a == "-h" then
      opts.help = true
    elseif a:match("^%-") then
      return nil, "未知参数: " .. a .. "（busted 参数写在 -- 之后）"
    elseif seen_lane then
      return nil, "只能指定一个车道（已有 " .. opts.lane .. "）: " .. a
    elseif not is_lane(a) then
      return nil, "未知车道: " .. a .. "（可用车道: " .. lane_names() .. "）"
    else
      opts.lane, seen_lane = a, true
    end
  end
  return opts
end

function M.main(args, env)
  local opts, err = parse(args or {})
  if not opts then
    io.stderr:write("test: " .. err .. "\n\n" .. M.usage())
    return 2
  end
  if opts.help then
    io.stdout:write(M.usage())
    return 0
  end
  local busted = seam.which("busted")
  if not busted then
    io.stderr:write("test: 找不到 busted。按固定版本用 luarocks 安装（luarocks --local install busted），"
      .. "并确认 ~/.luarocks/bin 在 PATH 中\n")
    return 3
  end
  local root = (env and env.repo_root) or "."
  local parts = { "cd", seam.q(root), "&&", seam.q(busted), seam.q("--run=" .. opts.lane) }
  for _, a in ipairs(opts.rest) do parts[#parts + 1] = seam.q(a) end
  return seam.execute(table.concat(parts, " "))
end

return M
