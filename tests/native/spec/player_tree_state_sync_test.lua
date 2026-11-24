-- #297-A1b 契约测试：player_tree 第一/二因果段、单批 ItemBarState 合并推送、持竿叶子与离场终镜像。
-- 失败方式先列：
--   1. 单次 spoke_runtime.batch 内多次修改库存/金币/药水/升级，触发多次 ItemBarState 推送或未同步 FishCoin/存档镜像；
--   2. 首领饵存在道具栏时未按 player_data 口径合并进 ItemBarState.bait，或背包/道具栏扩容容量未随 upgrade_level 同步；
--   3. 药水/商店升级/持续效果变更时 Stage 2 属性派生未即时重算，或亚秒级 paralyze 错误退出外层 alive 相位；
--   4. 持竿模型未随切槽/切换 held/角色重建/离场 dispose 自动逆序清理；
--   5. 离线/离场 Step 1 终镜像未完整写回 weakRemaining（含角色空窗暂停态）及第一因果段最新库存状态。

local game_cfg = require("common.game_cfg")
local body_scale = require("common.body_scale")
local spoke_clock = require("common.spoke_clock")
local spoke_runtime = require("common.packages.spoke.runtime.spoke_runtime")
local player_tree = require("server.world_host.player_tree")

local CONTAINER = game_cfg.Items.ContainerId

local function make_character(walk_speed)
  return {
    Name = "EggyCharacter",
    Controller = { WalkSpeed = walk_speed or 7 },
  }
end

local function make_player(user_id, character)
  local attrs = {}
  local set_coin_calls = 0
  local player = {
    UserId = user_id,
    Character = character,
    attrs = attrs,
    get_set_coin_calls = function()
      return set_coin_calls
    end,
    SetAttribute = function(self, key, value)
      attrs[key] = value
      if key == "FishCoin" then
        set_coin_calls = set_coin_calls + 1
      end
    end,
  }
  return player
end

local function make_ready_data(player, overrides)
  overrides = overrides or {}
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    data = {
      FishCoin = overrides.coin or 100,
      Zone = overrides.zone or "fishPond",
      UpgradeLevel = overrides.upgrade_level or 0,
      Containers = {
        [CONTAINER.ItemBar] = overrides.item_bar or {
          [1] = { itemId = game_cfg.Items.Id.StarterRod, count = 1, containerId = CONTAINER.ItemBar },
        },
        [CONTAINER.Backpack] = overrides.backpack or {},
      },
      Bait = overrides.bait or { item31 = 5 },
      Weapons = overrides.weapons or {},
      SelectedSlot = overrides.selected_slot,
      SelectedBait = overrides.selected_bait,
      SelectedWeapon = overrides.selected_weapon,
    },
    Extra = {
      inventory = {
        weapons = overrides.weapons or {},
        selection = {
          slot = overrides.selected_slot,
          bait = overrides.selected_bait,
          weapon = overrides.selected_weapon,
          held = overrides.held or { kind = nil, id = nil, slot = nil },
        },
      },
      growth = {
        potions = {
          item168 = overrides.body_potions or 0,
          item167 = overrides.speed_potions or 0,
        },
        upgrades = overrides.shop_upgrades or {},
      },
      survival = {
        health = overrides.health or game_cfg.vitals.MaxHealth,
        hunger = overrides.hunger or game_cfg.vitals.MaxHunger,
        dying = false,
        dead = false,
        weakRemaining = overrides.weak_remaining or 0,
      },
      cooldowns = overrides.cooldowns or {},
    },
  }
end

describe("player_tree #297-A1b：单批合并推送、属性即时重算与存档镜像", function()
  local saved_vec3, saved_color

  before_each(function()
    saved_vec3 = rawget(_G, "Vector3")
    saved_color = rawget(_G, "Color")
    _G.Vector3 = { New = function(x, y, z) return { x = x, y = y, z = z } end }
    _G.Color = { New = function(...) return { ... } end }
  end)

  after_each(function()
    _G.Vector3 = saved_vec3
    _G.Color = saved_color
    saved_vec3, saved_color = nil, nil
  end)

  it("单次 spoke_runtime.batch 内多次库存/金币/药水/升级变更只合并推送 1 次 ItemBarState 并同步属性与镜像", function()
    local clock = spoke_clock.new(100)
    local char = make_character(8)
    local player = make_player(9101, char)
    local data = make_ready_data(player, {
      coin = 200,
      selected_slot = 1,
      item_bar = {
        [1] = { itemId = game_cfg.Items.Id.StarterRod, count = 1, containerId = CONTAINER.ItemBar },
        [2] = { itemId = "item168", count = 1, containerId = CONTAINER.ItemBar },
      },
    })

    local pushes = {}
    local pt = player_tree.spawn({
      player = player,
      data = data,
      clock = clock,
      on_item_bar_state = function(target_player, snapshot)
        pushes[#pushes + 1] = { player = target_player, snapshot = snapshot }
      end,
    })

    -- 初始化即同步 FishCoin 属性，且未产生多余推送
    assert.equals(200, player.attrs.FishCoin)
    assert.equals(1, player.get_set_coin_calls())
    assert.equals(0, #pushes)
    assert.equals(2, pt.memos.item_bar_capacity:now())
    assert.equals(5, pt.memos.backpack_capacity:now())

    -- 选取一个首领饵 ID，验证 ItemBarState.bait 合并口径与 player_data 一致
    local boss_bait_id = next(game_cfg.Casting.BossBait)
    assert.is_string(boss_bait_id)

    local before_version = pt.states.save_version:now()
    spoke_runtime.batch(function()
      assert.is_true(pt:set_coin(550))
      assert.is_true(pt:set_upgrade_level(2))
      assert.is_true(pt:set_item_bar({
        [1] = { itemId = game_cfg.Items.Id.StarterRod, count = 1, containerId = CONTAINER.ItemBar },
        [2] = { itemId = boss_bait_id, count = 1, containerId = CONTAINER.ItemBar },
      }))
      assert.is_true(pt:set_backpack({
        [1] = { itemId = "item167", count = 1, containerId = CONTAINER.Backpack },
      }))
      assert.is_true(pt:set_weapons({ item64 = 1 }))
      assert.is_true(pt:set_bait({ item31 = 9 }))
      assert.is_true(pt:set_selected_slot(2))
      assert.is_true(pt:set_selected_bait(boss_bait_id))
      assert.is_true(pt:set_selected_weapon("item64"))
      assert.is_true(pt:set_held({ kind = "slot", id = boss_bait_id, slot = 2 }))
      assert.is_true(pt:set_potion_count("item168", 3))
      assert.is_true(pt:set_potion_count("item167", 4))
      assert.is_true(pt:set_shop_upgrade("melee", 2))
      assert.is_true(pt:set_cooldown("breath", 125))
    end)

    -- 同一 batch 内 14 次写入，树底 Reaction 严格只合并下发 1 次 ItemBarState、同步 1 次 FishCoin
    assert.equals(1, #pushes)
    assert.equals(player, pushes[1].player)
    assert.equals(550, player.attrs.FishCoin)
    assert.equals(2, player.get_set_coin_calls())
    assert.equals(before_version + 1, pt.states.save_version:now())

    local snap = pushes[1].snapshot
    assert.equals(550, snap.coin)
    assert.equals(2, snap.upgradeLevel)
    assert.equals(4, snap.slotCount)
    assert.equals(15, snap.backpackCount)
    assert.equals(2, snap.selectedSlot)
    assert.equals(boss_bait_id, snap.selectedBait)
    assert.equals("item64", snap.selectedWeapon)
    assert.equals(1, snap.weapons.item64)
    assert.equals(9, snap.bait.item31)
    assert.equals(1, snap.bait[boss_bait_id])
    assert.same({ kind = "slot", id = boss_bait_id, slot = 2 }, snap.held)
    assert.equals("item167", snap.backpack[1].itemId)

    -- Stage 2 属性派生即时重算
    assert.equals(480, pt.memos.max_health:now())
    assert.near(1.6, pt.memos.body_scale:now(), 1e-9)
    assert.near(body_scale.Derive(1.6).CameraDistance, pt.memos.body_derived:now().CameraDistance, 1e-9)
    assert.near(8 * 1.4, pt.memos.walk_speed:now(), 1e-9)
    assert.near(game_cfg.Shop.DamageScale("melee", 2), pt.memos.weapon_damage_scales:now().melee, 1e-9)

    -- 存档镜像已同步写回 data.data / data.Extra
    assert.equals(550, data.data.FishCoin)
    assert.equals(2, data.data.UpgradeLevel)
    assert.equals(3, data.Extra.growth.potions.item168)
    assert.equals(4, data.Extra.growth.potions.item167)
    assert.equals(2, data.Extra.growth.upgrades.melee)
    assert.equals(125, data.Extra.cooldowns.breath)
    assert.equals(boss_bait_id, data.data.Containers[CONTAINER.ItemBar][2].itemId)

    pt:dispose()
  end)

  it("亚秒级麻痹由 player_effects 驱动，仅关 can_act 与移速归零、不退出外层 alive 相位", function()
    local clock = spoke_clock.new(200)
    local player = make_player(9102, make_character(7))
    local data = make_ready_data(player)

    local pt = player_tree.spawn({
      player = player,
      data = data,
      clock = clock,
    })

    local alive_mounts, alive_cleanups = 0, 0
    pt:mount_phase("alive", "AliveSessionProbe", function(s)
      alive_mounts = alive_mounts + 1
      s:on_cleanup(function()
        alive_cleanups = alive_cleanups + 1
      end)
    end)

    assert.is_true(pt.memos.is_alive:now())
    assert.is_true(pt.memos.can_act:now())
    assert.near(7, pt.memos.walk_speed:now(), 1e-9)

    assert.is_true(pt:apply_modifier("paralyze"))
    assert.is_true(pt.memos.is_alive:now())
    assert.is_false(pt.memos.can_act:now())
    assert.equals(0, pt.memos.walk_speed:now())
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    clock:advance(0.25)
    assert.is_false(pt.memos.can_act:now())
    clock:advance(0.25)
    assert.is_true(pt.memos.can_act:now())
    assert.near(7, pt.memos.walk_speed:now(), 1e-9)
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    pt:dispose()
  end)

  it("持竿纯输出叶子随切槽、角色重建与离场 dispose 自动逆序清理，兼容代理 userdata 角色", function()
    local clock = spoke_clock.new(300)
    local char1 = setmetatable({}, { __index = { Name = "ProxyChar1" } })
    local char2 = setmetatable({}, { __index = { Name = "ProxyChar2" } })
    local player = make_player(9103, char1)
    local data = make_ready_data(player, {
      selected_slot = 1,
      item_bar = {
        [1] = { itemId = game_cfg.Items.Id.StarterRod, count = 1, containerId = CONTAINER.ItemBar },
        [2] = { itemId = "item168", count = 1, containerId = CONTAINER.ItemBar },
      },
    })

    local created, destroyed = {}, {}
    local function create_unit(unit_type, props)
      local unit = {
        Type = unit_type,
        Props = props,
        Destroy = function(self)
          destroyed[#destroyed + 1] = self.Props.Name
        end,
      }
      created[#created + 1] = unit
      return unit
    end

    local pt = player_tree.spawn({
      player = player,
      data = data,
      clock = clock,
      create_unit = create_unit,
    })

    -- 初始选中鱼竿槽：创建挂点 + 模型
    assert.equals(2, #created)
    assert.equals("HeldRodMount_9103", created[1].Props.Name)
    assert.equals(char1, created[1].Props.Parent)
    assert.equals("HeldRod_9103", created[2].Props.Name)
    assert.same({}, destroyed)

    -- 切到非鱼竿槽：自动逆序销毁模型与挂点
    assert.is_true(pt:set_selected_slot(2))
    assert.same({ "HeldRod_9103", "HeldRodMount_9103" }, destroyed)
    assert.equals(2, #created)

    -- 切回鱼竿槽并角色重建：重新挂载到新角色并销毁旧实例
    assert.is_true(pt:set_selected_slot(1))
    assert.equals(4, #created)
    assert.is_true(pt:set_character(char2))
    assert.equals(6, #created)
    assert.equals(char2, created[5].Props.Parent)
    assert.equals(4, #destroyed)

    -- 离场 dispose：彻底清理持竿模型与挂点零残留
    pt:begin_leave()
    pt:dispose()
    assert.equals(6, #destroyed)
    assert.equals("HeldRod_9103", destroyed[5])
    assert.equals("HeldRodMount_9103", destroyed[6])
  end)

  it("离线/离场终镜像完整写回 weakRemaining（含角色空窗暂停剩余秒数）与最新库存状态", function()
    local clock = spoke_clock.new(400)
    local player = make_player(9104, make_character(7))
    local data = make_ready_data(player, {
      coin = 30,
      weak_remaining = 50,
    })

    local push_count = 0
    local observed_in_finalize = nil
    local pt = player_tree.spawn({
      player = player,
      data = data,
      clock = clock,
      on_item_bar_state = function()
        push_count = push_count + 1
      end,
      on_leave_finalize = function(_, _, finalized_data)
        observed_in_finalize = {
          coin = finalized_data.data.FishCoin,
          weak = finalized_data.Extra.survival.weakRemaining,
          big = finalized_data.Extra.growth.potions.item168,
        }
      end,
    })

    -- 推进 12 秒 → weak 剩余 38 秒；随后角色移除空窗 10 秒，weak 冻结保持 38 秒
    clock:advance(12)
    assert.near(38, pt:get_modifier_remaining("weak"), 1e-9)
    pt:set_character(nil)
    clock:advance(10)
    assert.near(38, pt:get_modifier_remaining("weak"), 1e-9)

    -- 离场前改一笔金币与药水
    pt:batch(function()
      pt:set_coin(777)
      pt:set_potion_count("item168", 5)
    end)
    assert.equals(1, push_count)

    -- Step 1 离场终镜像：自动把 weakRemaining=38 与最新库存写入 data，且早于 on_leave_finalize 回调可读
    pt:begin_leave()
    assert.is_not_nil(observed_in_finalize)
    assert.equals(777, observed_in_finalize.coin)
    assert.near(38, observed_in_finalize.weak, 1e-9)
    assert.equals(5, observed_in_finalize.big)
    assert.near(38, data.Extra.survival.weakRemaining, 1e-9)
    assert.equals(777, data.data.FishCoin)

    -- Step 2 同步 dispose 后零残留
    pt:dispose()
    assert.is_true(pt:is_disposed())
  end)

  it("FishCoin 属性写入失败时记录含玩家标识的日志且不推进缓存，后续恢复后可重试成功", function()
    local clock = spoke_clock.new(500)
    local fail_once = true
    local logs = {}
    local attrs = {}
    local player = {
      UserId = 9105,
      Character = make_character(7),
      SetAttribute = function(_, key, value)
        if key == "FishCoin" and fail_once then
          error("mock-attr-write-fail")
        end
        attrs[key] = value
      end,
    }
    local data = make_ready_data(player, { coin = 50 })
    local pt = player_tree.spawn({
      player = player,
      data = data,
      clock = clock,
      logger = {
        error = function(_, msg)
          logs[#logs + 1] = msg
        end,
      },
    })

    assert.is_nil(attrs.FishCoin)
    assert.equals(1, #logs)
    assert.matches("sync_fish_coin_attribute", logs[1], nil, true)
    assert.matches("9105", logs[1], nil, true)
    assert.matches("mock-attr-write-fail", logs[1], nil, true)

    -- 恢复后触发同值状态刷新（如切区），因失败未写入 last_synced_coin，应重试写入成功
    fail_once = false
    assert.is_true(pt:set_zone("shrimpPond"))
    assert.equals(50, attrs.FishCoin)
    assert.equals(1, #logs)

    pt:dispose()
  end)
end)
