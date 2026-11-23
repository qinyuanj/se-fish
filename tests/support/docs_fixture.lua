-- docs 子命令的离线官网夹具：只构造 VitePress 响应，不访问网络。
local M = {}
M.SITE = "https://u5-creator.s3.game.163.com/manual/se/"
M.LUA_INDEX = M.SITE .. "lua/README.html"
M.API_INDEX = M.SITE .. "game_api/README.html"
M.CHANGELOG = M.SITE .. "game_api/changelog/changelog_20261119.html"
M.REMOTE_EVENT = M.SITE .. "game_api/classes/RemoteEvent.html"

local function page(title, body)
  return '<html><body><main><div class="vp-doc"><h1>' .. title .. "</h1>" .. body .. "</div></main></body></html>"
end

function M.responses()
  local responses, tutorial_links = {}, {}
  for number = 0, 22 do
    local key = string.format("%02d", number)
    local url = M.SITE .. "lua/" .. key .. "-fixture.html"
    tutorial_links[#tutorial_links + 1] = '<a href="' .. url .. '">第 ' .. key .. ' 章</a>'
    local body = "<p>第 " .. key .. " 章官方正文</p>"
    if number == 8 then
      body = body .. "<p>client_ready_retry 与 &lt;Server&gt; &amp; Client</p>"
    end
    responses[url] = page("第 " .. key .. " 章", body)
  end
  responses[M.LUA_INDEX] = page("SE UGC Lua 开发系列", table.concat(tutorial_links))
  responses[M.API_INDEX] = page("类型索引", table.concat({
    '<a href="/manual/se/game_api/changelog/changelog_20261112.html">旧日志</a>',
    '<a href="/manual/se/game_api/changelog/changelog_20261119.html">最新日志</a>',
    '<a href="/manual/se/game_api/classes/RemoteEvent.html">RemoteEvent</a>',
  }))
  responses[M.CHANGELOG] = page("20261119 更新", "<p>新增正式 API</p>")
  responses[M.REMOTE_EVENT] = page("RemoteEvent", table.concat({
    "<p>FireServer 参数必须是 &lt;table&gt;。</p>",
    '<pre><code><span class="line"><span>RemoteEvent:FireServer(player)</span></span></code></pre>',
  }))
  return responses
end

return M
