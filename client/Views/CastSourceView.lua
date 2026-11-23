-- 礁石来源鱼与钓线可视化（ADR-0032 / #302）。
-- 订阅统一 ClientStore，世界节点由 RootView 作用域托管，离开上钩态即销毁。
local GameCfg = require("common.GameCfg")
local CastSourceView = {}

local function point(value)
  local kind = type(value)
  if kind ~= "table" and kind ~= "userdata" then return false end
  for _, key in ipairs({ "x", "y", "z" }) do
    local ok, component = pcall(function() return value[key] end)
    if not ok or type(component) ~= "number" or component ~= component or math.abs(component) == math.huge then
      return false
    end
  end
  return true
end

local function vector(p)
  return Vector3.New(p.x, p.y, p.z)
end

local function create_world(ctx, kind, props)
  local services = ctx.services or {}
  if type(services.create_unit) == "function" then return services.create_unit(kind, props) end
  local ok, world = pcall(function() return game:GetService("World") end)
  if ok and world and type(world.CreateUnit) == "function" then return world:CreateUnit(kind, props) end
  return nil
end

function CastSourceView.spec()
  return {
    name = "CastSource",
    mount = function(scope, ctx)
      local body, line, current = nil, nil, nil
      local function clear()
        for _, unit in ipairs({ body, line }) do
          if unit and type(unit.Destroy) == "function" then pcall(unit.Destroy, unit) end
        end
        body, line, current = nil, nil, nil
      end
      local function character()
        local stored = ctx.store.local_character and ctx.store.local_character:now()
        if stored then return stored end
        local ok, player = pcall(function() return game:GetService("Players").LocalPlayer end)
        return ok and player and player.Character or nil
      end
      local function sync(state)
        local fish = type(state) == "table" and state.fishId and GameCfg.Fish[state.fishId] or nil
        local reel = ctx.services and ctx.services.reel
        local active = not reel or type(reel.active) ~= "function" or reel.active(state and state.reelSession)
        if not active or type(state) ~= "table" or state.phase ~= "hooked" or not fish
          or fish.ZoneId ~= "reefIsland" or type(state.castId) ~= "number" or not point(state.hookPosition) then
          clear()
          return
        end
        local key = tostring(state.castId) .. ":" .. tostring(state.fishId)
        if current == key then return end
        clear()
        current = key
        local p = state.hookPosition
        local ok, created = pcall(create_world, ctx, "WorldUnit", {
          Name = "CastSource_" .. tostring(state.castId), Position = vector(p),
          RenderMeshId = "official://mesh/" .. tostring(fish.Model), PhysicsActive = false, CanQuery = false,
          ModelColor1 = Color.New(fish.VisualColor[1], fish.VisualColor[2], fish.VisualColor[3], fish.VisualColor[4]),
        })
        if not ok or not created then
          current = nil
          print("[CastSourceView] 创建来源失败", tostring(created))
          return
        end
        -- 节点在 Effect 运行期间创建，cleanup 只在挂载时登记一次，避免封存 Epoch 变更。
        body = created
        local line_ok, created_line = pcall(create_world, ctx, "LinkEffectUnit", {
          Name = "CastSourceLine_" .. tostring(state.castId), EffectId = GameCfg.Casting.LineEffect,
          Position = vector(p), EndPosition = vector(p),
        })
        if line_ok and created_line then line = created_line end
      end
      scope:effect("CastSourceSync", function(es)
        sync(es:d(ctx.store.cast))
      end)
      scope:subscribe(ctx.clock.on_frame, function()
        if not body or not current then return end
        local target = character()
        local state = ctx.store.cast:now()
        if not point(target and target.Position) or type(state) ~= "table" or not point(state.hookPosition) then return end
        local reel = ctx.services and ctx.services.reel
        local progress = type(reel) == "table" and type(reel.progress) == "function" and reel.progress() or 50
        local t = math.min(1, math.max(0, ((progress or 50) - 50) / 50))
        local origin = state.hookPosition
        local destination = target.Position
        local p = Vector3.New(
          origin.x + (destination.x - origin.x) * t,
          origin.y + (destination.y + 2 - origin.y) * t,
          origin.z + (destination.z - origin.z) * t
        )
        local ok, err = pcall(function()
          body.Position = p
          if line then
            line.Position = Vector3.New(destination.x, destination.y + 1, destination.z)
            line.EndPosition = p
          end
        end)
        if not ok then
          print("[CastSourceView] 更新来源失败", tostring(err))
          clear()
        end
      end)
      scope:on_cleanup(clear)
    end,
  }
end

return CastSourceView
