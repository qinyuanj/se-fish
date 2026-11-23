-- 服务端单玩家会话 Auto SpokeTree（ADR-0032 §1、§2 / #295）：
-- 仅在玩家存档加载就绪时生成；树内严格按源码声明顺序排布四段因果流：
--   1. 存档与库存（SaveInventory）
--   2. 属性与持续效果派生（Attributes）
--   3. 生命与生存相位（Survival：外层生命 Phase + 倒计时 platform_pending 门控 + 内层 can_act）
--   4. 动作、特殊道具与设施会话相位（Actions）
-- 根部持有 session_alive（初始 true），支持离场三步协议 Step 1（终镜像写出）→ Step 2（同步 dispose 逆序清理）。
-- 本模块归属 L2（server.World），零反向依赖存量旧债务模块。

local GameCfg = require("common.GameCfg")
local AttrModel = require("common.AttrModel")
local spoke = require("common.packages.spoke.api")

local SpokeTree = spoke.SpokeTree
local Effect = spoke.Effect
local State = spoke.State

local PlayerTree = {}

local PHASE_NAMES = {
  alive = true,
  downed = true,
  downed_countdown = true,
  dead = true,
  dead_countdown = true,
}

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

---@param opts { player: table, data: table, clock: table, world?: table, logger?: table, on_leave_finalize?: fun(tree: table, player: table, data: table), mounts?: table }
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
  local raw_data = type(data.Data) == "table" and data.Data or {}
  local raw_extra = type(data.Extra) == "table" and data.Extra or {}
  local raw_growth = type(raw_extra.growth) == "table" and raw_extra.growth or {}
  local raw_potions = type(raw_growth.potions) == "table" and raw_growth.potions or {}
  local raw_survival = type(raw_extra.survival) == "table" and raw_extra.survival or {}

  local session_alive = State.new("PlayerTree.session_alive", true)
  local states = {
    -- Stage 1: 存档与库存基础状态
    coin = State.new("PlayerTree.coin", raw_data.FishCoin or 0),
    zone_id = State.new("PlayerTree.zone_id", raw_data.Zone or (GameCfg.Zones[1] and GameCfg.Zones[1].Id) or "fishPond"),
    selected_slot = State.new("PlayerTree.selected_slot", raw_data.SelectedSlot),
    potion_big_count = State.new("PlayerTree.potion_big_count", raw_potions.item168 or 0),
    potion_speed_count = State.new("PlayerTree.potion_speed_count", raw_potions.item167 or 0),
    save_version = State.new("PlayerTree.save_version", 0),
    -- Stage 2: 持续效果与属性修饰输入
    is_weak = State.new("PlayerTree.is_weak", (raw_survival.weakRemaining or 0) > 0),
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
      pcall(opts.logger.error, opts.logger, tag .. ": " .. tostring(err)) -- logger 异常不得中断业务清理与终镜像
    else
      print(tag, player.UserId, tostring(err))
    end
  end

  local function run_finalizers()
    if finalized then return end
    finalized = true
    for _, entry in ipairs(finalizers) do
      if entry.active then
        local ok, err = pcall(entry.fn, handle, player, data)
        if not ok then
          log_error("[PlayerTree] 离场终镜像回调失败", err)
        end
      end
    end
    if type(opts.on_leave_finalize) == "function" then
      local ok, err = pcall(opts.on_leave_finalize, handle, player, data)
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

    -- 1. 存档与库存（SaveInventory）
    s:effect("Stage1:SaveInventory", function(s1)
      docks.save_inventory = s1:dock("SaveInventoryDock")
      if type(mounts.save_inventory) == "function" then
        mounts.save_inventory(s1, handle)
      end
    end)

    -- 2. 属性与持续效果派生（Attributes）
    s:effect("Stage2:Attributes", function(s2)
      docks.modifiers = s2:dock("ModifierDock")

      local attr_plan = s2:memo("AttrPlan", function(ms)
        local body_potions = ms:d(states.potion_big_count)
        local speed_potions = ms:d(states.potion_speed_count)
        local weak = ms:d(states.is_weak)
        local move_mult = weak and GameCfg.Survival.WeakSpeedScale or 1
        return AttrModel.Plan({
          bodyPotions = body_potions,
          speedPotions = speed_potions,
          moveMultiplier = move_mult,
        })
      end)

      memos.max_health = s2:memo("MaxHealth", function(ms)
        return ms:d(attr_plan).Body.Health
      end)

      memos.body_scale = s2:memo("BodyScale", function(ms)
        return ms:d(attr_plan).Body.Scale
      end)

      memos.move_speed_scale = s2:memo("MoveSpeedScale", function(ms)
        return 1 + ms:d(attr_plan).Attributes.PlayerWalkSpeed.Ratio
      end)

      docks.attributes = s2:dock("AttributesDock")
      if type(mounts.attributes) == "function" then
        mounts.attributes(s2, handle)
      end
    end)

    -- 3. 生命与生存相位（Survival）
    s:effect("Stage3:Survival", function(s3)
      memos.is_alive = s3:memo("IsAlive", function(ms)
        return ms:d(states.life_phase) == "alive"
      end)
      memos.is_downed = s3:memo("IsDowned", function(ms)
        return ms:d(states.life_phase) == "downed"
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

    -- 树底：离场终镜像 Reaction（仅在 session_alive 翻转为 false 时同步运行，位于 dispose 之前）。
    s:reaction("LeaveFinalize", function()
      if session_alive:now() == false then
        run_finalizers()
      end
    end, { session_alive })
  end)

  handle.tree = SpokeTree.spawn("PlayerTree:" .. tostring(player.UserId), root, services)

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

  return handle
end

return PlayerTree
