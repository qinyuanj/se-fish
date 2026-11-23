-- #309 活鱼旧模块棘轮（ADR-0032 / #292 Testing Decisions）
-- 失败方式：旧活鱼、载体、AI 管理器或客户端战斗标签仍可加载，或业务源码仍引用它们。
-- 接缝：源码登记与可加载性。不放宽玩法断言，不窥探 Effect 拓扑。

local fs = require("tests.support.fs_fixture")
local lfs = require("lfs")

local REMOVED = {
  "server/Mgr/MgrFishUnit.lua",
  "server/Mgr/MgrFishCarrier.lua",
  "server/Mgr/MgrAi.lua",
  "server/Mgr/MgrAiTarget.lua",
  "client/FishCombatLabel.lua",
  "client/LocalGarBite.lua",
}

local FORBIDDEN = {
  "server.Mgr.MgrFishUnit",
  "server.Mgr.MgrFishCarrier",
  "server.Mgr.MgrAi",
  "server.Mgr.MgrAiTarget",
  "client.FishCombatLabel",
  "client.LocalGarBite",
}

local ROOTS = { "client", "common", "server" }

local function list_lua(dir, out)
  out = out or {}
  for _, name in ipairs(fs.list_dir(dir)) do
    local full = dir .. "/" .. name
    local mode = lfs.attributes(full, "mode")
    if mode == "directory" and name ~= "packages" and name ~= "_trigger" then
      list_lua(full, out)
    elseif mode == "file" and name:match("%.lua$") then
      out[#out + 1] = full
    end
  end
  return out
end

describe("活鱼旧模块棘轮（#309）", function()
  it("旧活鱼、载体、AI 管理器与客户端战斗标签已不可加载", function()
    for _, path in ipairs(REMOVED) do
      assert.is_false(fs.exists(path), path .. " 仍在")
    end
    local files = {}
    for _, root in ipairs(ROOTS) do
      list_lua(root, files)
    end
    local hits = {}
    for _, path in ipairs(files) do
      local text = fs.slurp(path) or ""
      for _, name in ipairs(FORBIDDEN) do
        if text:find(name, 1, true) then
          hits[#hits + 1] = path .. " -> " .. name
        end
      end
    end
    assert.equals(0, #hits, table.concat(hits, "\n"))
  end)
end)
