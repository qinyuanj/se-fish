-- editor 命令的门禁测试：状态摘要、CLI JSON 解析与缺省地图选取。
local fs = require("tests.support.fs_fixture")
local editor = require("tools.editor")

local ROOT = fs.temp_dir()
after_each(function() fs.rmrf(ROOT) end)

describe("EditorCommandGuard", function()
  it("parses CLI json behind a warning line", function()
    local parsed, err = editor.parse_json("warning: editor xml not found\n"
      .. '{"running":true,"ready":true,"role":"editor","map_name":"钓鱼怎么这么危险啊喂！","editor_mode":"se","map_id":"abc"}')
    assert.is_nil(err)
    assert.is_true(parsed.ready)
    local bad = editor.parse_json("no json here")
    assert.is_nil(bad)
  end)

  it("summarizes an open map and a launcher separately", function()
    local opened = editor.summary({ running = true, ready = true, role = "editor",
      map_name = "钓鱼怎么这么危险啊喂！", editor_mode = "se", map_id = "abc" })
    assert.is_truthy(opened:find("地图已打开", 1, true))
    local launcher = editor.summary({ running = true, ready = false, role = "launcher",
      lifecycle = "account", editor_mode = "fs" })
    assert.is_truthy(launcher:find("未进图", 1, true))
    assert.is_truthy(launcher:find("launcher", 1, true))
  end)

  it("picks newest SE map from ledger and ignores other modes", function()
    local ledger = '{"old":{"is_se":true,"updated_at":10,"map_dir":"C:/old"},'
      .. '"new":{"is_se":true,"updated_at":20,"map_dir":"C:/new"},'
      .. '"fs":{"is_se":false,"updated_at":30,"map_dir":"C:/fs"}}'
    local map = editor.parse_map_ledger(ledger)
    assert.are.equal("new", map.id)
    assert.are.equal("C:/new", map.dir)
    assert.is_nil(editor.parse_map_ledger("bad json"))
  end)
end)
