-- client/game_ui.lua 宿主 UI 节点按名字查找（GameUI:find_child_ui_node）单元测试。
-- 失败方式先列：
--   1. nil 节点 / nil 名字 / 缺 GetChildren 的节点 / GetChildren 返回 nil 时未先短路，读字段或调用抛错；
--   2. 名字命中时返回副本或重建节点，而不是宿主子节点对象本身（调用方拿到的改写不到宿主节点）；
--   3. 宿主节点还没长出子节点时返回哨兵对象而不是 nil。

-- 模块加载即读 game:GetService("Players")：先注入引擎双再 require，避免测试进程无宿主全局。
local saved_game = rawget(_G, "game")
_G.game = { GetService = function() return {} end }
local GameUI = require("client.game_ui")
_G.game = saved_game

-- find_child_ui_node 依赖的最小宿主节点形态：Name 与可选的 GetChildren。
local function host_node(name)
  return { Name = name }
end

local function host_node_with_children(name, children)
  return { Name = name, GetChildren = function() return children end }
end

describe("宿主 UI 节点按名字查找（client/game_ui.lua）", function()
  it("名字命中的直接子节点按宿主对象身份返回", function()
    local coin_label = host_node("FishCoin")
    local shop_entry = host_node_with_children("ShopEntry", { coin_label })

    local found = GameUI:find_child_ui_node(shop_entry, "FishCoin")

    assert.equal(coin_label, found)
    assert.equal("FishCoin", found.Name)
  end)

  it("宿主节点还没有子节点时返回 nil", function()
    assert.is_nil(GameUI:find_child_ui_node(host_node_with_children("ShopEntry", {}), "FishCoin"))
  end)

  it("节点、名字或宿主读取能力缺失时返回 nil 而不是抛错", function()
    assert.is_nil(GameUI:find_child_ui_node(nil, "FishCoin"))
    assert.is_nil(GameUI:find_child_ui_node(host_node_with_children("ShopEntry", {}), nil))
    assert.is_nil(GameUI:find_child_ui_node(host_node("ShopEntry"), "FishCoin"))
    assert.is_nil(GameUI:find_child_ui_node(host_node_with_children("ShopEntry", nil), "FishCoin"))
  end)
end)
