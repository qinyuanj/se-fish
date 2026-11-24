-- 旧名字符串守卫（#337）：L3a/L3b 改过的方法名，不许再以字符串字面量的形式留在业务源码里。
-- 为什么要有这一层：
--   1. 静态改名器只改标识符，`local Actions = { board = "board" }` 这类字符串键它看不见；
--   2. 这类键漏改不会在加载期报错，只会在运行期取到 nil，L3b 为此付了 7 轮修键；
--   3. 全量禁旧名字符串会把协议动作串（`action = "board"`）、策划枚举（`Kind = 'land'`）、
--      官方服务/属性名（`GetService("Players")`、`"MaxHealth"`）一起拦下，门禁必然被静音。
-- 所以按上下文放行三类「不是方法名」的串：协议字段值、官方服务/属性/节点名、配置枚举；
-- 表构造里的非协议键、`has_method(x, "Start")`、`x["Attach"]`、普通局部变量一律拦。
-- 剩下确实属于官方契约的个别点写进 data/string_key_exemptions.txt，逐条带理由。
-- 数据源就是 tools/naming/data/l3a_renames.txt、l3b_renames.txt 与 post_l3_renames.txt（L3a/L3b 与 recon/apply 共用）。
local lfs = require("lfs")

local M = {}

local ROOTS = { "client", "common", "server" }
local SKIP_DIR_NAMES = { packages = true, _trigger = true }
local DATA_DIR = "tools/naming/data"

-- 官方契约上下文：出现在这些调用/字段里的字符串是引擎/协议名字，不是自研方法名。
-- 出处：docs/engine-keys.md 五类豁免；新增前先确认真是官方或线上协议。
local OFFICIAL_CONTEXT = {
  "action", "GetService", "GetAttribute", "SetAttribute", "read_player_attr",
  "attr", "get_re", "send", "Name", "Parent", "FindFirstChild", "CreateUnit",
  "effect", "Dock", "export", "import", "Kind", "type", "State", "WeaponAction",
  "reply", "fail", "notify", "record_fact", "callback", "logFailure", "dock",
  "memo", "fire_re", "default_fire_re", "bindRE", "RemoteEvent",
  "read_attr", "write_attr",
}
-- 直接就是官方属性/服务/节点名的旧名；它们可能出现在数组字面量里，没有调用上下文。
local OFFICIAL_NAMES = {
  Players = true, Text = true, MaxHealth = true, Health = true, MaxHunger = true, Hunger = true,
}

-- 协议/展示字段的键名：这些键上的旧名字符串是线上协议或引擎契约，不是方法名。
-- 只留 action/event/kind/type/name/state 这类真正的协议键；command/key/op 等分发表键按旧名拦。
local PROTOCOL_KEYS = {
  action = true, event = true, kind = true, type = true, name = true, id = true,
  state = true, remote = true, route = true, tag = true,
  text = true, title = true, label = true, message = true, reason = true, mode = true,
  event_name = true, action_name = true,
}

local function normalize(path)
  return (tostring(path):gsub("\\", "/"))
end

local function join(root, rel)
  return normalize(root) .. "/" .. rel
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

local function parse_rows(body)
  local rows = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local old_name, new_name = trimmed:match("^(%S+)%s+(%S+)$")
      assert(old_name, "映射行格式不对：" .. line)
      rows[#rows + 1] = { old_name = old_name, new_name = new_name }
    end
  end
  return rows
end

-- 映射表：l3a 是 449 个标识符（含局部变量/字段），l3b 是 45 个方法名，
-- post_l3 是 L3 之后（PR #345 / ADR-0037 L4d）补充迁移的高危旧键（可选）。
-- 三层的旧名集合合并；新名只用于报错时提示改成什么。
function M.load_names(root)
  local l3a = parse_rows(assert(slurp(join(root, DATA_DIR .. "/l3a_renames.txt")), "缺 l3a 映射"))
  local l3b = parse_rows(assert(slurp(join(root, DATA_DIR .. "/l3b_renames.txt")), "缺 l3b 映射"))
  local post_l3_body = slurp(join(root, DATA_DIR .. "/post_l3_renames.txt"))
  local post_l3 = post_l3_body and parse_rows(post_l3_body) or {}
  local new_by_old = {}
  for _, row in ipairs(l3a) do new_by_old[row.old_name] = row.new_name end
  for _, row in ipairs(l3b) do new_by_old[row.old_name] = row.new_name end
  for _, row in ipairs(post_l3) do new_by_old[row.old_name] = row.new_name end
  return { l3a = l3a, l3b = l3b, post_l3 = post_l3, new_by_old = new_by_old }
end

-- 同一个旧名不能同时出现在两层，否则 apply 的先后顺序会决定结果。
function M.find_duplicate_old_names(names)
  local seen, duplicates = {}, {}
  for _, layer in ipairs({ "l3a", "l3b", "post_l3" }) do
    for _, row in ipairs(names[layer] or {}) do
      if seen[row.old_name] then
        duplicates[#duplicates + 1] = row.old_name
      else
        seen[row.old_name] = true
      end
    end
  end
  return duplicates
end

-- 两个旧名映射到同一新名会把不同字段静默合并；与旧名唯一同样在加载时拦住。
-- get_state / GetState / CallBack 这类只差大小写的旧名是同一语义，不算冲突。
local function normalized_old(name)
  return name:lower()
end

function M.find_duplicate_new_names(names)
  local seen, duplicates = {}, {}
  for _, layer in ipairs({ "l3a", "l3b", "post_l3" }) do
    for _, row in ipairs(names[layer] or {}) do
      local old = normalized_old(row.old_name)
      if seen[row.new_name] and seen[row.new_name] ~= old then
        duplicates[#duplicates + 1] = row.new_name
      else
        seen[row.new_name] = old
      end
    end
  end
  return duplicates
end

-- 豁免格式：path<TAB>旧名<TAB>理由。不加行号：行号会随无关改动漂移，这里按「文件 + 字面量」放行。
function M.load_exemptions(root)
  local body = slurp(join(root, DATA_DIR .. "/string_key_exemptions.txt")) or ""
  local set = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local path, literal, reason = trimmed:match("^(%S+)\t([^\t]+)\t(.+)$")
      assert(path, "豁免行格式不对：" .. line)
      set[normalize(path) .. "\0" .. literal] = reason
    end
  end
  return set
end

local function line_starts(src)
  local starts = { 1 }
  local pos = 1
  while true do
    local nl = src:find("\n", pos, true)
    if not nl then break end
    starts[#starts + 1] = nl + 1
    pos = nl + 1
  end
  return starts
end

local function line_index(starts, pos)
  local lo, hi = 1, #starts
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if starts[mid] <= pos then lo = mid + 1 else hi = mid - 1 end
  end
  return hi
end

-- 扫出所有短字符串字面量；注释、长字符串不参与（长字符串可能是数据/模板，不是分发键）。
-- 返回 { value, start, finish, line }，行号按字面量起点算。
local function find_strings(src)
  local out = {}
  local starts = line_starts(src)
  local i, n = 1, #src
  while i <= n do
    local two = src:sub(i, i + 1)
    if two == "--" then
      local eq = src:match("^%[(=*)%[", i + 2)
      if eq then
        local close = "]" .. eq .. "]"
        local stop = src:find(close, i + 4, true)
        i = stop and (stop + #close) or (n + 1)
      else
        local nl = src:find("\n", i + 2, true)
        i = nl and (nl + 1) or (n + 1)
      end
    else
      local ch = src:sub(i, i)
      if ch == '"' or ch == "'" then
        local quote = ch
        local j, buf = i + 1, {}
        while j <= n do
          local c = src:sub(j, j)
          if c == "\\" then
            buf[#buf + 1] = src:sub(j + 1, j + 1)
            j = j + 2
          elseif c == quote then
            break
          elseif c == "\n" then
            j = n + 1
            break
          else
            buf[#buf + 1] = c
            j = j + 1
          end
        end
        if j <= n and src:sub(j, j) == quote then
          out[#out + 1] = {
            value = table.concat(buf),
            start = i,
            finish = j,
            line = line_index(starts, i),
          }
        end
        i = j + 1
      else
        local eq = ch == "[" and src:match("^%[(=*)%[", i) or nil
        if eq then
          local close = "]" .. eq .. "]"
          local stop = src:find(close, i + #eq + 2, true)
          i = stop and (stop + #close) or (n + 1)
        else
          i = i + 1
        end
      end
    end
  end
  return out
end

-- 当前行的前缀；如果字面量独占一行（折行调用/表值），再向上带一至两行，
-- 让 `self:reply(player,\n "board")` 也能命中 reply 上下文。
local function line_prefix(src, starts, pos)
  local idx = line_index(starts, pos)
  local prefix = src:sub(starts[idx], pos - 1)
  local look, extra = idx - 1, 0
  local multiline = prefix:match("^%s*$") ~= nil
  while multiline and look >= 1 and extra < 2 do
    local stop = (starts[look + 1] or (#src + 1)) - 1
    local prev = src:sub(starts[look], stop)
    if prev:match("^%s*$") then break end
    prefix = prev .. "\n" .. prefix
    look = look - 1
    extra = extra + 1
  end
  return prefix, idx
end

local function previous_nonspace(src, pos)
  local i = pos - 1
  while i >= 1 and src:sub(i, i):match("%s") do i = i - 1 end
  return i >= 1 and src:sub(i, i) or ""
end

local function next_nonspace(src, pos)
  local i = pos + 1
  while i <= #src and src:sub(i, i):match("%s") do i = i + 1 end
  return i <= #src and src:sub(i, i) or ""
end

-- 官方上下文按标识符边界匹配，避免 send 命中 failed、type 命中 prototype 这类子串后门。
local function has_context(prefix, word)
  if word == "send" then
    return prefix:find("send_", 1, true) ~= nil or prefix:find("send(", 1, true) ~= nil
  end
  local escaped = word:gsub("(%W)", "%%%1")
  return prefix:find("%f[%w_]" .. escaped .. "%f[^%w_]") ~= nil
end

local function classify(src, starts, item)
  local prefix = line_prefix(src, starts, item.start)
  -- 按名查找：has_method(x, "Start")
  if prefix:find("has_method", 1, true) then
    return "has_method 按名查找"
  end
  -- 直接下标：x["Attach"] / { ["Attach"] = ... }
  if previous_nonspace(src, item.start) == "[" and next_nonspace(src, item.finish) == "]" then
    return "字符串下标查找"
  end
  -- 显式 rawget/rawset 按名查找：rawget(t, "MaxHealth") / rawset(t, "LongPressSec", v)
  if prefix:find("raw[gs]et%s*%([^,]+,%s*$") then
    return "rawget/rawset 按名查找"
  end
  if OFFICIAL_NAMES[item.value] then return nil end
  -- 表值：{ board = "board" }。键名是协议字段时放行（action/kind/name...）。
  local key = prefix:match("([%a_][%w_]*)%s*=%s*$")
  if key then
    if not PROTOCOL_KEYS[key:lower()] then
      return "表值旧方法名（键 " .. key .. "）"
    end
    return nil
  end
  for _, word in ipairs(OFFICIAL_CONTEXT) do
    if has_context(prefix, word) then return nil end
  end
  return "旧名字符串"
end

-- 单文件扫描，测试也走这里；exemptions 为空表时表示不豁免。
function M.scan_source(rel, src, exemptions, names)
  names = names or M.load_names(".")
  exemptions = exemptions or {}
  rel = normalize(rel)
  local starts = line_starts(src)
  local bad = {}
  for _, item in ipairs(find_strings(src)) do
    local new_name = names.new_by_old[item.value]
    if new_name and not exemptions[rel .. "\0" .. item.value] then
      local why = classify(src, starts, item)
      if why then
        bad[#bad + 1] = {
          where = rel .. ":" .. item.line,
          literal = item.value,
          new_name = new_name,
          why = why,
        }
      end
    end
  end
  return bad
end

local function is_dir(path)
  return lfs.attributes(path, "mode") == "directory"
end

local function walk(path, rel, out)
  for entry in lfs.dir(path) do
    if entry ~= "." and entry ~= ".." then
      local full = path .. "/" .. entry
      local sub = rel == "" and entry or rel .. "/" .. entry
      local mode = lfs.attributes(full, "mode")
      if mode == "directory" then
        if not SKIP_DIR_NAMES[entry] then walk(full, sub, out) end
      elseif mode == "file" and entry:match("%.lua$") then
        out[#out + 1] = { full = full, rel = sub }
      end
    end
  end
end

-- 业务源码全扫：client/common/server，排除 packages 与 _trigger（与命名基线同一扫描面）。
-- root 是要扫的仓库；data_root 缺省同 root，允许用当前仓库的映射去扫父提交 worktree。
function M.scan(root, data_root)
  root = normalize(root)
  data_root = normalize(data_root or root)
  local names = M.load_names(data_root)
  local exemptions = M.load_exemptions(data_root)
  local files = {}
  for _, top in ipairs(ROOTS) do
    local dir = root .. "/" .. top
    if is_dir(dir) then walk(dir, top, files) end
  end
  table.sort(files, function(a, b) return a.rel < b.rel end)
  if #files == 0 then
    return nil, "没有扫到任何业务文件（client/common/server 都不存在？目标根：" .. root .. "）"
  end
  local bad = {}
  for _, file in ipairs(files) do
    local src = slurp(file.full)
    if src then
      for _, item in ipairs(M.scan_source(file.rel, src, exemptions, names)) do
        bad[#bad + 1] = item
      end
    end
  end
  return bad
end

return M
