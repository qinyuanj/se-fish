-- test 子命令：按测试车道跑 busted（#145）。`lua tools/cli.lua test [fast|full|spec|art] [--jobs N] [-- <busted 参数>...]`。
-- 车道从三条扩到四条（#243）：新增 spec（条款断言车道），并让它随 full 一起跑。
-- 车道名与 .busted 的任务名同名，始终显式传 --run=<车道>（不依赖 .busted 的 default）。
-- 进程调用只经 tools/seam.lua（唯一接缝）：seam.which 找 busted，seam.spawn / seam.spawn_bg 在仓库根执行。
-- 退出码：busted 通过 0；busted 非 0 一律收成 1（业务失败）——busted 的退出码是失败数加错误数，
-- 原样透传时恰好 3 个失败会与「工具不可用」的 3 冲突；未知车道或参数 2；busted 不在 PATH 上 3。
--
-- 分片并行：--jobs N 把一段车道按文件分给 N 个 busted 进程并跑，缺省 1（串行，行为与以前完全一致：
-- 一条命令、busted 自己按 .busted 发现文件、输出直接到控制台）。
-- 并行时文件表从 .busted 现读（车道真源只有这一份，这里不抄第二份），按文件字节数做 LPT 装箱；
-- 写固定路径的车道段（slow、art）不分片，单独成段串行跑。段序与 .busted 的 ROOT 顺序一致，
-- 所以用例的执行顺序与串行跑时相同。
-- 并行时末行是聚合出来的 `N successes / M failures / E errors / P pending : T seconds`，
-- T 取整秒墙钟：分片互相争用，各分片自报的时间求和没有意义。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")

local M = {}

M.LANES = {
  { name = "fast", summary = "日常车道：tests/native 加 tests/native/guards" },
  { name = "full", summary = "收尾车道：fast 加 tests/native/slow 与 tests/native/spec" },
  { name = "guards", summary = "门禁型车道：tests/native/guards，随 fast 与 full 运行" },
  { name = "spec", summary = "条款断言车道：tests/native/spec，随 full 运行" },
  { name = "art", summary = "美术车道：tests/native/art，要本机 Blender，默认不进 full" },
}
M.DEFAULT_LANE = "fast"
M.DEFAULT_JOBS = 1

-- 并行上限 8：12 逻辑核上实测 4 路 5.7 秒、6 路 4.5 秒、8 路 4.3 秒、10 路与 12 路仍在 4.3 秒上下。
-- 再往上只是把同一次读盘争用摊薄（每个 busted 进程都要重新读一遍文件，过一遍防病毒过滤），
-- 墙钟不再下降，所以封顶。
M.MAX_JOBS = 8

-- 写固定路径、不能与别的段并跑的 ROOT，连同原因。加车道时先看这张表。
M.SERIAL_ROOTS = {
  ["tests/native/slow"] = "写固定路径 tmp/sync-transport-test 与 tmp/deploy-transport-test，并改写 qa_slot 的真实配置",
  ["tests/native/art"] = "要本机 Blender，写固定路径 tmp/blender-transport-test.out",
}

local function lane_names()
  local names = {}
  for i, l in ipairs(M.LANES) do names[i] = l.name end
  return table.concat(names, ", ")
end

function M.usage()
  local lines = {
    "用法: lua tools/cli.lua test [fast|full|spec|art] [--jobs N] [-- <busted 参数>...]",
    "",
    "在仓库根按测试车道跑 busted（显式 --run=<车道>），测试通过退出码 0、有失败或错误 1。缺省车道 " .. M.DEFAULT_LANE .. "。",
    "",
    "车道（与 .busted 任务同名）：",
  }
  for _, l in ipairs(M.LANES) do
    lines[#lines + 1] = string.format("  %-6s %s", l.name, l.summary)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("--jobs N  把车道分给 N 个 busted 进程并跑（1..%d），缺省 %d 即串行；",
    M.MAX_JOBS, M.DEFAULT_JOBS)
  lines[#lines + 1] = "          写固定路径的车道段（slow、art）始终串行，段序与 .busted 的 ROOT 顺序相同。"
  lines[#lines + 1] = "-- 之后的参数原样追加给 busted，例如: lua tools/cli.lua test fast -- --filter=<用例名>"
  lines[#lines + 1] = "并行时 -- 之后只能给 busted 的选项：再给 ROOT 参数与分片冲突，直接按用法错误退出。"
  lines[#lines + 1] = "busted 不在 PATH 上时退出码 3。"
  return table.concat(lines, "\n") .. "\n"
end

local function is_lane(name)
  for _, l in ipairs(M.LANES) do
    if l.name == name then return true end
  end
  return false
end

-- 仓库根：CLI 入口给的是 Windows 绝对路径（cli.lua 已用 lfs.currentdir 推导，不读 PWD）。
-- 直接跑本模块时没有 env，用接缝按当前目录绝对化兜底。
local function repo_root(env)
  local root = env and env.repo_root
  if root and (root:match("^%a:/") or root:sub(1, 2) == "//") then return root end
  return assert(seam.absolute("."))
end

-- 解析参数；用法错误返回 nil, 原因。
local function parse(args)
  local opts = { lane = M.DEFAULT_LANE, rest = {}, jobs = tostring(M.DEFAULT_JOBS) }
  local seen_lane = false
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do opts.rest[#opts.rest + 1] = args[j] end
      break
    elseif a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--jobs" then
      if args[i + 1] == nil then return nil, "--jobs 后面要跟并发数" end
      opts.jobs, i = args[i + 1], i + 1
    elseif a:sub(1, 7) == "--jobs=" then
      opts.jobs = a:sub(8)
    elseif a:sub(1, 1) == "-" then
      return nil, "未知参数: " .. a .. "（busted 参数写在 -- 之后）"
    elseif seen_lane then
      return nil, "只能指定一个车道（已有 " .. opts.lane .. "）: " .. a
    elseif not is_lane(a) then
      return nil, "未知车道: " .. a .. "（可用车道: " .. lane_names() .. "）"
    else
      opts.lane, seen_lane = a, true
    end
    i = i + 1
  end
  local jobs = tonumber(opts.jobs)
  if jobs == nil or jobs ~= math.floor(jobs) or jobs < 1 or jobs > M.MAX_JOBS then
    return nil, string.format("--jobs 要 1 到 %d 的整数（给了 %s）", M.MAX_JOBS, tostring(opts.jobs))
  end
  opts.jobs = math.floor(jobs)
  return opts
end

-- 读 .busted：它是纯 Lua，文件里写明「便于工具以 dofile 读取真实配置」。
local function load_config(root)
  local path = root .. "/.busted"
  local ok, cfg = pcall(dofile, path)
  if not ok then return nil, "读取 " .. path .. " 失败: " .. tostring(cfg) end
  if type(cfg) ~= "table" then return nil, path .. " 没有返回配置表" end
  return cfg
end

-- 车道分段：连续的、可以并跑的 ROOT 合成一段；不能并跑的 ROOT 各自成段（段内可以多个）。
-- 段序与 .busted 的 ROOT 顺序一致，用例的执行顺序因此不变。
local function segments_of(task)
  local segments = {}
  for _, dir in ipairs(task.ROOT) do
    local blocked = M.SERIAL_ROOTS[dir]
    local last = segments[#segments]
    if last and last.blocked == blocked then
      last.roots[#last.roots + 1] = dir
    else
      segments[#segments + 1] = { blocked = blocked, roots = { dir } }
    end
  end
  return segments
end

-- 一个 ROOT 下的测试文件（相对仓库根，按名排序）。
-- 发现口径对齐 busted 2.3.0 的 test_file_loader：recursive=false 只看一级文件，
-- basename 命中 pattern 才算（busted 是 basename:find(pattern)，不是整条路径），再由 lua 加载器认 .lua。
-- busted 版本由 ci-toolchain-v1 固定，升级时这里要跟着复核。
local function root_files(root, dir, recursive, pattern)
  local abs = dir:match("^%a:/") and dir or (root .. "/" .. dir)
  local names = {}
  if seam.is_dir(abs) then
    if recursive then
      names = seam.list_files(abs) or {}
    else
      for _, entry in ipairs(seam.list_entries(abs)) do
        if not entry.dir then names[#names + 1] = entry.name end
      end
    end
  elseif seam.exists(abs) then
    return { dir }
  else
    return nil, "找不到车道目录: " .. dir
  end
  local matched = {}
  for _, name in ipairs(names) do
    local base = name:match("[^/]*$")
    if base:find(pattern) and base:match("%.lua$") then matched[#matched + 1] = name end
  end
  table.sort(matched)
  local files = {}
  for _, name in ipairs(matched) do files[#files + 1] = dir .. "/" .. name end
  return files
end

-- LPT 装箱：大文件先落，每次都进当前最轻的分片。权重取文件字节数——现算、不会过期，
-- 与用例体量的相关性也够用；已知偏差是 guards 下扫全树的门禁用例（耗时与自身大小无关），
-- 被 MAX_JOBS 的均摊盖住。
local function shard(root, files, jobs)
  local weighted = {}
  for _, file in ipairs(files) do
    weighted[#weighted + 1] = { file = file, weight = seam.size(root .. "/" .. file) or 0 }
  end
  table.sort(weighted, function(a, b)
    if a.weight == b.weight then return a.file < b.file end
    return a.weight > b.weight
  end)
  local buckets = {}
  for i = 1, math.min(jobs, #weighted) do buckets[i] = { weight = 0, files = {} } end
  for _, item in ipairs(weighted) do
    local lightest = buckets[1]
    for i = 2, #buckets do
      if buckets[i].weight < lightest.weight then lightest = buckets[i] end
    end
    lightest.weight = lightest.weight + item.weight
    lightest.files[#lightest.files + 1] = item.file
  end
  for _, bucket in ipairs(buckets) do table.sort(bucket.files) end
  return buckets
end

-- busted 的汇总行：`12 successes / 0 failures / 0 errors / 0 pending : 0.123 seconds`。
local SUMMARY = "(%d+) successes? / (%d+) failures? / (%d+) errors? / (%d+) pending : ([%d%.]+) second"

-- 取最后一次命中：分片输出里本该只有一条，留出「输出里恰好引用了这句话」的余地。
local function summary_of(text)
  local found
  for successes, failures, errors, pending, seconds in text:gmatch(SUMMARY) do
    found = {
      successes = tonumber(successes),
      failures = tonumber(failures),
      errors = tonumber(errors),
      pending = tonumber(pending),
      seconds = tonumber(seconds),
    }
  end
  return found
end

local function print_block(header, output)
  if header ~= "" then io.stdout:write(header .. "\n") end
  if output == nil or output == "" then return end
  io.stdout:write(output)
  if output:sub(-1) ~= "\n" then io.stdout:write("\n") end
end

-- 分片并跑：先全部起来，再按完成顺序收。哪片先完就先打哪片，失败现场不必等别的分片。
local function run_shards(root, tmp_dir, plans)
  local items = {}
  for i, plan in ipairs(plans) do
    items[i] = {
      index = i,
      count = #plan.files,
      handle = seam.spawn_bg({ argv = plan.argv, cwd = root, tmp_dir = tmp_dir }),
    }
  end
  local finished = 0
  while finished < #items do
    for _, item in ipairs(items) do
      if not item.reported then
        local code = seam.bg_done(item.handle)
        if code ~= nil then
          item.reported = true
          item.code = code
          item.output = seam.bg_output(item.handle)
          finished = finished + 1
          local header = string.format("--- 分片 %d/%d（%d 个文件）退出码 %d ---",
            item.index, #items, item.count, code)
          -- 失败的分片留日志目录，成功的不留（tmp/ 不堆东西）。
          if code ~= 0 then
            header = header .. "\n--- 日志目录 " .. item.handle.dir .. " ---"
          else
            seam.bg_close(item.handle)
          end
          print_block(header, item.output)
        end
      end
    end
    if finished < #items then seam.sleep(20) end
  end
  return items
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
      .. "并确认 %APPDATA%\\luarocks\\bin 在 PATH 中\n")
    return exit_code.UNAVAILABLE
  end
  local root = repo_root(env)
  local base_argv = { busted, "--run=" .. opts.lane }
  for _, a in ipairs(opts.rest) do base_argv[#base_argv + 1] = a end

  -- 串行就是原来的行为，一条命令跑到底。
  if opts.jobs <= 1 then
    if seam.spawn({ argv = base_argv, cwd = root }) ~= 0 then return exit_code.FAILURE end
    return exit_code.OK
  end

  -- 并行：busted 的 ROOT 参数交给分片后就没法按车道发现文件了，宁可报用法错误也不猜。
  for _, a in ipairs(opts.rest) do
    if a:sub(1, 1) ~= "-" then
      io.stderr:write("test: -- 之后的 " .. a .. " 是 busted 的 ROOT 参数，与 --jobs 分片冲突；"
        .. "去掉 --jobs，或去掉这个参数\n")
      return 2
    end
  end

  local cfg, cfg_err = load_config(root)
  if not cfg then
    io.stderr:write("test: " .. cfg_err .. "\n")
    return exit_code.FAILURE
  end
  local task = cfg[opts.lane] or cfg.default
  local all = cfg._all or {}
  if type(task) ~= "table" or type(task.ROOT) ~= "table" or #task.ROOT == 0 then
    io.stderr:write("test: .busted 的车道 " .. opts.lane .. " 没有 ROOT，无法分片\n")
    return exit_code.FAILURE
  end

  local tmp_dir = root .. "/tmp"
  -- 墙钟用 os.clock：本仓只跑 Windows（ADR-0017），MSVC 的 clock() 是「进程启动至今的墙钟」而不是
  -- CPU 时间（实测空跑 ping 2 秒差值 2.07）。os.time 只有整秒，2.7 秒的运行会被写成 2 秒。
  local started = os.clock()
  -- crashed 计入 errors：分片没跑完（busted 起不来、Lua 崩溃、被信号打断）时输出里没有汇总行，
  -- 此时宁可让末行难看，也不能让它看起来全绿。
  local totals = { successes = 0, failures = 0, errors = 0, pending = 0, crashed = 0 }
  local failed = false

  local function account(code, output)
    local sum = summary_of(output or "")
    if sum then
      totals.successes = totals.successes + sum.successes
      totals.failures = totals.failures + sum.failures
      totals.errors = totals.errors + sum.errors
      totals.pending = totals.pending + sum.pending
    else
      totals.crashed = totals.crashed + 1
      totals.errors = totals.errors + 1
    end
    if code ~= 0 then failed = true end
  end

  for _, segment in ipairs(segments_of(task)) do
    local dirs = table.concat(segment.roots, ", ")
    if segment.blocked then
      -- 串行段：一条命令跑这段的全部 ROOT（busted 自己发现文件），输出收齐再打，好让末行能聚合它。
      io.stdout:write(string.format("--- 串行段 %s（%s）---\n", dirs, segment.blocked))
      local argv = { busted, "--run=" .. opts.lane }
      for _, a in ipairs(opts.rest) do argv[#argv + 1] = a end
      for _, dir in ipairs(segment.roots) do argv[#argv + 1] = dir end
      local code, output = seam.capture({ argv = argv, cwd = root, tmp_dir = tmp_dir })
      print_block("", output)
      account(code, output)
    else
      local files = {}
      for _, dir in ipairs(segment.roots) do
        local found, find_err = root_files(root, dir, all.recursive == true, all.pattern or "_spec")
        if not found then
          io.stderr:write("test: " .. find_err .. "\n")
          return exit_code.FAILURE
        end
        for _, file in ipairs(found) do files[#files + 1] = file end
      end
      if #files == 0 then
        io.stderr:write("test: 并行段 " .. dirs .. " 没有找到任何测试文件\n")
        return exit_code.FAILURE
      end
      local plans = {}
      for _, bucket in ipairs(shard(root, files, opts.jobs)) do
        local argv = { busted, "--run=" .. opts.lane }
        for _, a in ipairs(opts.rest) do argv[#argv + 1] = a end
        for _, file in ipairs(bucket.files) do argv[#argv + 1] = file end
        plans[#plans + 1] = { argv = argv, files = bucket.files }
      end
      io.stdout:write(string.format("--- 并行段 %s：%d 个文件分 %d 片 ---\n", dirs, #files, #plans))
      for _, item in ipairs(run_shards(root, tmp_dir, plans)) do
        account(item.code, item.output)
      end
    end
  end

  io.stdout:write(string.format("%d successes / %d failures / %d errors / %d pending : %.2f seconds\n",
    totals.successes, totals.failures, totals.errors, totals.pending, os.clock() - started))
  if totals.crashed > 0 then
    io.stderr:write(string.format("test: %d 个分片没有输出汇总行（没跑完），已计入 errors\n", totals.crashed))
  end
  if failed or totals.failures + totals.errors > 0 then return exit_code.FAILURE end
  return exit_code.OK
end

return M
