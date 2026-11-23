-- SE 官方手册的本地只读缓存：显式同步、离线检索，API 成员页按需加入（#290，方案 C）。
-- 所有核心页面先下载并解析到内存，全部成功后才替换缓存；网络或响应格式失败不会触碰旧缓存。
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")
local sha256 = require("tools.sha256")

local M = {}
local ORIGIN = "https://u5-creator.s3.game.163.com"
local SITE = ORIGIN .. "/manual/se/"
local SITE_PATTERN = SITE:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
local LUA_INDEX = SITE .. "lua/README.html"
local API_INDEX = SITE .. "game_api/README.html"
local CACHE_REL = ".toolcache/se-manual"
local MAX_RESULTS = 20

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local body = file:read("a")
  file:close()
  return body
end

local function write_file(path, body)
  seam.ensure_dir(path:match("^(.*)/[^/]*$"))
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  local ok, write_err = file:write(body)
  local close_ok, close_err = file:close()
  if not ok then return nil, write_err end
  if close_ok == nil then return nil, close_err end
  return true
end

-- Windows 的 rename 不覆盖已有文件；先保留备份，替换失败时恢复，避免写入失败丢掉旧缓存。
local function replace_file(path, body)
  local temporary = path .. ".new"
  local backup = path .. ".bak"
  local ok, err = write_file(temporary, body)
  if not ok then return nil, err end
  if not seam.exists(path) then
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary) end
    return renamed, rename_err
  end
  os.remove(backup)
  local backed_up, backup_err = os.rename(path, backup)
  if not backed_up then
    os.remove(temporary)
    return nil, backup_err
  end
  local renamed, rename_err = os.rename(temporary, path)
  if not renamed then
    os.rename(backup, path)
    os.remove(temporary)
    return nil, rename_err
  end
  os.remove(backup)
  return true
end

local function decode_entities(text)
  text = text:gsub("&#x(%x+);", function(value)
    local code = tonumber(value, 16)
    return code and utf8.char(code) or ""
  end)
  text = text:gsub("&#(%d+);", function(value)
    local code = tonumber(value, 10)
    return code and utf8.char(code) or ""
  end)
  local entities = { lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
  text = text:gsub("&(%a+);", function(name) return entities[name] or ("&" .. name .. ";") end)
  return (text:gsub("&amp;", "&"))
end

local function strip_tags(text)
  return (text:gsub("<[^>]*>", ""))
end

local function resolve_url(href, base)
  href = decode_entities(href)
  if href:match("^https?://") then return href end
  if href:sub(1, 1) == "/" then return ORIGIN .. href end
  return (base:match("^(.*)/[^/]*$") or SITE) .. "/" .. href
end

local function extract_links(html, base)
  local links = {}
  for attrs in html:gmatch("<a%s+([^>]*)>") do
    local href = attrs:match('href%s*=%s*"([^"]+)"') or attrs:match("href%s*=%s*'([^']+)'")
    if href then
      local url = resolve_url(href, base):gsub("#.*$", "")
      links[#links + 1] = url
    end
  end
  return links
end

-- 只取 VitePress 的 main，导航栏不进入缓存；链接保留为 Markdown，API 按需解析也以此定位官方 URL。
local function html_to_text(html, url)
  if type(html) ~= "string" or html == "" then return nil, "响应为空" end
  local main = html:match("<main[^>]*>(.-)</main>")
  if not main or not main:find("vp%-doc") then
    return nil, "响应中找不到 VitePress main/vp-doc 正文"
  end
  local title_html = main:match("<h1[^>]*>(.-)</h1>")
  if not title_html then return nil, "正文中找不到 h1 标题" end
  local title = trim(decode_entities(strip_tags(title_html)))
  if title == "" then return nil, "h1 标题为空" end

  main = main:gsub("<script[^>]*>.-</script>", "")
  main = main:gsub("<style[^>]*>.-</style>", "")
  main = main:gsub('<a%s+[^>]*class=["\'][^"\']*header%-anchor[^"\']*["\'][^>]*>.-</a>', "")
  main = main:gsub("<a%s+([^>]*)>(.-)</a>", function(attrs, label)
    local href = attrs:match('href%s*=%s*"([^"]+)"') or attrs:match("href%s*=%s*'([^']+)'")
    label = decode_entities(strip_tags(label))
    if not href or href:sub(1, 1) == "#" then return label end
    return "[" .. label .. "](" .. resolve_url(href, url) .. ")"
  end)
  for level = 1, 6 do
    main = main:gsub("<h" .. level .. "[^>]*>(.-)</h" .. level .. ">", function(text)
      return "\n" .. string.rep("#", level) .. " " .. text .. "\n"
    end)
  end
  local fence = string.rep(string.char(96), 3)
  main = main:gsub("<pre[^>]*>", "\n" .. fence .. "\n"):gsub("</pre>", "\n" .. fence .. "\n")
  main = main:gsub('<span[^>]*class=["\']line["\'][^>]*>', "\n")
  main = main:gsub("<li[^>]*>", "\n- ")
  main = main:gsub("<br%s*/?>", "\n")
  main = main:gsub("</t[dh]>", " | ")
  main = main:gsub("</p>", "\n"):gsub("</div>", "\n"):gsub("</li>", "\n")
  main = main:gsub("</tr>", "\n"):gsub("</table>", "\n"):gsub("</ul>", "\n"):gsub("</ol>", "\n")
  main = decode_entities(strip_tags(main))
  main = main:gsub("\r", ""):gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")
  main = main:gsub("\n%s*\n%s*\n+", "\n\n")
  return trim(main) .. "\n", nil, title
end

local function relative_path(url)
  local path = url:match("^" .. SITE_PATTERN .. "([^?#]+)%.html$")
  if not path or path:find("\\", 1, true) or path:find("..", 1, true) then return nil end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then return nil end
  end
  return path .. ".txt"
end

local function make_fetcher(root)
  local curl = seam.which("curl")
  if not curl then
    exit_code.unavailable("docs sync: 找不到 curl；请安装 curl 并确认它在 PATH 中")
  end
  return function(url)
    local code, output = seam.capture({
      argv = { curl, "--fail", "--location", "--silent", "--show-error", "--max-time", "30", url },
      cwd = root,
      tmp_dir = root .. "/tmp",
    })
    if code ~= 0 then
      return nil, string.format("下载失败（curl 退出码 %s）：%s", tostring(code), trim(output))
    end
    return output
  end
end

local function load_document(fetch, url, changelog_version, prefetched_html)
  local html, fetch_err = prefetched_html
  if not html then html, fetch_err = fetch(url) end
  if not html then return nil, url .. "\n" .. fetch_err end
  local text, parse_err, title = html_to_text(html, url)
  if not text then return nil, url .. "\n解析失败：" .. parse_err end
  local relative = relative_path(url)
  if not relative then return nil, "拒绝缓存非预期官方路径：" .. url end
  local hash = sha256.hex(text)
  local metadata = {
    "---",
    "title: " .. title,
    "source: " .. url,
    "fetched_at: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    "sha256: " .. hash,
  }
  if changelog_version then metadata[#metadata + 1] = "changelog_version: " .. changelog_version end
  metadata[#metadata + 1] = "---\n"
  return { url = url, relative = relative, body = table.concat(metadata, "\n") .. text, hash = hash }
end

local function core_urls(lua_html, api_html)
  local tutorials, seen = {}, {}
  for _, url in ipairs(extract_links(lua_html, LUA_INDEX)) do
    local number = url:match(SITE_PATTERN .. "lua/(%d%d)%-[^?#]+%.html$")
    if number and not seen[number] then
      tutorials[number] = url
      seen[number] = true
    end
  end
  local urls = { LUA_INDEX }
  for number = 0, 22 do
    local key = string.format("%02d", number)
    if not tutorials[key] then return nil, "教程索引缺少 " .. key .. " 章，官网目录可能已变化" end
    urls[#urls + 1] = tutorials[key]
  end
  urls[#urls + 1] = API_INDEX

  local latest_url, latest_version
  for _, url in ipairs(extract_links(api_html, API_INDEX)) do
    local version = url:match("game_api/changelog/changelog_(%d+)%.html$")
    if version and (not latest_version or version > latest_version) then
      latest_url, latest_version = url, version
    end
  end
  if not latest_url then return nil, "API 总索引缺少 game_api changelog，官网目录可能已变化" end
  urls[#urls + 1] = latest_url
  return urls, nil, latest_url, latest_version
end

local function commit_documents(root, documents)
  local cache = root .. "/" .. CACHE_REL
  for _, document in ipairs(documents) do
    local path = cache .. "/" .. document.relative
    local previous = read_file(path)
    document.changed = not previous or previous:match("sha256: (%x+)") ~= document.hash
    local ok, err = replace_file(path, document.body)
    if not ok then return nil, "写入缓存失败 " .. path .. "：" .. tostring(err) end
    io.stdout:write(string.format("%s %s\n", document.changed and "已更新" or "内容未变化（已刷新元数据）", CACHE_REL .. "/" .. document.relative))
  end
  return true
end

local function sync_core(root)
  local fetch = make_fetcher(root)
  local lua_html, lua_err = fetch(LUA_INDEX)
  if not lua_html then return nil, LUA_INDEX .. "\n" .. lua_err end
  local api_html, api_err = fetch(API_INDEX)
  if not api_html then return nil, API_INDEX .. "\n" .. api_err end
  local urls, discover_err, changelog_url, version = core_urls(lua_html, api_html)
  if not urls then return nil, discover_err end

  local documents = {}
  local prefetched = { [LUA_INDEX] = lua_html, [API_INDEX] = api_html }
  for _, url in ipairs(urls) do
    local document, err = load_document(fetch, url, url == changelog_url and version or nil, prefetched[url])
    if not document then return nil, err end
    documents[#documents + 1] = document
  end
  return commit_documents(root, documents)
end

local function api_urls_from_index(root)
  local index = read_file(root .. "/" .. CACHE_REL .. "/game_api/README.txt")
  if not index then return nil, "本地没有 API 总索引；请先运行 lua tools/cli.lua docs sync" end
  local urls, seen = {}, {}
  for url in index:gmatch(SITE_PATTERN .. "game_api/[^%s%)]+") do
    url = url:gsub("[.,;，。；]$", "")
    if url:match("%.html$") and not seen[url] then
      seen[url] = true
      urls[#urls + 1] = url
    end
  end
  return urls
end

local function resolve_api_url(root, query)
  if query:match("^https?://") then
    if not query:match("^" .. SITE_PATTERN .. "game_api/[^?#]+%.html$") then
      return nil, "API 页面必须是官方 manual/se/game_api/ 下不带查询参数或锚点的 .html URL"
    end
    if not relative_path(query) then return nil, "API URL 含非法路径" end
    return query
  end
  local urls, err = api_urls_from_index(root)
  if not urls then return nil, err end
  local matches = {}
  local wanted = query:lower():gsub("%.html$", "")
  for _, url in ipairs(urls) do
    local path = url:match("/game_api/(.+)%.html$")
    local name = path and path:match("([^/]+)$")
    if path and (name:lower() == wanted or path:lower() == wanted) then matches[#matches + 1] = url end
  end
  if #matches == 0 then return nil, "API 总索引中找不到 " .. query .. "；可传入官方完整 URL" end
  if #matches > 1 then return nil, "API 名称有歧义，请改用完整 URL：\n" .. table.concat(matches, "\n") end
  return matches[1]
end

local function sync_api(root, query)
  local url, err = resolve_api_url(root, query)
  if not url then return nil, err end
  local document, load_err = load_document(make_fetcher(root), url)
  if not document then return nil, load_err end
  return commit_documents(root, { document })
end

local function search(root, query)
  local cache = root .. "/" .. CACHE_REL
  local files = seam.list_files(cache) or {}
  local matches, document_count = {}, 0
  local needle = query:lower()
  for _, relative in ipairs(files) do
    if relative:match("%.txt$") then
      document_count = document_count + 1
      local body = read_file(cache .. "/" .. relative) or ""
      local source = body:match("source: ([^\r\n]+)") or "未知来源"
      local line_number = 0
      for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        if line:lower():find(needle, 1, true) and not line:match("^source:") then
          matches[#matches + 1] = { path = relative, line = line_number, source = source, text = trim(line) }
        end
      end
    end
  end
  if document_count == 0 then
    io.stderr:write("docs search: 本地缓存为空；请先运行 lua tools/cli.lua docs sync\n")
    return exit_code.FAILURE
  end
  io.stdout:write(string.format("查询 %q：%d 条命中%s\n", query, #matches, #matches > MAX_RESULTS and string.format("（仅显示前 %d 条）", MAX_RESULTS) or ""))
  for index = 1, math.min(#matches, MAX_RESULTS) do
    local match = matches[index]
    io.stdout:write(string.format("%s/%s:%d\n来源: %s\n%s\n", CACHE_REL, match.path, match.line, match.source, match.text))
  end
  return exit_code.OK
end

function M.usage()
  return [=[用法:
  lua tools/cli.lua docs sync
  lua tools/cli.lua docs sync api <类型名或官方 URL>
  lua tools/cli.lua docs search <查询>

sync 缺省同步 lua/00–22、教程索引、game_api/README 与 API 总索引所列最新 changelog。
sync api 只增加一个 API 成员页；类型名由已缓存的 API 总索引解析，也可传官方完整 URL。
search 只读 .toolcache/se-manual/，大小写不敏感地查找字面文本，最多显示 20 条。
同步显式触发，不自动刷新；任一下载或解析失败时保留旧缓存。curl 缺失退出码 3。
]=]
end

function M.main(args, env)
  local root = env and env.repo_root or assert(seam.absolute("."))
  local action, first = args[1], args[2]
  if action == "--help" or action == "-h" then
    io.stdout:write(M.usage())
    return exit_code.OK
  elseif action == "search" then
    if not first or #args < 2 then
      io.stderr:write("docs search: 缺少查询文本\n\n" .. M.usage())
      return exit_code.USAGE
    end
    return search(root, table.concat(args, " ", 2))
  elseif action ~= "sync" then
    io.stderr:write("docs: 未知操作 " .. tostring(action) .. "\n\n" .. M.usage())
    return exit_code.USAGE
  end

  return exit_code.protect(function()
    local ok, err
    if first == nil then
      ok, err = sync_core(root)
    elseif first == "api" and args[3] and #args == 3 then
      ok, err = sync_api(root, args[3])
    else
      io.stderr:write("docs sync: 参数错误\n\n" .. M.usage())
      return exit_code.USAGE
    end
    if not ok then
      io.stderr:write("docs sync: " .. tostring(err) .. "\n旧缓存未被本次下载或解析失败覆盖。\n")
      return exit_code.FAILURE
    end
    return exit_code.OK
  end)
end

return M
