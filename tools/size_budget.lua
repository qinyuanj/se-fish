-- size 子命令：部署范围（三端自写代码）的单文件 token 预算门禁（ADR-0041）。
-- 口径是 se-fish-budget-v1：纯 Lua 的近似分词器，用于预算而不是回放；在仓库全量 288 个 Lua 文件上
-- 与 cl100k_base 的中位偏差 +2%，P10–P90 为 0.95–1.09（校准方法见 ADR-0041）。
-- 范围与 EmmyLua 诊断门禁（ADR-0038）一致：client/common/server，排除上游整包 packages/、
-- 引擎导出 data/、生成物 _trigger/、tests/ 与 tmp/。
-- 基线 tools/size_baseline.txt 记录存量超限文件：门禁只拦基线外的新超限文件，--update-baseline 只许收窄。
-- 退出码：0 通过或基线已收窄 / 1 有基线外超限文件或读取失败 / 2 用法错误或棘轮拒绝。
local exit_code = require("tools.exit_code")
local lfs = require("lfs")

local M = {}

M.LIMIT = 5500
M.BASELINE = "tools/size_baseline.txt"
M.TOKENIZER = "se-fish-budget-v1"
-- 词元口径（钉死在这里，ADR-0041 记的是这几个常数）：标识符前 10 字节算 1 个 token，
-- 之后每 8 字节 +1；空白段含换行记 1 个 token；非 ASCII 码点各记 1 个。
M.WORD_BYTES = 10
M.WORD_STEP = 8

local SCOPE_ROOTS = { client = true, common = true, server = true }
local SKIP_DIRS = {
  packages = true, _trigger = true, tests = true, data = true, tmp = true, target = true,
}

local function is_word_byte(b)
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end

-- UTF-8 起始字节 -> 码点字节数；非法起始字节按 1 处理，宁可少算也不死循环。
local UTF8_LEN = {}
for b = 0, 255 do
  if b < 0x80 then UTF8_LEN[b] = 1
  elseif b >= 0xC2 and b <= 0xDF then UTF8_LEN[b] = 2
  elseif b >= 0xE0 and b <= 0xEF then UTF8_LEN[b] = 3
  elseif b >= 0xF0 and b <= 0xF4 then UTF8_LEN[b] = 4
  else UTF8_LEN[b] = 1 end
end

-- 源码 -> 近似 token 数。口径固定，不随环境变化；同一份源码永远得到同一个数。
function M.count(source)
  local total, i, n = 0, 1, #source
  while i <= n do
    local b = source:byte(i)
    if b == 32 or b == 9 or b == 10 or b == 13 then
      local newline = false
      while i <= n do
        local c = source:byte(i)
        if c == 10 or c == 13 then newline = true
        elseif c ~= 32 and c ~= 9 then break end
        i = i + 1
      end
      if newline then total = total + 1 end
    elseif is_word_byte(b) then
      local from = i
      while i <= n and is_word_byte(source:byte(i)) do i = i + 1 end
      local len = i - from
      total = total + 1
      if len > M.WORD_BYTES then
        total = total + math.floor((len - M.WORD_BYTES + 7) / M.WORD_STEP)
      end
    elseif b < 0x80 then
      total = total + 1
      i = i + 1
    else
      local len = UTF8_LEN[b]
      local ok = len > 1 and (i + len - 1) <= n
      if ok then
        for k = 1, len - 1 do
          local c = source:byte(i + k)
          if c < 0x80 or c > 0xBF then ok = false break end
        end
      end
      i = i + (ok and len or 1)
      total = total + 1
    end
  end
  return total
end

-- 路径是否计入预算：三端根、且路径上没有任何排除目录。
function M.in_scope(path)
  local root = tostring(path or ""):match("^([^/]+)/")
  if not root or not SCOPE_ROOTS[root] then return false end
  for segment in tostring(path):gmatch("[^/]+") do
    if SKIP_DIRS[segment] then return false end
  end
  return true
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then return nil, err end
  local body = file:read("a")
  file:close()
  return body
end

-- 遍历三端，按路径字典序返回 { {path=, tokens=}, ... }；读不出的文件直接报错，不静默跳过。
function M.measure(root)
  local rows = {}
  local function scan(dir, rel)
    local iter, state, ctrl = lfs.dir(dir)
    for entry in iter, state, ctrl do
      if entry ~= "." and entry ~= ".." then
        local full = dir .. "/" .. entry
        local sub = rel == "" and entry or rel .. "/" .. entry
        local mode = lfs.attributes(full, "mode")
        if mode == "directory" then
          if not SKIP_DIRS[entry] then scan(full, sub) end
        elseif mode == "file" and entry:match("%.lua$") then
          local body, err = read_file(full)
          if not body then return nil, "读取失败: " .. tostring(err) end
          rows[#rows + 1] = { path = sub, tokens = M.count(body) }
        end
      end
    end
    return true
  end
  for root_name in pairs(SCOPE_ROOTS) do
    local dir = root .. "/" .. root_name
    if lfs.attributes(dir, "mode") == "directory" then
      local ok, err = scan(dir, root_name)
      if not ok then return nil, err end
    end
  end
  table.sort(rows, function(a, b) return a.path < b.path end)
  return rows
end

-- 基线文本 -> { [路径] = token 数 }；-- 开头与空行跳过。
function M.parse_baseline(text)
  local set = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local path, tokens = line:match("^(%S+):(%d+)%s*$")
    if path and path:sub(1, 2) ~= "--" then set[path] = tonumber(tokens) end
  end
  return set
end

-- 返回 set, missing：文件不存在时 missing=true，调用方据此给出「先跑 --update-baseline」的提示。
function M.read_baseline(root)
  local path = root .. "/" .. M.BASELINE
  if lfs.attributes(path) == nil then return {}, true end
  local body, err = read_file(path)
  if not body then return nil, "读取基线失败: " .. tostring(err) end
  return M.parse_baseline(body), false
end

function M.write_baseline(root, over)
  local lines = {
    "-- token 预算基线（ADR-0041）：由 lua tools/cli.lua size --update-baseline 写入。",
    "-- 逐行格式：相对路径:token 数；棘轮只许减少，基线外的新超限文件由门禁拦住。",
  }
  local sorted = {}
  for _, row in ipairs(over) do sorted[#sorted + 1] = row end
  table.sort(sorted, function(a, b)
    if a.tokens == b.tokens then return a.path < b.path end
    return a.tokens > b.tokens
  end)
  for _, row in ipairs(sorted) do
    lines[#lines + 1] = row.path .. ":" .. row.tokens
  end
  local file, err = io.open(root .. "/" .. M.BASELINE, "wb")
  if not file then return nil, err end
  local ok, close_err = file:write(table.concat(lines, "\n") .. "\n")
  file:close()
  if not ok then return nil, close_err end
  return true
end

-- 把测量结果与基线比对：over 是全部超限文件，new 是基线外的新超限文件。
function M.check(rows, baseline)
  local over, new = {}, {}
  for _, row in ipairs(rows) do
    if row.tokens > M.LIMIT then
      over[#over + 1] = row
      if not baseline[row.path] then new[#new + 1] = row end
    end
  end
  return over, new
end

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua size [--update-baseline|--report]",
    "",
    "按 " .. M.TOKENIZER .. " 口径统计 client/common/server（排除 packages、data、_trigger、tests、tmp），",
    "单个文件超过 " .. M.LIMIT .. " tokens 且不在 " .. M.BASELINE .. " 里即失败（退出码 1）。",
    "--update-baseline 只在没有新超限文件时收窄基线（棘轮只许减少）；--report 只列超限清单不判红。",
  }, "\n") .. "\n"
end

function M.parse(args)
  local opts = { mode = "check" }
  for _, a in ipairs(args or {}) do
    if a == "--help" or a == "-h" then
      opts.help = true
    elseif a == "--update-baseline" then
      if opts.mode ~= "check" then return nil, "重复指定 --update-baseline" end
      opts.mode = "update"
    elseif a == "--report" then
      if opts.mode ~= "check" then return nil, "重复指定 --report" end
      opts.mode = "report"
    else
      return nil, "未知参数: " .. tostring(a)
    end
  end
  return opts
end

local function sorted_by_tokens(rows)
  local out = {}
  for _, row in ipairs(rows) do out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.tokens == b.tokens then return a.path < b.path end
    return a.tokens > b.tokens
  end)
  return out
end

local function print_over(prefix, rows)
  io.stderr:write(prefix .. "\n")
  for i = 1, math.min(#rows, 20) do
    local row = rows[i]
    io.stderr:write(string.format("  %s  %d tokens（超 %d）\n",
      row.path, row.tokens, row.tokens - M.LIMIT))
  end
  if #rows > 20 then io.stderr:write("  ... 其余 " .. (#rows - 20) .. " 个省略\n") end
end

function M.main(args, env)
  local opts, err = M.parse(args or {})
  if not opts then
    io.stderr:write("size: " .. err .. "\n\n" .. M.usage())
    return exit_code.USAGE
  end
  if opts.help then
    io.write(M.usage())
    return exit_code.OK
  end

  local root = (env and env.repo_root) or "."
  local rows, measure_err = M.measure(root)
  if not rows then
    io.stderr:write("size: " .. tostring(measure_err) .. "\n")
    return exit_code.FAILURE
  end
  local baseline, missing = M.read_baseline(root)
  if not baseline then
    io.stderr:write("size: " .. tostring(missing) .. "\n")
    return exit_code.FAILURE
  end
  local over, new = M.check(rows, baseline)

  if opts.mode == "report" then
    local sorted = sorted_by_tokens(over)
    print(string.format("size: %d 个文件，%d 个超 %d tokens（基线内 %d 个）",
      #rows, #over, M.LIMIT, #over - #new))
    for _, row in ipairs(sorted) do
      print(string.format("  %d tokens  %s", row.tokens, row.path))
    end
    return exit_code.OK
  end

  if opts.mode == "update" then
    if missing then
      -- 首次生成：把当前超限文件全部写入基线。
    elseif #new > 0 then
      print_over("size: 拒绝更新基线：" .. #new .. " 个基线外超限文件（棘轮只许减少）：", new)
      return exit_code.USAGE
    end
    local ok, write_err = M.write_baseline(root, over)
    if not ok then
      io.stderr:write("size: 写入基线失败: " .. tostring(write_err) .. "\n")
      return exit_code.FAILURE
    end
    print(string.format("size: 基线已写入 %s（%d 个超限文件）", M.BASELINE, #over))
    return exit_code.OK
  end

  if missing and #over > 0 then
    io.stderr:write("size: 缺少基线文件 " .. M.BASELINE
      .. "，先跑 lua tools/cli.lua size --update-baseline\n")
    return exit_code.FAILURE
  end
  if #new > 0 then
    print_over(string.format("size: %d 个基线外超限文件（预算 %d tokens / 文件，口径 %s）：",
      #new, M.LIMIT, M.TOKENIZER), new)
    io.stderr:write("  拆分模块后再提交；基线只许收窄，不要靠改预算过关。\n")
    return exit_code.FAILURE
  end
  local max_row = sorted_by_tokens(over)[1]
  print(string.format("size: 门禁通过，%d 个文件均在预算内（存量超限 %d 个在基线内%s）",
    #rows, #over, max_row and string.format("，最大 %s %d tokens", max_row.path, max_row.tokens) or ""))
  return exit_code.OK
end

return M
