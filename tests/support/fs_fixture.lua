-- 测试支撑层唯一入口：只提供环境事实与最少落盘助手，不承载断言（ADR-0017）。
-- 纯 Lua/lfs 实现，与生产侧 tools.seam 相互独立（夹具不依赖生产工具）。
local lfs = require("lfs")

local M = {}

local BACKSLASH = string.char(92)
local DQUOTE = string.char(34)

function M.normalize(path)
  if path == nil then return nil end
  return (tostring(path):gsub(BACKSLASH, "/"))
end

function M.exists(path)
  if path == nil then return false end
  return lfs.attributes(tostring(path)) ~= nil
end

local function is_dir(path)
  return lfs.attributes(tostring(path), "mode") == "directory"
end

-- 仓库根：从 cwd 向上找到同时含 .busted 与 AGENTS.md 的目录。
function M.repo_root()
  if M._root then return M._root end
  local dir = M.normalize(lfs.currentdir())
  while dir and dir ~= "" do
    if M.exists(dir .. "/.busted") and M.exists(dir .. "/AGENTS.md") then
      M._root = dir
      return dir
    end
    local parent = dir:match("^(.*)/[^/]+$")
    if not parent or parent == dir then break end
    dir = parent
  end
  M._root = M.normalize(lfs.currentdir())
  return M._root
end

local temp_counter = 0

-- 在仓库 tmp/ 下建一个唯一临时目录并返回其正斜杠路径。
function M.temp_dir()
  local base = M.repo_root() .. "/tmp"
  M.mkdirp(base)
  local dir
  repeat
    temp_counter = temp_counter + 1
    dir = base .. "/fs-fixture-" .. tostring(os.time()) .. "-" .. tostring(temp_counter)
  until not M.exists(dir)
  M.mkdirp(dir)
  return dir
end

function M.slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local body = f:read("a")
  f:close()
  return body
end

function M.mkdirp(path)
  path = M.normalize(path)
  if path == "" or is_dir(path) then return end
  if path:match("^%a:/?$") then return end
  local parent = path:match("^(.*)/[^/]*$")
  if parent and parent ~= "" and parent ~= path then M.mkdirp(parent) end
  lfs.mkdir(path)
end

function M.write_file(path, body)
  path = M.normalize(path)
  local dir = path:match("^(.*)/[^/]*$")
  if dir then M.mkdirp(dir) end
  local f = assert(io.open(path, "wb"), path .. " 建不出来")
  f:write(body)
  f:close()
end

local function rmrf(path)
  local mode = lfs.symlinkattributes(path, "mode")
  if mode == nil then return end
  if mode == "directory" then
    local names = {}
    local ok, iter, state, ctrl = pcall(lfs.dir, path)
    if ok then
      for name in iter, state, ctrl do
        if name ~= "." and name ~= ".." then names[#names + 1] = name end
      end
    end
    for _, name in ipairs(names) do rmrf(path .. "/" .. name) end
    lfs.rmdir(path)
  else
    os.remove(path)
  end
end

function M.rmrf(path)
  if path == nil then return end
  rmrf(M.normalize(path))
end

-- 目录一级条目名，按名排序；目录不存在返回空表。
function M.list_dir(dir)
  local out = {}
  if not is_dir(dir) then return out end
  local ok, iter, state, ctrl = pcall(lfs.dir, dir)
  if not ok then return out end
  for name in iter, state, ctrl do
    if name ~= "." and name ~= ".." then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- 按 PATH 找命令（name.exe / name.bat），只判存在，不做真实调用验证。
function M.find_on_path(name)
  local raw = os.getenv("PATH") or ""
  local names = { name .. ".exe", name .. ".bat" }
  for entry in (raw .. ";"):gmatch("([^;]*);") do
    entry = entry:gsub("^" .. DQUOTE, ""):gsub(DQUOTE .. "$", "")
    if entry ~= "" then
      local dir = M.normalize(entry)
      for _, n in ipairs(names) do
        local full = dir .. "/" .. n
        if M.exists(full) then return full end
      end
    end
  end
  return nil
end

return M
