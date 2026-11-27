-- 代码里的文档锚点必须可解析：`GameSpec.md#8.1-鱼塘`、`GLOSSARY.md#船票`、`GameSpec.md#16-物品基础数据` 这类字符串。
-- 失败方式先列：改名或改题号后锚点静默失效，`DecisionSource` 与 `source` 指向一个不存在的位置，没人发现。
-- 口径见 #351 的 P2。Markdown 链接的锚点由 doc_link_guard_test 负责，这里只管 Lua 源码里的字符串。
local fs = require('tests.support.fs_fixture')
local seam = require('tools.seam')
local doc_anchor = require('tests.support.doc_anchor')

local SCAN_ROOTS = { 'common/', 'client/', 'server/' }

-- 返回两个索引：文档名 -> 全部同名文档路径，扫描范围内的 Lua 文件。
local function track()
  local git = assert(seam.which('git'), 'PATH 上找不到 git')
  local code, output = seam.capture({
    argv = { git, '-c', 'core.quotepath=false', 'ls-files' },
    cwd = fs.repo_root(),
  })
  assert(code == 0, 'git ls-files 失败: ' .. tostring(output))
  local by_name, lua_files = {}, {}
  for line in (output .. '\n'):gmatch('([^\n]+)\n') do
    local path = line:gsub('\r$', '')
    if path:match('%.md$') then
      local name = path:match('([^/]+)$')
      by_name[name] = by_name[name] or {}
      table.insert(by_name[name], path)
    elseif path:match('%.lua$') then
      for _, root in ipairs(SCAN_ROOTS) do
        if path:sub(1, #root) == root then
          lua_files[#lua_files + 1] = path
          break
        end
      end
    end
  end
  table.sort(lua_files)
  return by_name, lua_files
end

local function targets_in(line)
  local found = {}
  for target in line:gmatch("([^%s'\"(),;]+%.md#[^%s'\"(),;]+)") do
    found[#found + 1] = target
  end
  return found
end

describe('文档锚点守卫', function()
  it('test_code_source_anchors_resolve', function()
    local by_name, lua_files = track()
    local bad = {}
    for _, path in ipairs(lua_files) do
      local source = doc_anchor.read(path)
      if source then
        local number = 0
        for line in (source .. '\n'):gmatch('([^\n]*)\n') do
          number = number + 1
          for _, target in ipairs(targets_in(line)) do
            local name, anchor = target:match('^(.+)%.md#(.+)$')
            local candidates = name and by_name[name .. '.md']
            if not candidates or #candidates ~= 1 then
              bad[#bad + 1] = path .. ':' .. number .. ' -> ' .. target .. '（找不到唯一的目标文档）'
            else
              local body = doc_anchor.read(candidates[1])
              if not body then
                bad[#bad + 1] = path .. ':' .. number .. ' -> ' .. target .. '（读不到目标文档）'
              elseif not doc_anchor.exists(body, anchor, { table_rows = true, section_objects = true }) then
                bad[#bad + 1] = path .. ':' .. number .. ' -> ' .. target .. '（锚点不存在）'
              end
            end
          end
        end
      end
    end
    table.sort(bad)
    assert.same({}, bad)
  end)
end)
