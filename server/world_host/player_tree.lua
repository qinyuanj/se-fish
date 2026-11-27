-- 服务端单玩家会话 Auto SpokeTree（ADR-0032 §1、§2、§3 / #295、#297-A1b）：
-- 仅在玩家存档加载就绪时生成；树内严格按源码声明顺序排布四段因果流：
--   1. 存档与库存（SaveInventory：金币/道具栏/背包/武器/鱼饵/选中槽/held/药水/升级/冷却 + ItemBarSnapshot）
--   2. 属性与持续效果派生（Attributes：挂载 PlayerEffects，接管属性派生与持续效果计时主权）
--   3. 生命与生存相位（Survival：外层生命 Phase + 倒计时 platform_pending 门控 + 内层 can_act）
--   4. 动作、特殊道具与设施会话相位（Actions）
-- 树底挂载纯输出叶子（HeldRodLeaf）、单批合并同步 Reaction（ItemBarState 下发 / FishCoin 属性 / 存档镜像）
-- 与离场终镜像 Reaction（session_alive=false 时同步写回完整镜像，包括 weakRemaining）。
-- 本模块归属 L2（server.world_host），零反向依赖存量旧债务模块。
local DeepCopy = require("common.deep_copy")
local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local Number = require("common.number")
local Spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local PlayerEffects = require("server.world_host.player_effects")
local PlayerLife = require("server.world_host.player_life")
local PlayerProjection = require("server.world_host.player_projection")
local SpecialItemPhase = require("server.world_host.special_item_phase")
local FishingPhase = require("server.world_host.fishing_phase")
local HeldRodLeaf = require("server.world_host.held_rod_leaf")
local PlayerCompendium = require("server.world_host.player_compendium")
local PlayerQuest = require("server.world_host.player_quest")
local PlayerStory = require("server.world_host.player_story")
local PlayerAchievements = require("server.world_host.player_achievements")
local PlayerGM = require("server.world_host.player_gm")
local PlayerWeapon = require("server.world_host.player_weapon")
local PlayerGrill = require("server.world_host.player_grill")
local PlayerShop = require("server.world_host.player_shop")
local PlayerFisherman = require("server.world_host.player_fisherman")
local PlayerLottery = require("server.world_host.player_lottery")
local PlayerBlindbox = require("server.world_host.player_blindbox")
local PlayerPlatformShop = require("server.world_host.player_platform_shop")

local SpokeTree = Spoke.SpokeTree
local Effect = Spoke.Effect
local State = Spoke.State
local Trigger = Spoke.Trigger

local PlayerTree = {}

local PHASE_NAMES = {
  alive = true,
  downed = true,
  downed_countdown = true,
  dead = true,
  dead_countdown = true,
}

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
  return Number.is_finite_number(value) and value >= 0 and value == math.floor(value)
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
  return EngineRead.is_valid_player(player, "PlayerTree.is_valid_player")
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
  if data.inited ~= true or data.load_state ~= "ready" then
    error("PlayerTree.spawn 仅允许在存档就绪后生成（LoadState=" .. tostring(data.load_state) .. "）", 3)
  end
end

-- 手持物归一化与存档镜像同形，直接用投影层实现，避免两份定义各自漂移。
local normalize_held = PlayerProjection.normalize_held

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

-- handle 行为表：方法名、参数顺序与返回值同拆分前，对外仍按 handle:method(...) 调用；
-- 原属 PlayerTree.spawn 的 upvalue 统一从 self.tree_env 读取。
local TreeBehavior = {}

-- 同形写入口的生成器：列表型 set_* 只差目标字段（类型校验 → 深拷贝写入 State），
-- 字符串型 set_* 只差「允许 nil」的目标字段；各生成一次闭包，方法名仍逐个挂在行为表上。
local function list_setter(field)
  return function(self, value)
    if type(value) ~= "table" then
      return false
    end
    self.states[field]:set(DeepCopy.copy(value))
    return true
  end
end

local function string_setter(field)
  return function(self, value)
    if value ~= nil and type(value) ~= "string" then
      return false
    end
    self.states[field]:set(value)
    return true
  end
end

-- 树构建段：四段因果流与纯输出叶子的装配，签名统一 (env, s)。
local TreeBuild = {}

-- 生存倒计时相位（Downed / Dead）同形：外层挂主相位 dock，内层按 countdown_active 挂倒计时 dock。
local function countdown_phase(kind, phase_name)
  return function(env, ps)
    local memos, phase_slots = env.memos, env.phase_slots
    mount_phase_dock(ps, phase_slots[kind], kind)
    ps:phase(phase_name, memos.countdown_active, function(cs)
      mount_phase_dock(cs, phase_slots[kind .. "_countdown"], kind .. "_countdown")
    end)
  end
end

---handle 行为表与树构建段共用的上下文，由 PlayerTree.spawn 装配。
---@class PlayerTreeEnv
---@field opts table
---@field player table
---@field data table
---@field clock table
---@field mounts table
---@field container_ids table
---@field session_alive table
---@field states table<string, any>
---@field memos table<string, any>
---@field docks table<string, any>
---@field phase_slots table<string, any>
---@field handle table<string, any>
---@field finalizers table
---@field finalized boolean
---@field last_synced_coin any
---@field last_pushed_snapshot any
---@field stage1_dirty boolean
---@field syncing_from_data boolean
---@field weak_touched boolean
---@field survival_dirty boolean

-- 非表一律退回空表；与 type(value) == "table" and value or {} 等价。
local function pick_table(value, fallback)
  if type(value) == "table" then
    return value
  end
  return fallback
end

-- 仅在确实变化时拷贝；未变化返回 nil，让下游跳过重算。
local function copy_if_changed(changed, value)
  if not changed then
    return nil
  end
  return DeepCopy.copy(value)
end

-- 归一化存档镜像的各级可选表：初始状态与 sync_from_data 共用同一套读取口径。
local function read_raw_sections(source)
  local raw_data = pick_table(source.data, {})
  local raw_extra = pick_table(source.extra, {})
  local raw_inventory = pick_table(raw_extra.inventory, {})
  local raw_growth = pick_table(raw_extra.growth, {})
  return {
    data = raw_data,
    containers = pick_table(raw_data.containers, {}),
    inventory = raw_inventory,
    selection = pick_table(raw_inventory.selection, {}),
    potions = pick_table(raw_growth.potions, {}),
    upgrades = pick_table(raw_growth.upgrades, {}),
    survival = pick_table(raw_extra.survival, {}),
    cooldowns = pick_table(raw_extra.cooldowns, {}),
  }
end

-- Stage 1 初始状态：存档与库存基础状态。
local function init_stage1_states(states, raw, character)
  local container_ids = GameCfg.Items.ContainerId
  states.coin = State.new("PlayerTree.coin", raw.data.FishCoin or 0)
  states.zone_id = State.new("PlayerTree.zone_id", raw.data.Zone or (GameCfg.Zones[1] and GameCfg.Zones[1].Id) or "fishPond")
  states.item_bar = State.new("PlayerTree.item_bar", DeepCopy.copy(raw.containers[container_ids.ItemBar] or {}))
  states.backpack = State.new("PlayerTree.backpack", DeepCopy.copy(raw.containers[container_ids.Backpack] or {}))
  states.weapons = State.new("PlayerTree.weapons", DeepCopy.copy(raw.data.weapons or raw.inventory.weapons or {}))
  states.bait = State.new("PlayerTree.bait", DeepCopy.copy(raw.data.Bait or {}))
  states.selected_slot = State.new("PlayerTree.selected_slot",
    raw.data.selected_slot ~= nil and raw.data.selected_slot or raw.selection.slot)
  states.selected_bait = State.new("PlayerTree.selected_bait",
    raw.data.selected_bait ~= nil and raw.data.selected_bait or raw.selection.bait)
  states.selected_weapon = State.new("PlayerTree.selected_weapon",
    raw.data.selected_weapon ~= nil and raw.data.selected_weapon or raw.selection.weapon)
  states.held = State.new("PlayerTree.held", normalize_held(raw.selection.held))
  states.potion_big_count = State.new("PlayerTree.potion_big_count", raw.potions.item168 or 0)
  states.potion_speed_count = State.new("PlayerTree.potion_speed_count", raw.potions.item167 or 0)
  states.upgrade_level = State.new("PlayerTree.upgrade_level", raw.data.upgrade_level or 0)
  states.shop_upgrades = State.new("PlayerTree.shop_upgrades", DeepCopy.copy(raw.upgrades))
  states.cooldowns = State.new("PlayerTree.cooldowns", DeepCopy.copy(raw.cooldowns))
  states.save_version = State.new("PlayerTree.save_version", 0)
  states.character = State.new("PlayerTree.character", character)
  states.held_rod_retry = State.new("PlayerTree.held_rod_retry", 0)
end

-- Stage 2 初始状态：持续效果与属性修饰输入。
local function init_stage2_states(states, raw)
  states.base_speed = State.new("PlayerTree.base_speed", nil)
  states.is_weak = State.new("PlayerTree.is_weak", (raw.survival.weakRemaining or 0) > 0)
  states.is_frost = State.new("PlayerTree.is_frost", false)
  states.is_paralyzed = State.new("PlayerTree.is_paralyzed", false)
end

-- Stage 3 初始状态：生命与生存状态。
local function init_stage3_states(states, raw)
  states.health = State.new("PlayerTree.health", raw.survival.health or GameCfg.Vitals.MaxHealth)
  states.hunger = State.new("PlayerTree.hunger", raw.survival.hunger or GameCfg.Vitals.MaxHunger)
  states.life_phase = State.new("PlayerTree.life_phase", initial_life_phase(raw.survival))
  states.platform_pending = State.new("PlayerTree.platform_pending", false)
end

local function log_error(env, tag, err)
  local opts, player = env.opts, env.player
  if opts.logger and type(opts.logger.error) == "function" then
    pcall(opts.logger.error, opts.logger, tag .. " (uid=" .. tostring(player.UserId) .. "): " .. tostring(err)) -- logger 异常不得中断业务清理与终镜像
  else
    print(tag, player.UserId, tostring(err))
  end
end

local function sync_fish_coin_attribute(env, coin)
  local player, opts = env.player, env.opts
  if coin == env.last_synced_coin then
    return
  end
  local ok_set = EngineRead.write_attribute(player, "FishCoin", coin, {
    context = "PlayerTree.sync_fish_coin_attribute (uid=" .. tostring(player.UserId) .. ")",
    logger = opts.logger,
  })
  if not ok_set then
    return
  end
  env.last_synced_coin = coin
end

local function mirror_stage1_to_data(env)
  local data, states, container_ids = env.data, env.states, env.container_ids
  if type(data) ~= "table" then
    return
  end
  local patch = PlayerProjection.build_stage1_mirror({
    coin = states.coin:now(),
    zone_id = states.zone_id:now(),
    upgrade_level = states.upgrade_level:now(),
    item_bar = states.item_bar:now(),
    backpack = states.backpack:now(),
    bait = states.bait:now(),
    weapons = states.weapons:now(),
    selected_slot = states.selected_slot:now(),
    selected_bait = states.selected_bait:now(),
    selected_weapon = states.selected_weapon:now(),
    held = states.held:now(),
    potion_big_count = states.potion_big_count:now(),
    potion_speed_count = states.potion_speed_count:now(),
    shop_upgrades = states.shop_upgrades:now(),
    cooldowns = states.cooldowns:now(),
  }, container_ids)
  for _, operation in ipairs(patch) do
    local parent = data
    local path = operation.path
    for index = 1, #path - 1 do
      local key = path[index]
      if type(parent[key]) ~= "table" then
        parent[key] = {}
      end
      parent = parent[key]
    end
    parent[path[#path]] = operation.value
  end
end

local function mirror_to_data(env, force_all)
  local data, states, handle = env.data, env.states, env.handle
  if type(data) ~= "table" then
    return
  end
  if force_all or env.stage1_dirty then
    mirror_stage1_to_data(env)
  end

  if type(data.extra) ~= "table" then
    data.extra = {}
  end
  local extra = data.extra
  if type(extra.survival) ~= "table" then
    extra.survival = {}
  end
  if force_all or env.survival_dirty then
    extra.survival.health = states.health:now()
    extra.survival.hunger = states.hunger:now()
    local phase = states.life_phase:now()
    extra.survival.dying = phase == "downed" or phase == "rescuing"
    extra.survival.dead = phase == "dead"
  end
  if type(handle.get_modifier_remaining) == "function" then
    local weak_rem = handle:get_modifier_remaining("weak")
    if force_all or env.weak_touched or weak_rem > 0 then
      extra.survival.weakRemaining = weak_rem
    end
  end
end

local function emit_item_bar_state(env, snapshot)
  local opts, player, handle = env.opts, env.player, env.handle
  if type(opts.on_item_bar_state) ~= "function" then
    return
  end
  local ok, err = pcall(opts.on_item_bar_state, player, DeepCopy.copy(snapshot), handle) -- 隔离外围推送回调异常，防止打断树状态同步
  if not ok then
    log_error(env, "[PlayerTree] on_item_bar_state 回调失败", err)
  end
end

local function run_finalizers(env)
  local finalizers, handle, player, data, opts = env.finalizers, env.handle, env.player, env.data, env.opts
  if env.finalized then return end
  env.finalized = true
  for _, entry in ipairs(finalizers) do
    if entry.active then
      local ok, err = pcall(entry.fn, handle, player, data) -- 隔离单个离场回调异常，保证其余终镜像与收尾继续执行
      if not ok then
        log_error(env, "[PlayerTree] 离场终镜像回调失败", err)
      end
    end
  end
  mirror_to_data(env)
  if type(opts.on_leave_finalize) == "function" then
    local ok, err = pcall(opts.on_leave_finalize, handle, player, data) -- 隔离宿主离场回调异常，避免阻断后续 dispose 协议
    if not ok then
      log_error(env, "[PlayerTree] on_leave_finalize 失败", err)
    end
  end
end

-- 托管玩家角色生命周期信号（CharacterAdded / CharacterRemoving），树销毁时对称断开，零泄漏。
local function bind_character_signal(env, s, signal_name, on_fire)
  local player, opts = env.player, env.opts
  local ok_sig, sig = EngineRead.read_field(player, signal_name, {
    context = "PlayerTree." .. signal_name,
    logger = opts.logger,
  })
  if not ok_sig or sig == nil then
    return
  end
  local ok_conn, conn = EngineRead.call_method(sig, "Connect", {
    context = "PlayerTree." .. signal_name .. ".Connect",
    logger = opts.logger,
  }, on_fire)
  if ok_conn and conn ~= nil then
    s:on_cleanup(function()
      EngineRead.disconnect(conn, { context = "PlayerTree." .. signal_name .. ".cleanup", logger = opts.logger })
    end)
  end
end

-- 归一化外部（过渡期 PlayerData）快照；非表返回 nil，与拆分前的提前返回一致。
local function read_sync_snapshot(source_data, fallback_data)
  local src = type(source_data) == "table" and source_data or fallback_data
  if type(src) ~= "table" then
    return nil
  end
  return read_raw_sections(src), src
end

-- 只比较不写 State：算出 Stage 1 的差量候选值，供 sync_from_data 在单批合并里提交。
local function compute_sync_candidates(self, source_data)
  local states = self.states
  local container_ids = self.tree_env.container_ids
  local raw, src = read_sync_snapshot(source_data, self.data)
  if raw == nil then
    return nil
  end
  local next_coin = raw.data.FishCoin or 0
  local next_zone = raw.data.Zone or states.zone_id:now()
  local next_upgrade = raw.data.upgrade_level or 0
  local next_item_bar = raw.containers[container_ids.ItemBar] or {}
  local item_bar_changed = not deep_equal(states.item_bar:now(), next_item_bar)
  local next_backpack = raw.containers[container_ids.Backpack] or {}
  local backpack_changed = not deep_equal(states.backpack:now(), next_backpack)
  local next_weapons = raw.data.weapons or raw.inventory.weapons or {}
  local weapons_changed = not deep_equal(states.weapons:now(), next_weapons)
  local next_bait = raw.data.Bait or {}
  local bait_changed = not deep_equal(states.bait:now(), next_bait)
  local next_held = normalize_held(raw.selection.held)
  local held_changed = not deep_equal(states.held:now(), next_held)
  local upgrades_changed = not deep_equal(states.shop_upgrades:now(), raw.upgrades)
  local cds_changed = not deep_equal(states.cooldowns:now(), raw.cooldowns)
  local read_opts = { context = "PlayerTree.sync_from_data", logger = self.tree_env.opts.logger }
  local ok_ch, ch = EngineRead.read_character(self.player, read_opts)
  return {
    from_own_data = src == self.data,
    coin = next_coin,
    zone = next_zone,
    upgrade = next_upgrade,
    item_bar_changed = item_bar_changed,
    item_bar_copy = copy_if_changed(item_bar_changed, next_item_bar),
    backpack_changed = backpack_changed,
    backpack_copy = copy_if_changed(backpack_changed, next_backpack),
    weapons_changed = weapons_changed,
    weapons_copy = copy_if_changed(weapons_changed, next_weapons),
    bait_changed = bait_changed,
    bait_copy = copy_if_changed(bait_changed, next_bait),
    slot = raw.data.selected_slot,
    bait_sel = raw.data.selected_bait,
    weapon_sel = raw.data.selected_weapon,
    held_changed = held_changed,
    held = next_held,
    potion_big = raw.potions.item168 or 0,
    potion_speed = raw.potions.item167 or 0,
    upgrades_changed = upgrades_changed,
    upgrades_copy = copy_if_changed(upgrades_changed, raw.upgrades),
    cds_changed = cds_changed,
    cds_copy = copy_if_changed(cds_changed, raw.cooldowns),
    character = ok_ch and ch or nil,
  }
end

-- 在单批合并里提交候选值：仅变更项写 State，避免无谓的下游重算。
local function apply_sync_candidates(self, next)
  local states = self.states
  if states.coin:now() ~= next.coin then states.coin:set(next.coin) end
  if states.zone_id:now() ~= next.zone then states.zone_id:set(next.zone) end
  if states.upgrade_level:now() ~= next.upgrade then states.upgrade_level:set(next.upgrade) end
  if next.item_bar_changed then states.item_bar:set(next.item_bar_copy) end
  if next.backpack_changed then states.backpack:set(next.backpack_copy) end
  if next.weapons_changed then states.weapons:set(next.weapons_copy) end
  if next.bait_changed then states.bait:set(next.bait_copy) end
  if states.selected_slot:now() ~= next.slot then states.selected_slot:set(next.slot) end
  if states.selected_bait:now() ~= next.bait_sel then states.selected_bait:set(next.bait_sel) end
  if states.selected_weapon:now() ~= next.weapon_sel then states.selected_weapon:set(next.weapon_sel) end
  if next.held_changed then states.held:set(next.held) end
  if states.potion_big_count:now() ~= next.potion_big then states.potion_big_count:set(next.potion_big) end
  if states.potion_speed_count:now() ~= next.potion_speed then states.potion_speed_count:set(next.potion_speed) end
  if next.upgrades_changed then states.shop_upgrades:set(next.upgrades_copy) end
  if next.cds_changed then states.cooldowns:set(next.cds_copy) end
  if states.character:now() ~= next.character then states.character:set(next.character) end
  if self._held_rod_failed then
    states.held_rod_retry:set(states.held_rod_retry:now() + 1)
  end
end

function TreeBuild.alive_phase(env, ps)
  local opts, handle, phase_slots = env.opts, env.handle, env.phase_slots
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
  local weapon = PlayerWeapon.mount(ps, handle, {
    remote = opts.remote,
    save = opts.save,
    physics = opts.physics,
    players_service = opts.players_service,
    ability = opts.ability,
    fish_unit = opts.weapon_fish_unit,
    fish_carrier = opts.fish_carrier,
    world = opts.world_service,
    random = opts.random,
    new_hit = opts.new_hit,
    apply_hit = opts.apply_hit,
    apply_effect = opts.apply_effect,
  })
  local weapon_guard = function(unit, index) return weapon:guard(unit, index) end
  handle.weapon_cast_guard = weapon_guard
  ps:on_cleanup(function()
    if handle.weapon_cast_guard == weapon_guard then handle.weapon_cast_guard = nil end
  end)
  PlayerGrill.mount(ps, handle, {
    remote = opts.remote,
    save = opts.save,
    world = opts.world_service,
    create_unit = opts.create_unit,
    players = opts.players,
    new_hit = opts.new_hit,
    apply_hit = opts.apply_hit,
  })
  PlayerShop.mount(ps, handle, {
    remote = opts.remote,
    save = opts.save,
    quest = handle.quest or opts.quest,
  })
  PlayerFisherman.mount(ps, handle, {
    remote = opts.remote,
    save = opts.save,
    quest = handle.quest or opts.quest,
  })
  PlayerLottery.mount(ps, handle, {
    remote = opts.remote,
    save = opts.save,
    random = opts.random,
    in_range = opts.lottery_in_range,
  })
end

TreeBuild.downed_phase = countdown_phase("downed", "DownedCountdown")
TreeBuild.dead_phase = countdown_phase("dead", "DeadCountdown")

function TreeBuild.stage1(env, s1)
  local opts, mounts, handle = env.opts, env.mounts, env.handle
  local states, memos, docks = env.states, env.memos, env.docks
  local player, clock = env.player, env.clock
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
    return PlayerProjection.build_item_bar_snapshot({
      item_bar = ms:d(states.item_bar),
      slot_count = ms:d(memos.item_bar_capacity),
      backpack = ms:d(states.backpack),
      backpack_count = ms:d(memos.backpack_capacity),
      upgrade_level = ms:d(states.upgrade_level),
      bait = ms:d(states.bait),
      coin = ms:d(states.coin),
      selected_slot = ms:d(states.selected_slot),
      selected_bait = ms:d(states.selected_bait),
      weapons = ms:d(states.weapons),
      selected_weapon = ms:d(states.selected_weapon),
      held = ms:d(states.held),
    })
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
end

function TreeBuild.stage2(env, s2)
  local opts, mounts, handle, states, docks = env.opts, env.mounts, env.handle, env.states, env.docks
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
end

function TreeBuild.stage3(env, s3)
  local opts, mounts, handle = env.opts, env.mounts, env.handle
  local memos, docks, states = env.memos, env.docks, env.states
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
  TreeBuild.alive_phase(env, ps)
end)

-- 濒死相位：内嵌 platform_pending 门控的倒计时子相位。
s3:phase("DownedPhase", memos.is_downed, function(ps)
  TreeBuild.downed_phase(env, ps)
end)

-- 死亡相位：内嵌 platform_pending 门控的倒计时子相位。
s3:phase("DeadPhase", memos.is_dead, function(ps)
  TreeBuild.dead_phase(env, ps)
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
end

function TreeBuild.stage4(env, s4)
  local opts, mounts, handle, docks = env.opts, env.mounts, env.handle, env.docks
  docks.actions = s4:dock("ActionsDock")
  docks.special_items = s4:dock("SpecialItemsDock")
  docks.facilities = s4:dock("FacilitiesDock")
  if type(mounts.actions) == "function" then
    mounts.actions(s4, handle)
  end
  local delivery_epoch = opts.delivery_epoch or tostring(opts.world)
  PlayerBlindbox.mount(s4, handle, {
    remote = opts.remote, state = State,
    save = opts.save,
    platform = opts.platform,
    world = opts.world,
    random = opts.random,
    delivery_epoch = delivery_epoch,
  })
  PlayerPlatformShop.mount(s4, handle, {
    remote = opts.remote, state = State,
    save = opts.save,
    platform = opts.platform,
    world = opts.world,
    delivery_epoch = delivery_epoch,
  })
end

function TreeBuild.stage5(env, sb)
  local states, memos, session_alive = env.states, env.memos, env.session_alive
  sync_fish_coin_attribute(env, states.coin:now())
  env.last_pushed_snapshot = memos.item_bar_snapshot:now()

  sb:reaction("StateMirrorAndPush", function()
    if session_alive:now() == false then
      return
    end
    sync_fish_coin_attribute(env, states.coin:now())
    if not env.syncing_from_data then
      env.stage1_dirty = true
      mirror_stage1_to_data(env)
    end
    states.save_version:set(states.save_version:now() + 1)

    local snapshot = memos.item_bar_snapshot:now()
    if snapshot ~= env.last_pushed_snapshot then
      env.last_pushed_snapshot = snapshot
      emit_item_bar_state(env, snapshot)
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
      env.weak_touched = true
    end
  end, { states.is_weak })

  sb:reaction("TrackSurvivalDirty", function()
    env.survival_dirty = true
  end, { states.health, states.hunger, states.life_phase })
end

function TreeBuild.root(env, s)
  local opts, player, data, clock = env.opts, env.player, env.data, env.clock
  local session_alive, handle, states, mounts = env.session_alive, env.handle, env.states, env.mounts
  s:export("clock", clock)
  s:export("player", player)
  s:export("data", data)
  s:export("session_alive", session_alive)
  s:export("player_tree", handle)
  if opts.world ~= nil then
    s:export("world", opts.world)
  end

  bind_character_signal(env, s, "CharacterAdded", function(character)
    if not handle:is_disposed() then
      states.character:set(character)
    end
  end)

  bind_character_signal(env, s, "CharacterRemoving", function(character)
    if not handle:is_disposed() then
      if character == nil or states.character:now() == character then
        states.character:set(nil)
      end
    end
  end)

-- 1. 存档与库存（SaveInventory）
s:effect("Stage1:SaveInventory", function(s1)
  TreeBuild.stage1(env, s1)
end)

-- 2. 属性与持续效果派生（Attributes）
s:effect("Stage2:Attributes", function(s2)
  TreeBuild.stage2(env, s2)
end)

-- 3. 生命与生存相位（Survival）
s:effect("Stage3:Survival", function(s3)
  TreeBuild.stage3(env, s3)
end)

-- 4. 动作、特殊道具与设施会话相位（Actions）
s:effect("Stage4:Actions", function(s4)
  TreeBuild.stage4(env, s4)
end)

  -- 树底纯输出叶子：左手持竿 / 手持外观投影（通过可选注入 create_unit 保持建点台账不变）。
  HeldRodLeaf.mount(s, handle, {
    create_unit = opts.create_unit,
    on_error = function(msg)
      log_error(env, "[PlayerTree]", msg)
    end,
  })

  -- 树底扩展叶子挂点（供 ServerRuntime 挂载 AttrLeaf / AbilityLeaf 等官方包纯输出叶子）。
  if type(mounts.leaves) == "function" then
    mounts.leaves(s, handle)
  end

-- 树底：单批合并同步节点（等待 Stage1..4 初始化完成后绑定 memos.item_bar_snapshot 与单批合并 Reaction）。
s:effect("Stage5:StateSync", function(sb)
  TreeBuild.stage5(env, sb)
end)
  -- 树底：离场终镜像 Reaction（仅在 session_alive 翻转为 false 时同步运行，位于 dispose 之前）。
  s:reaction("LeaveFinalize", function()
    if session_alive:now() == false then
      run_finalizers(env)
    end
  end, { session_alive })
end

function TreeBehavior.batch(_, fn)
  if type(fn) ~= "function" then
    error("PlayerTree:batch 需要函数", 2)
  end
  return SpokeRuntime.batch(fn)
end

function TreeBehavior.set_coin(self, value)
  local states = self.states
  if not is_non_negative_int(value) then
    return false
  end
  states.coin:set(value)
  return true
end

function TreeBehavior.set_zone(self, zone_id)
  local states = self.states
  if type(zone_id) ~= "string" or zone_id == "" then
    return false
  end
  states.zone_id:set(zone_id)
  return true
end

TreeBehavior.set_item_bar = list_setter("item_bar")

TreeBehavior.set_backpack = list_setter("backpack")

TreeBehavior.set_weapons = list_setter("weapons")

TreeBehavior.set_bait = list_setter("bait")

function TreeBehavior.set_selected_slot(self, slot)
  local states = self.states
  if slot ~= nil and (not is_non_negative_int(slot) or slot < 1) then
    return false
  end
  states.selected_slot:set(slot)
  return true
end

TreeBehavior.set_selected_bait = string_setter("selected_bait")

TreeBehavior.set_selected_weapon = string_setter("selected_weapon")

function TreeBehavior.set_held(self, held)
  local states = self.states
  if held ~= nil and type(held) ~= "table" then
    return false
  end
  states.held:set(normalize_held(held))
  return true
end

function TreeBehavior.set_potion_count(self, item_id, count)
  local states = self.states
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

function TreeBehavior.set_upgrade_level(self, level)
  local states = self.states
  if not is_non_negative_int(level) or level > #GameCfg.Items.UpgradePrices then
    return false
  end
  states.upgrade_level:set(level)
  return true
end

TreeBehavior.set_shop_upgrades = list_setter("shop_upgrades")

function TreeBehavior.set_shop_upgrade(self, kind, level)
  local states = self.states
  local spec = type(kind) == "string" and GameCfg.Shop and GameCfg.Shop.UpgradeKinds
      and GameCfg.Shop.UpgradeKinds[kind]
  if not spec or not is_non_negative_int(level) then
    return false
  end
  ---@cast spec { MaxLevel: number }
  if level > spec.MaxLevel then
    return false
  end
  local next_upgrades = DeepCopy.copy(states.shop_upgrades:now() or {})
  next_upgrades[kind] = level
  states.shop_upgrades:set(next_upgrades)
  return true
end

function TreeBehavior.set_cooldown(self, key, expires_at)
  local states = self.states
  if type(key) ~= "string" or key == "" then
    return false
  end
  if expires_at ~= nil and not Number.is_finite_number(expires_at) then
    return false
  end
  local next_cooldowns = DeepCopy.copy(states.cooldowns:now() or {})
  next_cooldowns[key] = expires_at
  states.cooldowns:set(next_cooldowns)
  return true
end

function TreeBehavior.set_character(self, character)
  local states = self.states
  states.character:set(character)
  return true
end

function TreeBehavior.get_item_bar_snapshot(self)
  local memos = self.memos
  return DeepCopy.copy(memos.item_bar_snapshot:now())
end

function TreeBehavior.push_item_bar_state(self)
  local env = self.tree_env
  local memos, session_alive = self.memos, self.session_alive
  if self:is_disposed() or session_alive:now() == false then
    return false
  end
  local snapshot = memos.item_bar_snapshot:now()
  env.last_pushed_snapshot = snapshot
  emit_item_bar_state(env, snapshot)
  return true
end

function TreeBehavior.mirror_to_data(self)
  local env = self.tree_env
  mirror_to_data(env, true)
end

function TreeBehavior.dispatch_action(self, action, payload)
  local session_alive = self.session_alive
  local trigger = self.actions[action]
  if not trigger or self:is_disposed() or session_alive:now() == false then return false end
  local event = { payload = payload, result = false }
  trigger:invoke(event)
  return event.result
end

function TreeBehavior.mount_phase(self, phase_name, key, block)
  local phase_slots = self.tree_env.phase_slots
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

function TreeBehavior.unmount_phase(self, phase_name, key)
  local phase_slots = self.tree_env.phase_slots
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

function TreeBehavior.register_leave_finalizer(self, fn)
  local finalizers = self.tree_env.finalizers
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
function TreeBehavior.begin_leave(self)
  local env = self.tree_env
  local session_alive = self.session_alive
  if self:is_disposed() then
    return
  end
  session_alive:set(false)
  -- 若树此前发生未捕获异常进入 faulted 导致 Reaction 未 flush，仍兜底执行离场终镜像（幂等）。
  if not env.finalized then
    run_finalizers(env)
  end
end

-- 离场三步协议 Step 2：同步按逆序拆除全部树内在场资源、相位与局部信号连接。
function TreeBehavior.dispose(self)
  if self.tree and not self.tree.is_detached then
    self.tree:dispose()
  end
end

function TreeBehavior.is_disposed(self)
  return self.tree.is_detached == true
end

function TreeBehavior.is_faulted(self)
  return self.tree.fault ~= nil
end

function TreeBehavior.fault(self)
  return self.tree.fault
end

--- 将外部（过渡期 PlayerData）最新字段单批同步进 PlayerTree Stage 1 状态，仅变更项触发下游重算。
---@param source_data? table
---@param sync_opts? { force_push?: boolean }
function TreeBehavior.sync_from_data(self, source_data, sync_opts)
  local env = self.tree_env
  if self:is_disposed() then
    return false
  end
  local next = compute_sync_candidates(self, source_data)
  if next == nil then
    return false
  end
  local prev_pushed_snapshot = env.last_pushed_snapshot
  local prev_syncing = env.syncing_from_data
  if next.from_own_data then
    env.syncing_from_data = true
  end
  local ok, err = pcall(SpokeRuntime.batch, function() -- 仅保证异常时恢复 syncing_from_data，不吞错
    apply_sync_candidates(self, next)
  end)
  env.syncing_from_data = prev_syncing
  if not ok then
    error(err, 0)
  end
  local force_push = type(sync_opts) == "table" and sync_opts.force_push == true
  if force_push and env.last_pushed_snapshot == prev_pushed_snapshot then
    self:push_item_bar_state()
  end
  return true
end

---@param opts table { player: table, data: table, clock: table, world?: table, logger?: table, effects?: table, create_unit?: function, on_item_bar_state?: function, on_leave_finalize?: function, mounts?: table }
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
  local raw = read_raw_sections(data)

  local ok_char, initial_character = EngineRead.read_character(player, { context = "PlayerTree.spawn", logger = opts.logger })

  local session_alive = State.new("PlayerTree.session_alive", true)
  local states = {}
  init_stage1_states(states, raw, ok_char and initial_character or nil)
  init_stage2_states(states, raw)
  init_stage3_states(states, raw)

  local memos = {}
  local docks = {}
  local phase_slots = make_phase_slots()

  ---@type table<string, any>
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
    actions = {
      weapon = Trigger.new("PlayerTree.weapon"),
      grill = Trigger.new("PlayerTree.grill"),
      shop = Trigger.new("PlayerTree.shop"),
      interact = Trigger.new("PlayerTree.interact"),
      lottery = Trigger.new("PlayerTree.lottery"),
      lottery_state = Trigger.new("PlayerTree.lottery_state"),
      blindbox = Trigger.new("PlayerTree.blindbox"),
      blindbox_state = Trigger.new("PlayerTree.blindbox_state"),
      platform_shop = Trigger.new("PlayerTree.platform_shop"),
    },
    tree = nil,
  }

  ---@type PlayerTreeEnv
  local env = {
    opts = opts,
    player = player,
    data = data,
    clock = clock,
    mounts = mounts,
    container_ids = GameCfg.Items.ContainerId,
    session_alive = session_alive,
    states = states,
    memos = memos,
    docks = docks,
    phase_slots = phase_slots,
    handle = handle,
    finalizers = {},
    finalized = false,
    last_synced_coin = nil,
    last_pushed_snapshot = nil,
    stage1_dirty = false,
    syncing_from_data = false,
    weak_touched = (raw.survival.weakRemaining or 0) > 0,
    survival_dirty = false,
  }
  handle.tree_env = env

  local services = opts.logger and { logger = opts.logger } or nil
  local root = Effect.new("PlayerRoot:" .. tostring(player.UserId), function(s)
    TreeBuild.root(env, s)
  end)
  handle.tree = SpokeTree.spawn("PlayerTree:" .. tostring(player.UserId), root, services)

  -- 行为表整体挂到 instance：方法名、参数顺序与返回值同拆分前，调用方仍按 tree:method(...) 调用。
  for name, method in pairs(TreeBehavior) do
    handle[name] = method
  end

  -- 离场终镜像由 PlayerLife 在树构建期间挂接：先暂存，方法装好后立即补执行。
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
