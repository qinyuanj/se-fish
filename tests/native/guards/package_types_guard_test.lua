-- types/packages/ 公开契约层守卫（ADR-0038）：
-- 1. 业务代码里每一条 require("*.packages.*") 必须在 types/packages/ 下有对应的 ---@meta 声明；
-- 2. types/packages/ 下每一条 ---@meta 声明对应的真实包文件必须存在，防止包改名/删除后声明悬空；
-- 3. 纯 Lua 包入口的顶层导出键必须全部在对应的 types/packages/ 声明中出现。

local fs = require("tests.support.fs_fixture")
local lfs = require("lfs")

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local src = file:read("*a")
  file:close()
  return src
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

local function walk_lua_files(dir, out, skip_dirs)
  out = out or {}
  for _, name in ipairs(fs.list_dir(dir)) do
    local full = dir .. "/" .. name
    if lfs.attributes(full, "mode") == "directory" then
      if not (skip_dirs and skip_dirs[name]) then
        walk_lua_files(full, out, skip_dirs)
      end
    elseif name:match("%.lua$") then
      out[#out + 1] = full
    end
  end
  return out
end

local function collect_meta_declarations()
  local meta_map = {}
  for _, path in ipairs(walk_lua_files("types/packages")) do
    local src = read_file(path)
    local mod = src:match("^%s*%-%-%-@meta%s+([%w_%.]+)")
    assert.is_truthy(mod, path .. " 首行缺少 ---@meta <module_name> 声明")
    assert.is_nil(meta_map[mod], "重复的 ---@meta 声明: " .. mod .. " (" .. path .. ")")
    meta_map[mod] = { path = path, src = src }
  end
  return meta_map
end

local function collect_business_package_requires()
  local required = {}
  local skip = { packages = true, _trigger = true, tests = true }
  for _, root in ipairs({ "client", "common", "server" }) do
    for _, path in ipairs(walk_lua_files(root, nil, skip)) do
      local src = read_file(path)
      for mod in src:gmatch('require%s*%(%s*["\']([%w_%.]+)["\']%s*%)') do
        if mod:find("%.packages%.", 1, false) then
          required[mod] = required[mod] or {}
          required[mod][#required[mod] + 1] = path
        end
      end
    end
  end
  return required
end

describe("package_types_guard", function()
  it("业务代码引用的每个 packages 模块在 types/packages/ 下都有对应 ---@meta 声明", function()
    local meta_map = collect_meta_declarations()
    local required = collect_business_package_requires()
    local missing = {}
    for mod, refs in pairs(required) do
      if not meta_map[mod] then
        missing[#missing + 1] = mod .. "（引用自 " .. refs[1] .. "）"
      end
    end
    table.sort(missing)
    assert.equals(0, #missing, "缺少 types/packages/ 契约声明:\n  " .. table.concat(missing, "\n  "))
  end)

  it("types/packages/ 下每个 ---@meta 声明都对应真实存在的包文件", function()
    local meta_map = collect_meta_declarations()
    local dangling = {}
    for mod, info in pairs(meta_map) do
      local real_path = mod:gsub("%.", "/") .. ".lua"
      if not file_exists(real_path) then
        dangling[#dangling + 1] = info.path .. " -> " .. real_path
      end
    end
    table.sort(dangling)
    assert.equals(0, #dangling, "存在悬空的包类型声明:\n  " .. table.concat(dangling, "\n  "))
  end)

  it("纯 Lua 包公开入口的顶层导出键全部覆盖在 types/packages/ 声明中", function()
    local meta_map = collect_meta_declarations()
    local pure_modules = {
      "common.packages.spoke.api",
      "common.packages.spoke.runtime.spoke_runtime",
      "common.packages.spoke_eggy.api",
    }
    for _, mod in ipairs(pure_modules) do
      local info = assert(meta_map[mod], "缺少声明: " .. mod)
      local real = require(mod)
      local missing_keys = {}
      for key in pairs(real) do
        if type(key) == "string" and key:sub(1, 1) ~= "_" then
          local pat_field = "M%." .. key .. "%f[^%w_]"
          if not info.src:find(pat_field) then
            missing_keys[#missing_keys + 1] = key
          end
        end
      end
      table.sort(missing_keys)
      assert.equals(0, #missing_keys,
        info.path .. " 缺少导出键声明: " .. table.concat(missing_keys, ", "))
    end
  end)
end)
