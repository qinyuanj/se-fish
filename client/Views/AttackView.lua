-- 攻击与伤害反馈投影（#300）：订阅只读道具栏、HUD 显隐与服务端事件。
-- 攻击键只在持有武器且 HUD 可见时存在；关闭、死亡或根节点销毁由视图树逆序清掉节点与连接。

local GameCfg = require("common.GameCfg")
local PressGesture = require("client.PressGesture")
local spoke = require("common.packages.spoke.api")
local State = spoke.State
local MainHudLayout = require("client.MainHudLayout")
local AttackView = {}

local HINTS = {
  ["cannot-act"] = "现在不能攻击",
  unavailable = "武器未就绪",
  cooldown = "出手太快",
  reloading = "换弹中",
  empty = "弹匣已空，自动换弹",
  ["not-a-gun"] = "手持的不是枪械",
  ["mag-full"] = "弹匣是满的",
  ["bad-slot"] = "格子不存在",
  ["bad-throwable"] = "这个不能投掷",
  ["bad-target"] = "落点无效",
  ["bad-weapon"] = "武器未配置",
  ["bad-aim"] = "瞄准无效",
}

local function equipped(item_bar)
  if type(item_bar) ~= "table" then return nil end
  local weapons = type(item_bar.weapons) == "table" and item_bar.weapons or {}
  local held = item_bar.held
  if type(held) == "table" and held.kind == "weapon" and (weapons[held.id] or 0) > 0 then
    return held.id
  end
  local selected = item_bar.selectedWeapon
  if selected and (weapons[selected] or 0) > 0 then return selected end
  return nil
end

local function is_gun(weapon_id)
  return weapon_id ~= nil and GameCfg.Ability.Guns[weapon_id] ~= nil
end

local function resolution_of(services)
  local value = services and services.resolution
  if type(value) == "function" then value = value() end
  if type(value) == "table" and type(value.x) == "number" and type(value.y) == "number" then
    return value
  end
  return { x = 1920, y = 1080 }
end

local function attack_rect(services)
  local resolution = resolution_of(services)
  local layout = MainHudLayout.Compute({
    width = resolution.x,
    height = resolution.y,
    slots = 1,
  })
  return layout and layout.Rects and layout.Rects.AttackControl or { x = 1690, y = 430, w = 160, h = 160 }
end

local function color(rgba)
  if Color then return Color.New(rgba[1], rgba[2], rgba[3], rgba[4] or 255) end
  return rgba
end

function AttackView.mount(scope, ctx)
  local services = ctx.services or {}
  local active = scope:memo("AttackVisible", function(ms)
    return ms:d(ctx.store.hud_visible) ~= false and equipped(ms:d(ctx.store.item_bar)) ~= nil
  end)

  scope:phase("AttackButton", active, function(ps)
    local rect = attack_rect(services)
    local screen = ctx.root_node and ctx.root_node.FindFirstChild and ctx.root_node:FindFirstChild("ScreenMain", true)
    local control = ctx.create_node(ps, "EUILayout", {
      Name = "AttackControl",
      Parent = screen or nil,
      Position = Vector2 and Vector2.New(rect.x, rect.y) or { x = rect.x, y = rect.y },
      Size = Vector2 and Vector2.New(rect.w, rect.h) or { x = rect.w, y = rect.h },
    })
    control.TouchEnabled = false
    control.Visible = true
    local button = ctx.create_node(ps, "EUIButton", {
      Name = "BtnAttack",
      Parent = control,
      Position = Vector2 and Vector2.New(rect.x, rect.y) or { x = rect.x, y = rect.y },
      Size = Vector2 and Vector2.New(rect.w, rect.h) or { x = rect.w, y = rect.h },
      ButtonText = "",
    })
    button.TouchEnabled = false
    button.Visible = true
    local screen_open = ctx.store.hud_visible
    ps:effect("AttackEnabled", function(es)
      button.TouchEnabled = es:d(screen_open) == true
    end)
    local label = ctx.create_node(ps, "EUITextLabel", {
      Name = "AttackLabel",
      Parent = control,
      Position = button.Position,
      Size = button.Size,
      Text = "攻击",
    })
    label.TouchEnabled = false

    ps:effect("AttackCaption", function(es)
      local weapon_id = equipped(es:d(ctx.store.item_bar))
      label.Text = is_gun(weapon_id) and "射击" or "攻击"
    end)

    local pressing = false
    local auto_fired = false
    local next_auto = 0
    local gesture = PressGesture.New({ LongPressSec = GameCfg.Ability.Throw.LongPressSec })
    local function current_now()
      if type(services.now) == "function" then
        local ok, value = pcall(services.now)
        if ok and type(value) == "number" then return value end
      end
      local ok, world = pcall(function() return game:GetService("World") end)
      if ok and world and type(world.GetServerTime) == "function" then
        local ok_now, value = pcall(world.GetServerTime, world)
        if ok_now and type(value) == "number" then return value end
      end
      return 0
    end
    local function current_gun()
      local weapon_id = equipped(ctx.store.item_bar:now())
      return weapon_id and GameCfg.Ability.Guns[weapon_id] or nil
    end
    local function send(action)
      if type(services.send_weapon) ~= "function" then return end
      local payload = { action = action }
      if action == "attack" and type(services.aim_direction) == "function" then
        local ok, direction = pcall(services.aim_direction)
        if ok and type(direction) == "table" then payload.aim = direction end
      end
      services.send_weapon(payload)
    end
    local function tick()
      if not pressing then return end
      local t = current_now()
      gesture:Update(t)
      local gun = current_gun()
      if gun and gun.Auto and t >= next_auto then
        next_auto = t + (gun.IntervalSec or 0.2)
        auto_fired = true
        send("attack")
      end
    end
    if button.OnTouchBegan and button.OnTouchEnded then
      ctx.connect(ps, button.OnTouchBegan, function()
        pressing = true
        auto_fired = false
        next_auto = 0
        gesture:Begin(current_now())
      end)
      ctx.connect(ps, button.OnTouchEnded, function()
        pressing = false
        local result = gesture:End(current_now())
        if result == "tap" then
          if not auto_fired then send("attack") end
        elseif result == "long" then
          local gun = current_gun()
          if gun and not gun.Auto then send("reload") end
        end
      end)
      local ok_run, run_service = pcall(function() return game:GetService("RunService") end)
      if ok_run and run_service and run_service.Heartbeat then
        ctx.connect(ps, run_service.Heartbeat, tick)
      end
    else
      ctx.connect(ps, button.OnClicked, function() send("attack") end)
    end
  end)

  local damage_notice = State.new("AttackView.damage_notice", nil)
  scope:subscribe(ctx.store.on_server_event, function(event)
    if type(event) ~= "table" then return end
    if event.channel == "WeaponResult" then
      local payload = event.payload
      if type(payload) == "table" and payload.ok == false and type(services.notify) == "function" then
        services.notify(HINTS[payload.reason] or ("武器操作失败 " .. tostring(payload.reason)))
      end
    elseif event.channel == "DamageNotice" and type(event.payload) == "table" then
      local amount = tonumber(event.payload.amount)
      if amount == nil or amount ~= amount or math.abs(amount) == math.huge then return end
      damage_notice:set({
        amount = math.floor(amount + 0.5),
        critical = event.payload.critical == true,
        seq = (damage_notice:now() and damage_notice:now().seq or 0) + 1,
      })
    end
  end)

  scope:effect("DamageFloat", function(es)
    local notice = es:d(damage_notice)
    if type(notice) ~= "table" then return end
    local node = ctx.create_node(es, "EUITextLabel", {
      Name = "DamageFloat",
      Text = tostring(notice.amount),
      Position = Vector2 and Vector2.New(0, 0) or { x = 0, y = 0 },
      Size = Vector2 and Vector2.New(120, 40) or { x = 120, y = 40 },
    })
    node.TextColor = color(notice.critical and { 255, 214, 74, 255 } or { 255, 255, 255, 255 })
    node.TouchEnabled = false
    node.Visible = true
  end)
end

function AttackView.spec()
  return {
    name = "Attack",
    mount = function(scope, ctx)
      AttackView.mount(scope, ctx)
    end,
  }
end

return AttackView
