-- 服务端单玩家会话 Auto SpokeTree（ADR-0032 §1、§2、§3 / #295、#297-A1b）：
-- 仅在玩家存档加载就绪时生成；树内严格按源码声明顺序排布四段因果流：
--   1. 存档与库存（SaveInventory：金币/道具栏/背包/武器/鱼饵/选中槽/held/药水/升级/冷却 + ItemBarSnapshot）
--   2. 属性与持续效果派生（Attributes：挂载 PlayerEffects，接管属性派生与持续效果计时主权）
--   3. 生命与生存相位（Survival：外层生命 Phase + 倒计时 platform_pending 门控 + 内层 can_act）
--   4. 动作、特殊道具与设施会话相位（Actions）
-- 树底挂载纯输出叶子（HeldRodLeaf）、单批合并同步 Reaction（ItemBarState 下发 / FishCoin 属性 / 存档镜像）
-- 与离场终镜像 Reaction（session_alive=false 时同步写回完整镜像，包括 weakRemaining）。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块。

local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local PlayerEffects = require("server.world_host.player_effects")
local PlayerLife = require("server.world_host.player_life")
local SpecialItemPhase = require("server.world_host.special_item_phase")
local FishingPhase = require("server.world_host.fishing_phase")
local HeldRodLeaf = require("server.world_host.held_rod_leaf")
local PlayerCompendium = require("server.world_host.player_compendium")
local PlayerQuest = require("server.world_host.player_quest")
local PlayerStory = require("server.world_host.player_story")
local PlayerAchievements = require("server.world_host.player_achievements")
local PlayerGM = require("server.world_host.player_gm")

local SpokeTree = Spoke.SpokeTree
local Effect = Spoke.Effect
local State = Spoke.State

local PlayerTree = {}

local PHASE_NAMES = {
  alive = true,
  downed = true,
  downed_countdown = true,
  dead = true,
  dead_countdown = true,
}

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function is_non_negative_int(value)
  return Number.IsFiniteNumber(value) and value >= 0 and value == math.floor(value)
end

local function assert_clock(clock)
  if type(clock) ~= "table"
      or type(clock.now) ~= "function"
      or type(clock.second) ~= "table"
      or type(clock.on_second) ~= "table"
      or type(clock.on_frame) ~= "table" then
    error("PlayerTree.spawn 需要有效的 SpokeClock 实例", 3)
  end
end

local function is_valid_player(player)
  local kind = type(player)
  return (kind == "table" or kind == "userdata") and player.UserId ~= nil
end

local function assert_ready_player_data(player, data)
  if not is_valid_player(player) then
    error("PlayerTree.spawn 需要有效的 player 对象（含 UserId）", 3)
  end
  if type(data) ~= "table" then
    error("PlayerTree.spawn 拒绝未就绪存档：缺少 data", 3)
  end
  if data.Player ~= player then
    error("PlayerTree.spawn 拒绝归属不匹配的存档对象", 3)
  end
  if data.Inited ~= true or data.LoadState ~= "ready" then
    error("PlayerTree.spawn 仅允许在存档就绪后生成（LoadState=" .. tostring(data.LoadState) .. "）", 3)
  end
end

local function normalize_held(raw)
  if type(raw) ~= "table" then
    return { kind = nil, id = nil, slot = nil }
  end
  return {
    kind = raw.kind,
    id = raw.id,
    slot = raw.slot,
  }
end

local function compute_item_bar_capacity(upgrade_level)
  local level = is_non_negative_int(upgrade_level) and upgrade_level or 0
  return GameCfg.Items.InitialItemBarSlots + level
end

local function compute_backpack_capacity(upgrade_level)
  local level = is_non_negative_int(upgrade_level) and upgrade_level or 0
  if level >= #GameCfg.Items.UpgradePrices then
    return GameCfg.Items.MaxBackpackSlots
  end
  return GameCfg.Items.InitialBackpackSlots + level * GameCfg.Items.BackpackSlotsPerUpgrade
end

local function copy_slots(items, capacity)
  local slots = {}
  if type(items) ~= "table" then
    return slots
  end
  for index = 1, capacity do
    local entry = items[index]
    if type(entry) == "table" and (entry.count or 0) > 0 then
      slots[index] = {
        itemId = entry.itemId,
        count = entry.count,
        containerId = entry.containerId,
        mult = entry.mult,
        cooked = entry.cooked,
      }
    end
  end
  return slots
end

local function build_item_bar_snapshot(
    item_bar,
    slot_count,
    backpack,
    backpack_count,
    upgrade_level,
    bait,
    coin,
    selected_slot,
    selected_bait,
    weapons,
    selected_weapon,
    held)
  local bait_out = {}
  for item_id, count in pairs(type(bait) == "table" and bait or {}) do
    bait_out[item_id] = count
  end

  local boss_bait = GameCfg.Casting and GameCfg.Casting.BossBait
  if type(boss_bait) == "table" then
    local bosses = {}
    for item_id in pairs(boss_bait) do
      bosses[#bosses + 1] = item_id
    end
    table.sort(bosses)
    for _, item_id in ipairs(bosses) do
      local total = 0
      for _, entry in pairs(type(item_bar) == "table" and item_bar or {}) do
        if type(entry) == "table" and entry.itemId == item_id and (entry.count or 0) > 0 then
          total = total + entry.count
        end
      end
      if total >= 1 then
        bait_out[item_id] = total
      end
    end
  end

  return {
    slots = copy_slots(item_bar, slot_count),
    slotCount = slot_count,
    backpack = copy_slots(backpack, backpack_count),
    backpackCount = backpack_count,
    upgradeLevel = upgrade_level,
    bait = bait_out,
    coin = coin,
    selectedSlot = selected_slot,
    selectedBait = selected_bait,
    weapons = deep_copy(type(weapons) == "table" and weapons or {}),
    selectedWeapon = selected_weapon,
    held = normalize_held(held),
  }
end

local function initial_life_phase(survival)
  if type(survival) == "table" then
    if survival.dead then return "dead" end
    if survival.dying then return "downed" end
  end
  return "alive"
end

local function make_phase_slots()
  local slots = {}
  for name in pairs(PHASE_NAMES) do
    slots[name] = { order = {}, blocks = {}, active_dock = nil }
  end
  return slots
end

local function mount_phase_dock(ps, slot, label)
  local dock = ps:dock("PhaseDock:" .. label)
  slot.active_dock = dock
  for _, key in ipairs(slot.order) do
    local block = slot.blocks[key]
    if block then
      dock:effect(key, block)
    end
  end
  ps:on_cleanup(function()
    if slot.active_dock == dock then
      slot.active_dock = nil
    end
  end)
end

---@param opts { player: table, data: table, clock: table, world?: table, logger?: table, effects?: table, create_unit?: fun(unit_type: string, props: table): any, on_item_bar_state?: fun(player: any, snapshot: table, tree: table), on_leave_finalize?: fun(tree: table, player: table, data: table), mounts?: table }
function PlayerTree.spawn(opts)
  if type(opts) ~= "table" then
    error("PlayerTree.spawn 需要参数表", 2)
  end
  assert_clock(opts.clock)
  assert_ready_player_data(opts.player, opts.data)

  local player = opts.player
  local data = opts.data
  local clock = opts.clock
  local mounts = type(opts.mounts) == "table" and opts.mounts or {}
  local container_ids = GameCfg.Items.ContainerId

  local raw_data = type(data.Data) == "table" and data.Data or {}
  local raw_containers = type(raw_data.Containers) == "table" and raw_data.Containers or {}
  local raw_extra = type(data.Extra) == "table" and data.Extra or {}
  local raw_inventory = type(raw_extra.inventory) == "table" and raw_extra.inventory or {}
  local raw_selection = type(raw_inventory.selection) == "table" and raw_inventory.selection or {}
  local raw_growth = type(raw_extra.growth) == "table" and raw_extra.growth or {}
  local raw_potions = type(raw_growth.potions) == "table" and raw_growth.potions or {}
  local raw_upgrades = type(raw_growth.upgrades) == "table" and raw_growth.upgrades or {}
  local raw_survival = type(raw_extra.survival) == "table" and raw_extra.survival or {}
  local raw_cooldowns = type(raw_extra.cooldowns) == "table" and raw_extra.cooldowns or {}

  local ok_char, initial_character = pcall(function() return player.Character end) -- 兼容引擎 userdata 玩家

  local session_alive = State.new("PlayerTree.session_alive", true)
  local states = {
    -- Stage 1: 存档与库存基础状态
    coin = State.new("PlayerTree.coin", raw_data.FishCoin or 0),
    zone_id = State.new("PlayerTree.zone_id", raw_data.Zone or (GameCfg.Zones[1] and GameCfg.Zones[1].Id) or "fishPond"),
    item_bar = State.new("PlayerTree.item_bar", deep_copy(raw_containers[container_ids.ItemBar] or {})),
    backpack = State.new("PlayerTree.backpack", deep_copy(raw_containers[container_ids.Backpack] or {})),
    weapons = State.new("PlayerTree.weapons", deep_copy(raw_data.Weapons or raw_inventory.weapons or {})),
    bait = State.new("PlayerTree.bait", deep_copy(raw_data.Bait or {})),
    selected_slot = State.new("PlayerTree.selected_slot",
      raw_data.SelectedSlot ~= nil and raw_data.SelectedSlot or raw_selection.slot),
    selected_bait = State.new("PlayerTree.selected_bait",
      raw_data.SelectedBait ~= nil and raw_data.SelectedBait or raw_selection.bait),
    selected_weapon = State.new("PlayerTree.selected_weapon",
      raw_data.SelectedWeapon ~= nil and raw_data.SelectedWeapon or raw_selection.weapon),
    held = State.new("PlayerTree.held", normalize_held(raw_selection.held)),
    potion_big_count = State.new("PlayerTree.potion_big_count", raw_potions.item168 or 0),
    potion_speed_count = State.new("PlayerTree.potion_speed_count", raw_potions.item167 or 0),
    upgrade_level = State.new("PlayerTree.upgrade_level", raw_data.UpgradeLevel or 0),
    shop_upgrades = State.new("PlayerTree.shop_upgrades", deep_copy(raw_upgrades)),
    cooldowns = State.new("PlayerTree.cooldowns", deep_copy(raw_cooldowns)),
    save_version = State.new("PlayerTree.save_version", 0),
    character = State.new("PlayerTree.character", ok_char and initial_character or nil),
    held_rod_retry = State.new("PlayerTree.held_rod_retry", 0),
    -- Stage 2: 持续效果与属性修饰输入
    base_speed = State.new("PlayerTree.base_speed", nil),
    is_weak = State.new("PlayerTree.is_weak", (raw_survival.weakRemaining or 0) > 0),
    is_frost = State.new("PlayerTree.is_frost", false),
    is_paralyzed = State.new("PlayerTree.is_paralyzed", false),
    -- Stage 3: 生命与生存状态
    health = State.new("PlayerTree.health", raw_survival.health or GameCfg.Vitals.MaxHealth),
    hunger = State.new("PlayerTree.hunger", raw_survival.hunger or GameCfg.Vitals.MaxHunger),
    life_phase = State.new("PlayerTree.life_phase", initial_life_phase(raw_survival)),
    platform_pending = State.new("PlayerTree.platform_pending", false),
  }

  local memos = {}
  local docks = {}
  local phase_slots = make_phase_slots()
  local finalizers = {}
  local finalized = false
  local last_synced_coin = nil
  local last_pushed_snapshot = nil
  local stage1_dirty = false
  local syncing_from_data = false
  local weak_touched = (raw_survival.weakRemaining or 0) > 0
  local survival_dirty = false

  local handle = {
    user_id = player.UserId,
    player = player,
    data = data,
    clock = clock,
    world = opts.world,
    session_alive = session_alive,
    states = states,
    memos = memos,
    docks = docks,
    tree = nil,
  }

  local function log_error(tag, err)
    if opts.logger and type(opts.logger.error) == "function" then
      pcall(opts.logger.error, opts.logger, tag .. " (uid=" .. tostring(player.UserId) .. "): " .. tostring(err)) -- logger 异常不得中断业务清理与终镜像
    else
      print(tag, player.UserId, tostring(err))
    end
  end

  local function sync_fish_coin_attribute(coin)
    if coin == last_synced_coin then
      return
    end
    local ok_has, set_attr = pcall(function() return player.SetAttribute end) -- 兼容引擎 userdata 读取 SetAttribute 成员
    if not ok_has or type(set_attr) ~= "function" then
      return
    end
    local ok_set, err = pcall(set_attr, player, "FishCoin", coin)
    if not ok_set then
      log_error("[PlayerTree] sync_fish_coin_attribute 失败", err)
      return
    end
    last_synced_coin = coin
  end

  local function mirror_stage1_to_data()
    if type(data) ~= "table" then
      return
    end
    if type(data.Data) ~= "table" then
      data.Data = {}
    end
    local d = data.Data
    d.FishCoin = states.coin:now()
    d.Zone = states.zone_id:now()
    d.UpgradeLevel = states.upgrade_level:now()
    if type(d.Containers) ~= "table" then
      d.Containers = {}
    end
    d.Containers[container_ids.ItemBar] = deep_copy(states.item_bar:now() or {})
    d.Containers[container_ids.Backpack] = deep_copy(states.backpack:now() or {})
    d.Bait = deep_copy(states.bait:now() or {})
    d.Weapons = deep_copy(states.weapons:now() or {})
    d.SelectedSlot = states.selected_slot:now()
    d.SelectedBait = states.selected_bait:now()
    d.SelectedWeapon = states.selected_weapon:now()

    if type(data.Extra) ~= "table" then
      data.Extra = {}
    end
    local extra = data.Extra
    if type(extra.inventory) ~= "table" then
      extra.inventory = {}
    end
    extra.inventory.weapons = deep_copy(states.weapons:now() or {})
    if type(extra.inventory.selection) ~= "table" then
      extra.inventory.selection = {}
    end
    extra.inventory.selection.slot = states.selected_slot:now()
    extra.inventory.selection.bait = states.selected_bait:now()
    extra.inventory.selection.weapon = states.selected_weapon:now()
    extra.inventory.selection.held = normalize_held(states.held:now())

    if type(extra.growth) ~= "table" then
      extra.growth = {}
    end
    if type(extra.growth.potions) ~= "table" then
      extra.growth.potions = {}
    end
    extra.growth.potions.item168 = states.potion_big_count:now()
    extra.growth.potions.item167 = states.potion_speed_count:now()
    extra.growth.upgrades = deep_copy(states.shop_upgrades:now() or {})

    extra.cooldowns = deep_copy(states.cooldowns:now() or {})
  end

  local function mirror_to_data(force_all)
    if type(data) ~= "table" then
      return
    end
    if force_all or stage1_dirty then
      mirror_stage1_to_data()
    end

    if type(data.Extra) ~= "table" then
      data.Extra = {}
    end
    local extra = data.Extra
    if type(extra.survival) ~= "table" then
      extra.survival = {}
    end
    if force_all or survival_dirty then
      extra.survival.health = states.health:now()
      extra.survival.hunger = states.hunger:now()
      local phase = states.life_phase:now()
      extra.survival.dying = phase == "downed" or phase == "rescuing"
      extra.survival.dead = phase == "dead"
    end
    if type(handle.get_modifier_remaining) == "function" then
      local weak_rem = handle:get_modifier_remaining("weak")
      if force_all or weak_touched or weak_rem > 0 then
        extra.survival.weakRemaining = weak_rem
      end
    end
  end

  local function emit_item_bar_state(snapshot)
    if type(opts.on_item_bar_state) ~= "function" then
      return
    end
    local ok, err = pcall(opts.on_item_bar_state, player, deep_copy(snapshot), handle) -- 隔离外围推送回调异常，防止打断树状态同步
    if not ok then
      log_error("[PlayerTree] on_item_bar_state 回调失败", err)
    end
  end

  local function run_finalizers()
    if finalized then return end
    finalized = true
    for _, entry in ipairs(finalizers) do
      if entry.active then
        local ok, err = pcall(entry.fn, handle, player, data) -- 隔离单个离场回调异常，保证其余终镜像与收尾继续执行
        if not ok then
          log_error("[PlayerTree] 离场终镜像回调失败", err)
        end
      end
    end
    mirror_to_data()
    if type(opts.on_leave_finalize) == "function" then
      local ok, err = pcall(opts.on_leave_finalize, handle, player, data) -- 隔离宿主离场回调异常，避免阻断后续 dispose 协议
      if not ok then
        log_error("[PlayerTree] on_leave_finalize 失败", err)
      end
    end
  end

  local services = opts.logger and { logger = opts.logger } or nil
  local root = Effect.new("PlayerRoot:" .. tostring(player.UserId), function(s)
    s:export("clock", clock)
    s:export("player", player)
    s:export("data", data)
    s:export("session_alive", session_alive)
    s:export("player_tree", handle)
    if opts.world ~= nil then
      s:export("world", opts.world)
    end

    -- 托管玩家角色生命周期信号（CharacterAdded / CharacterRemoving），树销毁时对称断开，零泄漏。
    local ok_added_sig, added_sig = pcall(function() return player.CharacterAdded end) -- 兼容引擎 userdata 或精简替身对象
    if ok_added_sig and added_sig ~= nil and added_sig.Connect ~= nil then
      local ok_conn, conn_added = pcall(added_sig.Connect, added_sig, function(character)
        if not handle:is_disposed() then
          states.character:set(character)
        end
      end) -- 兼容只读/异常信号对象
      if ok_conn and conn_added ~= nil then
        s:on_cleanup(function()
          pcall(conn_added.Disconnect, conn_added) -- 玩家或信号可能已随引擎卸载
        end)
      end
    end

    local ok_rem_sig, rem_sig = pcall(function() return player.CharacterRemoving end) -- 兼容引擎 userdata 或精简替身对象
    if ok_rem_sig and rem_sig ~= nil and rem_sig.Connect ~= nil then
      local ok_conn, conn_rem = pcall(rem_sig.Connect, rem_sig, function(character)
        if not handle:is_disposed() then
          if character == nil or states.character:now() == character then
            states.character:set(nil)
          end
        end
      end) -- 兼容只读/异常信号对象
      if ok_conn and conn_rem ~= nil then
        s:on_cleanup(function()
          pcall(conn_rem.Disconnect, conn_rem) -- 玩家或信号可能已随引擎卸载
        end)
      end
    end

    -- 1. 存档与库存（SaveInventory）
    s:effect("Stage1:SaveInventory", function(s1)
      memos.item_bar_capacity = s1:memo("ItemBarCapacity", function(ms)
        return compute_item_bar_capacity(ms:d(states.upgrade_level))
      end)

      memos.backpack_capacity = s1:memo("BackpackCapacity", function(ms)
        return compute_backpack_capacity(ms:d(states.upgrade_level))
      end)

      memos.held_visual_item_id = s1:memo("HeldVisualItemId", function(ms)
        return HeldRodLeaf.resolve_visual_item_id(
          ms:d(states.held),
          ms:d(states.selected_slot),
          ms:d(states.item_bar)
        )
      end)

      memos.item_bar_snapshot = s1:memo("ItemBarSnapshot", function(ms)
        return build_item_bar_snapshot(
          ms:d(states.item_bar),
          ms:d(memos.item_bar_capacity),
          ms:d(states.backpack),
          ms:d(memos.backpack_capacity),
          ms:d(states.upgrade_level),
          ms:d(states.bait),
          ms:d(states.coin),
          ms:d(states.selected_slot),
          ms:d(states.selected_bait),
          ms:d(states.weapons),
          ms:d(states.selected_weapon),
          ms:d(states.held)
        )
      end)

      docks.save_inventory = s1:dock("SaveInventoryDock")
      if opts.save and opts.player_data and _G.REUtil then
        local session_opts = {
          player = player, clock = clock, save = opts.save, player_data = opts.player_data,
          records = opts.records,
        }
        PlayerQuest.mount(s1, handle, session_opts)
        PlayerCompendium.mount(s1, handle, session_opts)
        PlayerStory.mount(s1, handle, session_opts)
        PlayerAchievements.mount(s1, handle, session_opts)
        PlayerGM.mount(s1, handle, session_opts)
      end
      if type(mounts.save_inventory) == "function" then
        mounts.save_inventory(s1, handle)
      end
    end)

    -- 2. 属性与持续效果派生（Attributes）
    s:effect("Stage2:Attributes", function(s2)
      docks.modifiers = s2:dock("ModifierDock")

      local builtin_effects_dock = s2:dock("BuiltinEffectsDock")
      builtin_effects_dock:effect("default", function(es)
        PlayerEffects.mount(es, handle, opts.effects)
      end)
      local builtin_apply_modifier = handle.apply_modifier

      docks.attributes = s2:dock("AttributesDock")
      if type(mounts.attributes) == "function" then
        mounts.attributes(s2, handle)
        -- 若调用方在 mounts.attributes 中显式挂载了自定义 PlayerEffects 实例，拆除内置实例并恢复活跃标志位，避免双份监听。
        if handle.apply_modifier ~= builtin_apply_modifier then
          builtin_effects_dock:drop("default")
          SpokeRuntime.batch(function()
            states.is_weak:set(handle:get_modifier_remaining("weak") > 0)
            states.is_frost:set(handle:get_modifier_remaining("frost") > 0)
            states.is_paralyzed:set(handle:get_modifier_remaining("paralyze") > 0)
          end)
        end
      end
    end)

    -- 3. 生命与生存相位（Survival）
    s:effect("Stage3:Survival", function(s3)
      memos.is_alive = s3:memo("IsAlive", function(ms)
        return ms:d(states.life_phase) == "alive"
      end)
      memos.is_downed = s3:memo("IsDowned", function(ms)
        local phase = ms:d(states.life_phase)
        return phase == "downed" or phase == "rescuing"
      end)
      memos.is_dead = s3:memo("IsDead", function(ms)
        return ms:d(states.life_phase) == "dead"
      end)
      memos.can_act = s3:memo("CanAct", function(ms)
        return ms:d(memos.is_alive) and not ms:d(states.is_paralyzed)
      end)
      memos.countdown_active = s3:memo("CountdownActive", function(ms)
        return not ms:d(states.platform_pending)
      end)

      -- 外层存活相位：仅跟随 is_alive，麻痹不退出此相位。
      s3:phase("AlivePhase", memos.is_alive, function(ps)
        mount_phase_dock(ps, phase_slots.alive, "alive")
        SpecialItemPhase.mount(ps, handle, {
          remote = opts.remote,
          create_unit = opts.create_unit,
          players = opts.players,
          fish_units = opts.fish_units,
          fish_carrier = opts.fish_carrier,
        })
        handle.fishing = FishingPhase.mount(ps, handle, {
          remote = opts.remote,
          world = opts.world_service,
          create_unit = opts.create_unit,
          fish_unit = opts.fish_unit,
          compendium = opts.compendium or handle.compendium,
          quest = opts.quest or handle.quest,
          random = opts.random,
        })
      end)

      -- 濒死相位：内嵌 platform_pending 门控的倒计时子相位。
      s3:phase("DownedPhase", memos.is_downed, function(ps)
        mount_phase_dock(ps, phase_slots.downed, "downed")
        ps:phase("DownedCountdown", memos.countdown_active, function(cs)
          mount_phase_dock(cs, phase_slots.downed_countdown, "downed_countdown")
        end)
      end)

      -- 死亡相位：内嵌 platform_pending 门控的倒计时子相位。
      s3:phase("DeadPhase", memos.is_dead, function(ps)
        mount_phase_dock(ps, phase_slots.dead, "dead")
        ps:phase("DeadCountdown", memos.countdown_active, function(cs)
          mount_phase_dock(cs, phase_slots.dead_countdown, "dead_countdown")
        end)
      end)

      PlayerLife.mount(s3, handle, {
        remote = opts.remote,
        save = opts.save,
        player_data = opts.player_data,
        platform = opts.platform,
        fish_carrier = opts.fish_carrier,
        damage_filter = opts.damage_filter,
        damage_context = opts.damage_context,
        lookup_tree = opts.lookup_tree,
        players = opts.players,
        speed_writer = opts.speed_writer,
        growth_writer = opts.growth_writer,
        max_health_of = opts.max_health_of,
        on_downed = opts.on_downed,
      })

      docks.survival = s3:dock("SurvivalDock")
      if type(mounts.survival) == "function" then
        mounts.survival(s3, handle)
      end
    end)

    -- 4. 动作、特殊道具与设施会话相位（Actions）
    s:effect("Stage4:Actions", function(s4)
      docks.actions = s4:dock("ActionsDock")
      docks.special_items = s4:dock("SpecialItemsDock")
      docks.facilities = s4:dock("FacilitiesDock")
      if type(mounts.actions) == "function" then
        mounts.actions(s4, handle)
      end
    end)

    -- 树底纯输出叶子：左手持竿 / 手持外观投影（通过可选注入 create_unit 保持建点台账不变）。
    HeldRodLeaf.mount(s, handle, {
      create_unit = opts.create_unit,
      on_error = function(msg)
        log_error("[PlayerTree]", msg)
      end,
    })

    -- 树底扩展叶子挂点（供 ServerRuntime 挂载 AttrLeaf / AbilityLeaf 等官方包纯输出叶子）。
    if type(mounts.leaves) == "function" then
      mounts.leaves(s, handle)
    end

    -- 树底：单批合并同步节点（等待 Stage1..4 初始化完成后绑定 memos.item_bar_snapshot 与单批合并 Reaction）。
    s:effect("Stage5:StateSync", function(sb)
      sync_fish_coin_attribute(states.coin:now())
      last_pushed_snapshot = memos.item_bar_snapshot:now()

      sb:reaction("StateMirrorAndPush", function()
        if session_alive:now() == false then
          return
        end
        sync_fish_coin_attribute(states.coin:now())
        if not syncing_from_data then
          stage1_dirty = true
          mirror_stage1_to_data()
        end
        states.save_version:set(states.save_version:now() + 1)

        local snapshot = memos.item_bar_snapshot:now()
        if snapshot ~= last_pushed_snapshot then
          last_pushed_snapshot = snapshot
          emit_item_bar_state(snapshot)
        end
      end, {
        memos.item_bar_snapshot,
        states.potion_big_count,
        states.potion_speed_count,
        states.shop_upgrades,
        states.cooldowns,
        states.zone_id,
      })

      sb:reaction("TrackWeakAndSurvivalDirty", function()
        if states.is_weak:now() then
          weak_touched = true
        end
      end, { states.is_weak })

      sb:reaction("TrackSurvivalDirty", function()
        survival_dirty = true
      end, { states.health, states.hunger, states.life_phase })
    end)

    -- 树底：离场终镜像 Reaction（仅在 session_alive 翻转为 false 时同步运行，位于 dispose 之前）。
    s:reaction("LeaveFinalize", function()
      if session_alive:now() == false then
        run_finalizers()
      end
    end, { session_alive })
  end)

  handle.tree = SpokeTree.spawn("PlayerTree:" .. tostring(player.UserId), root, services)

  function handle:batch(fn)
    if type(fn) ~= "function" then
      error("PlayerTree:batch 需要函数", 2)
    end
    return SpokeRuntime.batch(fn)
  end

  function handle:set_coin(value)
    if not is_non_negative_int(value) then
      return false
    end
    states.coin:set(value)
    return true
  end

  function handle:set_zone(zone_id)
    if type(zone_id) ~= "string" or zone_id == "" then
      return false
    end
    states.zone_id:set(zone_id)
    return true
  end

  function handle:set_item_bar(items)
    if type(items) ~= "table" then
      return false
    end
    states.item_bar:set(deep_copy(items))
    return true
  end

  function handle:set_backpack(items)
    if type(items) ~= "table" then
      return false
    end
    states.backpack:set(deep_copy(items))
    return true
  end

  function handle:set_weapons(weapons)
    if type(weapons) ~= "table" then
      return false
    end
    states.weapons:set(deep_copy(weapons))
    return true
  end

  function handle:set_bait(bait)
    if type(bait) ~= "table" then
      return false
    end
    states.bait:set(deep_copy(bait))
    return true
  end

  function handle:set_selected_slot(slot)
    if slot ~= nil and (not is_non_negative_int(slot) or slot < 1) then
      return false
    end
    states.selected_slot:set(slot)
    return true
  end

  function handle:set_selected_bait(item_id)
    if item_id ~= nil and type(item_id) ~= "string" then
      return false
    end
    states.selected_bait:set(item_id)
    return true
  end

  function handle:set_selected_weapon(item_id)
    if item_id ~= nil and type(item_id) ~= "string" then
      return false
    end
    states.selected_weapon:set(item_id)
    return true
  end

  function handle:set_held(held)
    if held ~= nil and type(held) ~= "table" then
      return false
    end
    states.held:set(normalize_held(held))
    return true
  end

  function handle:set_potion_count(item_id, count)
    if not is_non_negative_int(count) then
      return false
    end
    if item_id == "item168" then
      states.potion_big_count:set(count)
      return true
    end
    if item_id == "item167" then
      states.potion_speed_count:set(count)
      return true
    end
    return false
  end

  function handle:set_upgrade_level(level)
    if not is_non_negative_int(level) or level > #GameCfg.Items.UpgradePrices then
      return false
    end
    states.upgrade_level:set(level)
    return true
  end

  function handle:set_shop_upgrades(upgrades)
    if type(upgrades) ~= "table" then
      return false
    end
    states.shop_upgrades:set(deep_copy(upgrades))
    return true
  end

  function handle:set_shop_upgrade(kind, level)
    local spec = type(kind) == "string" and GameCfg.Shop and GameCfg.Shop.UpgradeKinds
        and GameCfg.Shop.UpgradeKinds[kind]
    if not spec or not is_non_negative_int(level) or level > spec.MaxLevel then
      return false
    end
    local next_upgrades = deep_copy(states.shop_upgrades:now() or {})
    next_upgrades[kind] = level
    states.shop_upgrades:set(next_upgrades)
    return true
  end

  function handle:set_cooldown(key, expires_at)
    if type(key) ~= "string" or key == "" then
      return false
    end
    if expires_at ~= nil and not Number.IsFiniteNumber(expires_at) then
      return false
    end
    local next_cooldowns = deep_copy(states.cooldowns:now() or {})
    next_cooldowns[key] = expires_at
    states.cooldowns:set(next_cooldowns)
    return true
  end

  function handle:set_character(character)
    states.character:set(character)
    return true
  end

  --- 将外部（过渡期 PlayerData）最新字段单批同步进 PlayerTree Stage 1 状态，仅变更项触发下游重算。
  ---@param source_data? table
  ---@param sync_opts? { force_push?: boolean }
  function handle:sync_from_data(source_data, sync_opts)
    if self:is_disposed() then
      return false
    end
    local src = type(source_data) == "table" and source_data or data
    if type(src) ~= "table" then
      return false
    end
    local d = type(src.Data) == "table" and src.Data or {}
    local c = type(d.Containers) == "table" and d.Containers or {}
    local extra = type(src.Extra) == "table" and src.Extra or {}
    local inv = type(extra.inventory) == "table" and extra.inventory or {}
    local sel = type(inv.selection) == "table" and inv.selection or {}
    local growth = type(extra.growth) == "table" and extra.growth or {}
    local potions = type(growth.potions) == "table" and growth.potions or {}
    local upgrades = type(growth.upgrades) == "table" and growth.upgrades or {}
    local cds = type(extra.cooldowns) == "table" and extra.cooldowns or {}

    local next_coin = d.FishCoin or 0
    local next_zone = d.Zone or states.zone_id:now()
    local next_upgrade = d.UpgradeLevel or 0
    local next_item_bar = c[container_ids.ItemBar] or {}
    local item_bar_changed = not deep_equal(states.item_bar:now(), next_item_bar)
    local item_bar_copy = item_bar_changed and deep_copy(next_item_bar) or nil
    local next_backpack = c[container_ids.Backpack] or {}
    local backpack_changed = not deep_equal(states.backpack:now(), next_backpack)
    local backpack_copy = backpack_changed and deep_copy(next_backpack) or nil
    local next_weapons = d.Weapons or inv.weapons or {}
    local weapons_changed = not deep_equal(states.weapons:now(), next_weapons)
    local weapons_copy = weapons_changed and deep_copy(next_weapons) or nil
    local next_bait = d.Bait or {}
    local bait_changed = not deep_equal(states.bait:now(), next_bait)
    local bait_copy = bait_changed and deep_copy(next_bait) or nil
    local next_slot = d.SelectedSlot
    local next_bait_sel = d.SelectedBait
    local next_weapon_sel = d.SelectedWeapon
    local next_held = normalize_held(sel.held)
    local held_changed = not deep_equal(states.held:now(), next_held)
    local next_big = potions.item168 or 0
    local next_speed = potions.item167 or 0
    local upgrades_changed = not deep_equal(states.shop_upgrades:now(), upgrades)
    local upgrades_copy = upgrades_changed and deep_copy(upgrades) or nil
    local cds_changed = not deep_equal(states.cooldowns:now(), cds)
    local cds_copy = cds_changed and deep_copy(cds) or nil
    local ok_ch, ch = pcall(function() return player.Character end) -- 兼容引擎 userdata 玩家

    local prev_pushed_snapshot = last_pushed_snapshot
    local prev_syncing = syncing_from_data
    if src == data then
      syncing_from_data = true
    end
    local ok, err = pcall(SpokeRuntime.batch, function() -- 仅保证异常时恢复 syncing_from_data，不吞错
      if states.coin:now() ~= next_coin then states.coin:set(next_coin) end
      if states.zone_id:now() ~= next_zone then states.zone_id:set(next_zone) end
      if states.upgrade_level:now() ~= next_upgrade then states.upgrade_level:set(next_upgrade) end
      if item_bar_changed then states.item_bar:set(item_bar_copy) end
      if backpack_changed then states.backpack:set(backpack_copy) end
      if weapons_changed then states.weapons:set(weapons_copy) end
      if bait_changed then states.bait:set(bait_copy) end
      if states.selected_slot:now() ~= next_slot then states.selected_slot:set(next_slot) end
      if states.selected_bait:now() ~= next_bait_sel then states.selected_bait:set(next_bait_sel) end
      if states.selected_weapon:now() ~= next_weapon_sel then states.selected_weapon:set(next_weapon_sel) end
      if held_changed then states.held:set(next_held) end
      if states.potion_big_count:now() ~= next_big then states.potion_big_count:set(next_big) end
      if states.potion_speed_count:now() ~= next_speed then states.potion_speed_count:set(next_speed) end
      if upgrades_changed then states.shop_upgrades:set(upgrades_copy) end
      if cds_changed then states.cooldowns:set(cds_copy) end
      if ok_ch and states.character:now() ~= ch then states.character:set(ch) end
      if handle._held_rod_failed then
        states.held_rod_retry:set(states.held_rod_retry:now() + 1)
      end
    end)
    syncing_from_data = prev_syncing
    if not ok then
      error(err, 0)
    end
    if type(sync_opts) == "table" and sync_opts.force_push == true and last_pushed_snapshot == prev_pushed_snapshot then
      handle:push_item_bar_state()
    end
    return true
  end

  function handle:get_item_bar_snapshot()
    return deep_copy(memos.item_bar_snapshot:now())
  end

  function handle:push_item_bar_state()
    if self:is_disposed() or session_alive:now() == false then
      return false
    end
    local snapshot = memos.item_bar_snapshot:now()
    last_pushed_snapshot = snapshot
    emit_item_bar_state(snapshot)
    return true
  end

  function handle:mirror_to_data()
    mirror_to_data(true)
  end

  function handle:mount_phase(phase_name, key, block)
    local slot = phase_slots[phase_name]
    if not slot then
      error("PlayerTree:mount_phase 未知相位: " .. tostring(phase_name), 2)
    end
    if type(key) ~= "string" or key == "" then
      error("PlayerTree:mount_phase key 必须是非空字符串", 2)
    end
    if type(block) ~= "function" then
      error("PlayerTree:mount_phase block 必须是函数", 2)
    end
    if slot.blocks[key] == nil then
      slot.order[#slot.order + 1] = key
    end
    slot.blocks[key] = block
    if slot.active_dock and not self:is_disposed() and not self:is_faulted() then
      slot.active_dock:effect(key, block)
    end
  end

  function handle:unmount_phase(phase_name, key)
    local slot = phase_slots[phase_name]
    if not slot then
      error("PlayerTree:unmount_phase 未知相位: " .. tostring(phase_name), 2)
    end
    if slot.blocks[key] == nil then
      return
    end
    slot.blocks[key] = nil
    for i, existing in ipairs(slot.order) do
      if existing == key then
        table.remove(slot.order, i)
        break
      end
    end
    if slot.active_dock and not self:is_disposed() then
      slot.active_dock:drop(key)
    end
  end

  function handle:register_leave_finalizer(fn)
    if type(fn) ~= "function" then
      error("PlayerTree:register_leave_finalizer 需要函数", 2)
    end
    local entry = { fn = fn, active = true }
    finalizers[#finalizers + 1] = entry
    return function()
      entry.active = false
    end
  end

  -- 离场三步协议 Step 1：置 session_alive = false 触发离场终镜像写出与会话结算。
  function handle:begin_leave()
    if self:is_disposed() then
      return
    end
    session_alive:set(false)
    -- 若树此前发生未捕获异常进入 faulted 导致 Reaction 未 flush，仍兜底执行离场终镜像（幂等）。
    if not finalized then
      run_finalizers()
    end
  end

  -- 离场三步协议 Step 2：同步按逆序拆除全部树内在场资源、相位与局部信号连接。
  function handle:dispose()
    if self.tree and not self.tree.is_detached then
      self.tree:dispose()
    end
  end

  function handle:is_disposed()
    return self.tree.is_detached == true
  end

  function handle:is_faulted()
    return self.tree.fault ~= nil
  end

  function handle:fault()
    return self.tree.fault
  end

  if type(handle._life_finish) == "function" then
    local finish = handle._life_finish
    handle._life_finish = nil
    finish()
  end

  if type(handle._pending_leave_finalizers) == "table" then
    for _, fn in ipairs(handle._pending_leave_finalizers) do
      handle:register_leave_finalizer(fn)
    end
    handle._pending_leave_finalizers = nil
  end

  handle:sync_from_data(data)

  return handle
end

return PlayerTree
