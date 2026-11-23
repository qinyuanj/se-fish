-- #297-A1a 契约测试：PlayerEffects（属性派生与持续效果计时/层数主权）与 HeldRodLeaf（左手持竿投影）。
-- 失败方式先列：
--   1. AttrModel/BodyScale 派生公式漂移，或药水/武器升级超限时未封顶，或角色重建未重新捕获基准移速；
--   2. poison/burn 叠层超 5 层、刷新清零层数或丢失 DoT 跳伤相位/末次来源、来源离场后仍继续扣血；
--   3. frost 叠加衰减超过 30%，或 weak + frost 未正确叠乘（0.5 * 0.7 = 0.35）；
--   4. paralyze 0.5s 亚秒到期失灵，或麻痹错误退出外层 alive 相位；
--   5. weak 在角色空窗期继续流失或角色重建后丢失剩余秒数；
--   6. HeldRodLeaf 在切槽/角色重建/树 dispose 后未逆序销毁模型与挂点，或模型创建失败时泄漏挂点。

local GameCfg = require("common.GameCfg")
local BodyScale = require("common.BodyScale")
local SpokeClock = require("common.SpokeClock")
local spoke = require("common.packages.spoke.api")
local SpokeRuntime = require("common.packages.spoke.runtime.spoke_runtime")
local PlayerTree = require("server.World.PlayerTree")
local PlayerEffects = require("server.World.PlayerEffects")
local HeldRodLeaf = require("server.World.HeldRodLeaf")

local State = spoke.State
local Effect = spoke.Effect
local SpokeTree = spoke.SpokeTree

local function make_ready_data(player, overrides)
  overrides = overrides or {}
  return {
    Player = player,
    Inited = true,
    LoadState = "ready",
    Data = {
      FishCoin = overrides.coin or 0,
      Zone = overrides.zone or "fishPond",
      SelectedSlot = overrides.selected_slot,
    },
    Extra = {
      growth = {
        potions = {
          item168 = overrides.body_potions or 0,
          item167 = overrides.speed_potions or 0,
        },
        upgrades = overrides.upgrades or {},
      },
      survival = {
        health = overrides.health or GameCfg.Vitals.MaxHealth,
        hunger = overrides.hunger or GameCfg.Vitals.MaxHunger,
        dying = false,
        dead = false,
        weakRemaining = overrides.weak_remaining or 0,
      },
    },
  }
end

local function make_character(walk_speed)
  return {
    Name = "EggyCharacter",
    Controller = { WalkSpeed = walk_speed or 7 },
  }
end

local function spawn_with_effects(opts)
  opts = opts or {}
  local clock = opts.clock or SpokeClock.new(100)
  local player = opts.player or { UserId = opts.user_id or 7001, Character = opts.character }
  local data = make_ready_data(player, opts.data_overrides)
  local dot_ticks = {}
  local leaf_events = {}

  local pt = PlayerTree.spawn({
    player = player,
    data = data,
    clock = clock,
    mounts = {
      attributes = function(s2, tree)
        PlayerEffects.mount(s2, tree, {
          on_dot_tick = function(target_tree, kind, damage, source, stacks)
            dot_ticks[#dot_ticks + 1] = {
              user_id = target_tree.user_id,
              kind = kind,
              damage = damage,
              source = source,
              stacks = stacks,
              now = clock.now(),
            }
          end,
          on_mount_modifier_leaf = function(es, _, kind, entry)
            leaf_events[#leaf_events + 1] = "mount:" .. kind .. ":stacks=" .. tostring(entry.stacks)
            es:on_cleanup(function()
              leaf_events[#leaf_events + 1] = "cleanup:" .. kind
            end)
          end,
        })
      end,
    },
  })

  return pt, clock, dot_ticks, leaf_events
end

describe("PlayerEffects：确定性属性派生（AttrModel / BodyScale）", function()
  it("药水成长、武器升级与基准移速变更时确定性重算且正确封顶", function()
    local char1 = make_character(8)
    local pt = spawn_with_effects({
      character = char1,
      data_overrides = {
        body_potions = 2,
        speed_potions = 3,
        upgrades = { melee = 2, ranged = 1, explosive = 3 },
      },
    })

    assert.equals(420, pt.memos.max_health:now())
    assert.near(1.4, pt.memos.body_scale:now(), 1e-9)
    assert.is_false(pt.memos.body_scale_capped:now())
    assert.near(BodyScale.Derive(1.4).CameraDistance, pt.memos.body_derived:now().CameraDistance, 1e-9)
    assert.near(BodyScale.Derive(1.4).InteractRange, pt.memos.body_derived:now().InteractRange, 1e-9)
    assert.near(8 * 1.3, pt.memos.walk_speed:now(), 1e-9)
    assert.near(1.2, pt.memos.weapon_damage_scales:now().melee, 1e-9)

    -- 封顶成长：10 变大（900 血、3 倍体型）、20 加速（3 倍速）
    SpokeRuntime.batch(function()
      pt.states.potion_big_count:set(99)
      pt.states.potion_speed_count:set(99)
      pt.states.shop_upgrades:set({ melee = 5, ranged = 2, explosive = 1 })
    end)
    assert.equals(900, pt.memos.max_health:now())
    assert.near(3, pt.memos.body_scale:now(), 1e-9)
    assert.is_true(pt.memos.body_scale_capped:now())
    assert.near(8 * 3, pt.memos.walk_speed:now(), 1e-9)
    assert.near(GameCfg.Shop.DamageScale("melee", 5), pt.memos.weapon_damage_scales:now().melee, 1e-9)

    -- 角色重建后重新捕获新角色基准移速
    local char2 = make_character(10)
    pt.states.character:set(char2)
    assert.near(10 * 3, pt.memos.walk_speed:now(), 1e-9)

    pt:dispose()
  end)
end)

describe("PlayerEffects：持续效果计时与层数主权", function()
  it("poison 与 burn 叠层上限 5、刷新保留跳伤相位与末次来源、来源离场与到期清空零残留", function()
    local pt, clock, dot_ticks, leaf_events = spawn_with_effects({
      character = make_character(7),
    })
    local src1 = { UserId = 9001 }
    local src2 = { UserId = 9002 }

    assert.is_true(pt:apply_modifier("poison", { source = src1 }))
    clock:advance(0.5)
    assert.is_true(pt:apply_modifier("poison", { source = src2 }))
    assert.equals(2, pt:get_modifier_stacks("poison"))
    assert.near(3, pt:get_modifier_remaining("poison"), 1e-9)

    -- 100.0 -> 101.0 第一跳：2 层 × 1 = 2，来源为末次命中 src2
    clock:advance(0.5)
    assert.equals(1, #dot_ticks)
    assert.equals("poison", dot_ticks[1].kind)
    assert.equals(2, dot_ticks[1].damage)
    assert.equals(src2, dot_ticks[1].source)

    -- 叠到超上限 6 次仍钳制在 5 层
    for _ = 1, 6 do
      pt:apply_modifier("poison", { source = src2 })
    end
    assert.equals(5, pt:get_modifier_stacks("poison"))

    -- 再推进 3 秒：102、103、104 各跳 5 点，并在 104.0 到期注销叶子
    clock:advance(3)
    assert.equals(4, #dot_ticks)
    assert.equals(5, dot_ticks[2].damage)
    assert.equals(5, dot_ticks[4].damage)
    assert.equals(0, pt:get_modifier_stacks("poison"))
    assert.equals(0, pt:get_modifier_remaining("poison"))
    assert.same({ "mount:poison:stacks=1", "cleanup:poison" }, leaf_events)

    -- 到期后不再产生跳伤
    clock:advance(2)
    assert.equals(4, #dot_ticks)

    -- burn（每层 4 点）在来源离场时被清除，不再跳伤
    assert.is_true(pt:apply_modifier("burn", { source = src1 }))
    assert.is_true(pt:apply_modifier("burn", { source = src1 }))
    clock:advance(1)
    assert.equals(5, #dot_ticks)
    assert.equals("burn", dot_ticks[5].kind)
    assert.equals(8, dot_ticks[5].damage)

    pt:clear_modifiers_by_source(src1)
    assert.equals(0, pt:get_modifier_stacks("burn"))
    clock:advance(2)
    assert.equals(5, #dot_ticks)

    pt:dispose()
  end)

  it("paralyze 0.5s 亚秒由 SpokeClock.on_frame 驱动，仅关 can_act 与移速归零、不退出 alive 相位", function()
    local pt, clock = spawn_with_effects({
      character = make_character(7),
    })

    local alive_mounts, alive_cleanups = 0, 0
    pt:mount_phase("alive", "ParalyzeSafetyProbe", function(s)
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
    assert.equals(0, pt.memos.move_multiplier:now())
    assert.equals(0, pt.memos.walk_speed:now())
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    -- 推进 0.3s 刷新麻痹（不叠加，仍为 0.5s）
    clock:advance(0.3)
    assert.is_false(pt.memos.can_act:now())
    assert.is_true(pt:apply_modifier("paralyze"))
    assert.near(0.5, pt:get_modifier_remaining("paralyze"), 1e-9)

    -- 推进 0.5s 亚秒精确到期恢复
    clock:advance(0.5)
    assert.is_true(pt.memos.can_act:now())
    assert.equals(1, pt.memos.move_multiplier:now())
    assert.near(7, pt.memos.walk_speed:now(), 1e-9)
    assert.equals(1, alive_mounts)
    assert.equals(0, alive_cleanups)

    pt:dispose()
  end)

  it("frost 不可叠加且与 weak 叠乘（0.35），weak 在角色空窗期暂停并在重建后保留剩余秒数", function()
    local char1 = make_character(10)
    local pt, clock = spawn_with_effects({
      character = char1,
      data_overrides = { weak_remaining = 40 },
    })

    assert.is_true(pt.states.is_weak:now())
    assert.near(40, pt:get_modifier_remaining("weak"), 1e-9)
    assert.near(0.5, pt.memos.move_multiplier:now(), 1e-9)

    -- 叠加 frost（30% 减速）→ 0.5 * 0.7 = 0.35；重复施加 frost 不叠加只刷新
    assert.is_true(pt:apply_modifier("frost"))
    assert.near(0.35, pt.memos.move_multiplier:now(), 1e-9)
    assert.near(3.5, pt.memos.walk_speed:now(), 1e-9)
    clock:advance(1)
    assert.is_true(pt:apply_modifier("frost"))
    assert.equals(1, pt:get_modifier_stacks("frost"))
    assert.near(0.35, pt.memos.move_multiplier:now(), 1e-9)

    -- 角色销毁空窗：清除非持久 frost，冻结 weak 剩余 39 秒不继续流失
    pt.states.character:set(nil)
    assert.equals(0, pt:get_modifier_remaining("frost"))
    assert.near(39, pt:get_modifier_remaining("weak"), 1e-9)

    clock:advance(20)
    assert.near(39, pt:get_modifier_remaining("weak"), 1e-9)

    -- 角色重建：恢复 weak 倒计时，5 秒后剩余 34 秒
    pt.states.character:set(make_character(10))
    clock:advance(5)
    assert.near(34, pt:get_modifier_remaining("weak"), 1e-9)

    -- 再走 34 秒到期恢复正常移速
    clock:advance(34)
    assert.equals(0, pt:get_modifier_remaining("weak"))
    assert.is_false(pt.states.is_weak:now())
    assert.equals(1, pt.memos.move_multiplier:now())
    assert.near(10, pt.memos.walk_speed:now(), 1e-9)

    pt:dispose()
  end)
end)

describe("HeldRodLeaf：左手持竿外观纯输出与 on_cleanup 对称销毁", function()
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

  it("持竿/切换手持/角色重建/dispose 均对称创建并逆序销毁模型与挂点，模型失败自动回滚挂点", function()
    local created = {}
    local destroyed = {}
    local fail_model = false

    local function create_unit(unit_type, props)
      if fail_model and unit_type == "WorldUnit" then
        error("mock-model-fail")
      end
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

    -- 代理角色（模拟引擎 userdata 成员访问）
    local char1 = setmetatable({}, { __index = { Name = "ProxyChar1" } })
    local char2 = setmetatable({}, { __index = { Name = "ProxyChar2" } })
    local character_state = State.new("character", char1)
    local item_state = State.new("held_visual_item_id", GameCfg.Items.Id.StarterRod)

    local fake_tree = {
      user_id = 8801,
      states = { character = character_state },
      memos = { held_visual_item_id = item_state },
    }

    local errors = {}
    local root = Effect.new("HeldRodTestRoot", function(s)
      HeldRodLeaf.mount(s, fake_tree, {
        create_unit = create_unit,
        on_error = function(msg) errors[#errors + 1] = msg end,
      })
    end)
    local tree = SpokeTree.spawn("HeldRodTestTree", root)

    -- 首帧创建挂点 + 模型
    assert.equals(2, #created)
    assert.equals("SkeletalSocketMount", created[1].Type)
    assert.equals("HeldRodMount_8801", created[1].Props.Name)
    assert.equals(char1, created[1].Props.Parent)
    assert.equals("WorldUnit", created[2].Type)
    assert.equals("HeldRod_8801", created[2].Props.Name)
    assert.equals(created[1], created[2].Props.Parent)
    assert.same({}, destroyed)

    -- 角色重建：逆序销毁旧模型与旧挂点，再为新角色创建新实例
    character_state:set(char2)
    assert.same({ "HeldRod_8801", "HeldRodMount_8801" }, destroyed)
    assert.equals(4, #created)
    assert.equals(char2, created[3].Props.Parent)

    -- 卸下手持：销毁当前模型与挂点，不新建
    item_state:set(nil)
    assert.equals(4, #destroyed)
    assert.equals(4, #created)

    -- 模型创建失败时自动回滚已建挂点并上报错误
    fail_model = true
    item_state:set(GameCfg.Items.Id.StarterRod)
    assert.equals(5, #created)
    assert.equals(5, #destroyed)
    assert.equals("HeldRodMount_8801", destroyed[5])
    assert.equals(1, #errors)

    -- 恢复正常后重新持竿，并在 tree:dispose() 时彻底销毁零残留
    fail_model = false
    item_state:set(nil)
    item_state:set(GameCfg.Items.Id.StarterRod)
    assert.equals(7, #created)
    local before_dispose = #destroyed
    tree:dispose()
    assert.equals(before_dispose + 2, #destroyed)
    assert.equals("HeldRod_8801", destroyed[#destroyed - 1])
    assert.equals("HeldRodMount_8801", destroyed[#destroyed])
  end)

  it("resolve_visual_item_id 优先鱼竿，其次带 Visual.Socket 的手持武器", function()
    local rod_id = GameCfg.Items.Id.StarterRod
    local bar = { [1] = { itemId = rod_id, count = 1 } }
    assert.equals(rod_id, HeldRodLeaf.resolve_visual_item_id({ kind = nil }, 1, bar))
    assert.equals(rod_id, HeldRodLeaf.resolve_visual_item_id({ kind = "slot", slot = 1 }, nil, bar))
    assert.is_nil(HeldRodLeaf.resolve_visual_item_id({ kind = "slot", slot = 2 }, 1, bar))
  end)
end)
