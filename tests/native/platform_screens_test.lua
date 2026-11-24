local GameCfg = require("common.game_cfg")
local ClientWorld = require("tests.support.economy_client")

describe("盲盒与地图商店界面（#312 RootView 宿主）", function()
  local env
  before_each(function() env = ClientWorld.new() end)
  after_each(function() if env then env:cleanup(); env = nil end end)

  local function open_blindbox()
    env:open("blindbox")
  end
  local function blindbox_result(extra)
    local value = { ok = true, seq = 1, pityAfter = 1, draws = { { itemKey = "item7", itemName = "极品罗非鱼" } }, operation = { id = "op-1" } }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
  end

  it("test_awaiting_blocks_repeat_clicks_and_times_out_with_original_query", function()
    open_blindbox()
    env:click("BtnBlindboxSingle")
    env:click("BtnBlindboxTen")
    assert.same(1, #env.sent.blindbox)
    env:step(GameCfg.Blindbox.ResultTimeoutSec - 1)
    assert.same(1, #env.sent.blindbox)
    env:step(1)
    assert.same(2, #env.sent.blindbox)
    assert.same("Query", env.sent.blindbox[2].action)
    assert.matches("原请求", env.notices[#env.notices])
  end)

  it("test_buttons_show_platform_prices_and_send_counts", function()
    open_blindbox()
    assert.matches(tostring(GameCfg.Platform.Goods.blindboxSingle.beans), env:child("BtnBlindboxSingle").Text)
    assert.matches(tostring(GameCfg.Platform.Goods.blindboxTen.beans), env:child("BtnBlindboxTen").Text)
    env:click("BtnBlindboxTen")
    assert.same({ action = "Draw", count = 10, seq = 1 }, env.sent.blindbox[1])
  end)

  it("test_failures_have_readable_notices_and_unlock", function()
    open_blindbox()
    env:click("BtnBlindboxSingle")
    env:ingest("BlindboxResult", { ok = false, seq = 1, reason = "cancel" })
    assert.is_true(env:child("BtnBlindboxSingle").TouchEnabled)
    assert.is_true(#env.notices > 0)
    env:click("BtnBlindboxSingle")
    assert.same(2, env.sent.blindbox[2].seq)
  end)

  it("test_full_inventory_warns_before_landing_and_second_click_confirms", function()
    env:bar({
      slotCount = 1, slots = { { itemId = "item7", count = 1 } },
      backpackCount = 1, backpack = { { itemId = "item7", count = 1 } },
    })
    open_blindbox()
    env:click("BtnBlindboxSingle")
    assert.same(0, #env.sent.blindbox)
    assert.matches("已满", env:child("LabelBlindboxResult").Text)
    env:click("BtnBlindboxSingle")
    assert.same(1, #env.sent.blindbox)
  end)

  it("test_old_response_cannot_unlock_new_request", function()
    open_blindbox()
    env:click("BtnBlindboxSingle")
    env:ingest("BlindboxResult", { ok = false, seq = 1, reason = "cancel" })
    env:click("BtnBlindboxTen")
    env:ingest("BlindboxResult", blindbox_result({ seq = 1 }))
    assert.is_false(env:child("BtnBlindboxTen").TouchEnabled)
    env:ingest("BlindboxResult", blindbox_result({ seq = 2, operation = { id = "op-2" } }))
    assert.is_true(env:child("BtnBlindboxTen").TouchEnabled)
  end)

  it("test_pending_adopts_original_identity_after_lost_state", function()
    open_blindbox()
    env:click("BtnBlindboxSingle")
    env:ingest("BlindboxResult", {
      ok = false, seq = 1, originalSeq = 1, requestId = "req-1",
      reason = "busy", deliveryPending = true,
    })
    env:step(GameCfg.Blindbox.ResultTimeoutSec)
    assert.same({ action = "Query", count = 1, seq = 1, requestId = "req-1" }, env.sent.blindbox[2])
  end)

  it("test_result_shows_draws_updates_pity_and_ignores_replay", function()
    open_blindbox()
    env:ingest("BlindboxResult", blindbox_result({ recovered = true }))
    local text = env:child("LabelBlindboxResult").Text
    assert.matches("极品罗非鱼", text)
    assert.matches("已连续 1 次", env:child("LabelBlindboxPity").Text)
    env:ingest("BlindboxResult", blindbox_result({ pityAfter = 9, draws = { { itemKey = "item31" } } }))
    assert.same(text, env:child("LabelBlindboxResult").Text)
    assert.matches("已连续 1 次", env:child("LabelBlindboxPity").Text)
  end)

  it("test_entry_opens_panel_and_handshakes_state", function()
    assert.is_true(env:click("BtnBlindboxEntry"))
    assert.same("blindbox", env.store.active_modal:now())
    assert.same(1, env.sent.blindbox_state)
    env:ingest("BlindboxResult", { ok = true, action = "State", pity = 3 })
    assert.matches("已连续 3 次", env:child("LabelBlindboxPity").Text)
  end)

  it("test_state_handshake_refreshes_pity_with_content_prize_names", function()
    open_blindbox()
    env:ingest("BlindboxResult", { ok = true, action = "State", pity = 0 })
    assert.matches("大奖", env:child("LabelBlindboxPity").Text)
    assert.matches("极品", env:child("LabelBlindboxPity").Text)
  end)

  it("test_blindbox_clear_and_rebuild_do_not_stack_nodes_or_listeners", function()
    open_blindbox()
    local panel, button = env:child("ScreenBlindbox"), env:child("BtnBlindboxSingle")
    env:click("BtnBlindboxClose")
    env:open("blindbox")
    assert.is_true(panel.Destroyed)
    assert.same(0, button.OnClicked:Count())
    assert.are_not.equal(panel, env:child("ScreenBlindbox"))
  end)

  it("test_adrenaline_offers_render_server_prices_and_buy_selected_goods", function()
    env:open("platform")
    env:ingest("PlatformResult", { ok = true, action = "AdrenalineShop", offers = {
      { key = "adrenaline1", name = "肾上腺素", beans = 1 },
      { key = "adrenaline5", name = "肾上腺素×5", beans = 4 },
    } })
    assert.matches("4", env:child("BtnPlatformOffer_adrenaline5").ButtonText)
    env:click("BtnPlatformOffer_adrenaline5")
    assert.same({ action = "Purchase", goods = "adrenaline5", seq = 1 }, env.sent.platform[1])
    assert.is_false(env:child("BtnPlatformOffer_adrenaline5").Visible)
  end)

  it("test_hud_map_shop_entry_opens_coin_shop", function()
    assert.is_true(env:click("BtnMapShopEntry"))
    assert.same("platform", env.store.active_modal:now())
    assert.same({ action = "OpenCoinShop" }, env.sent.platform[1])
  end)

  it("test_unavailable_and_failures_are_readable_and_grant_reports_overflow", function()
    env:open("platform")
    env:ingest("PlatformResult", { ok = false, reason = "unavailable" })
    assert.matches("不可用", env:child("LabelPlatformResult").Text)
    env:ingest("PlatformResult", { ok = true, action = "Grant", goods = "adrenaline5", overflow = 2 })
    assert.matches("2 件落在面前地上", env:child("LabelPlatformResult").Text)
  end)

  it("test_platform_clear_and_rebuild_do_not_stack_nodes_or_listeners", function()
    env:open("platform")
    local panel, button = env:child("ScreenPlatform"), env:child("BtnPlatformClose")
    env:cleanup()
    assert.is_true(panel.Destroyed)
    assert.is_true(button.Destroyed)
    assert.same(0, button.OnClicked:Count())
    env = nil
  end)
end)
