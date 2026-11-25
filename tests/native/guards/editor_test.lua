-- editor 命令与宿主 log.txt 阈值清理的门禁测试。
local fs = require("tests.support.fs_fixture")
local editor = require("tools.editor")
local host_log = require("tools.host_log")
local seam = require("tools.seam")

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

  it("keeps empty or fresh small host log and flags oversize or stale log", function()
    local ok, reason = host_log.should_clean({ size = 0, mtime = 0 })
    assert.is_false(ok)
    assert.are.equal("missing_or_empty", reason)

    ok, reason = host_log.should_clean({ size = 1024, mtime = 1000 },
      { max_bytes = 5000, max_age_sec = 3600, now = 2000 })
    assert.is_false(ok)
    assert.are.equal("below_threshold", reason)

    ok, reason = host_log.should_clean({ size = 5001, mtime = 1999 },
      { max_bytes = 5000, max_age_sec = 3600, now = 2000 })
    assert.is_true(ok)
    assert.are.equal("size", reason)

    ok, reason = host_log.should_clean({ size = 128, mtime = 1000 },
      { max_bytes = 5000, max_age_sec = 3600, now = 5000 })
    assert.is_true(ok)
    assert.are.equal("age", reason)
  end)

  it("removes host log when over threshold and skips cleanly when locked", function()
    local ws = ROOT .. "/ws"
    fs.write_file(ws .. "/log.txt", "1234567890")

    local locked = host_log.clean(ws, {
      max_bytes = 5,
      remove_fn = function() return nil, "Permission denied" end,
    })
    assert.are.equal("locked", locked.status)
    assert.is_true(seam.exists(ws .. "/log.txt"))

    local removed = host_log.clean(ws, { max_bytes = 5 })
    assert.are.equal("removed", removed.status)
    assert.is_false(seam.exists(ws .. "/log.txt"))
  end)
end)
