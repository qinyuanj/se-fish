-- 模块编译结果缓存：用例夹具常在 before_each 里清掉 package.loaded、再重新 require 整棵模块树，
-- 换一个「模块表全新」的世界。代价是 Lua 每次都要重新解析源码：
-- ferry_test 的世界宿主 35 个模块实测 18.6 ms，其中 14.6 ms 是编译、只有 2.2 ms 是执行。
-- 这里在 package.searchers 里插一个缓存 searcher：模块表仍然由「重新执行 chunk」得到，
-- 唯一不改变的语义是「同一份源码在一个进程里只解析一次」。
-- 唯一不能这么办的情形是「进程内改写某个模块文件、再 require 同一个名字」——那会拿到改写前的
-- chunk。本仓没有这种用例：夹具读写的一律是 tmp/ 下的假仓库，不挂在 package.path 上。
local M = {}

local chunks = {}
local installed = false

local function chunk_of(path)
  local chunk = chunks[path]
  if chunk then return chunk end
  local file, err = loadfile(path)
  if not file then error(err, 0) end
  chunks[path] = file
  return file
end

local function cached_searcher(name)
  -- 找不到时把 searchpath 的「试过哪些路径」原样交出去：require 会把它拼进错误信息。
  -- 全仓的模块解析都经过这个 searcher，报错不能退化成一句空话。
  local path, not_found = package.searchpath(name, package.path)
  if not path then return not_found end
  return chunk_of(path), path
end

-- 装上缓存 searcher（幂等）。必须在用例 require 之前调用；helper 每个进程启动时调一次。
function M.install()
  if installed then return end
  installed = true
  table.insert(package.searchers, 2, cached_searcher)
end

-- 显式 loadfile 的位置复用同一个缓存（返回编译好的 chunk，调用方自己执行）。
-- 只收一个 path：loadfile 还有 (mode, env) 两个参数，带 env 的 chunk 各自绑不同的 _ENV，
-- 缓存起来就会把世界换错。要 env 的地方直接用原生 loadfile。
function M.loadfile(path, ...)
  assert(select("#", ...) == 0, "module_cache.loadfile 只接受一个参数；需要 mode/env 请直接用 loadfile")
  return chunk_of(path)
end

return M
