local game_cfg = require("common.game_cfg")
local view_util = require("client.views.view_util")

local cast_source_view = {}

local function vector(p)
  return Vector3.New(p.x, p.y, p.z)
end

local function create_world(ctx, kind, props)
  local services = ctx.services or {}
  if type(services.create_unit) == "function" then return services.create_unit(kind, props) end
  local ok, world = pcall(function() return game:GetService("World") end) -- 宿主 World 服务未就绪时安全回退
  if ok and world and type(world.CreateUnit) == "function" then return world:CreateUnit(kind, props) end
  return nil
end

local function resolve_reef_hook(state, ctx)
  local fish = type(state) == "table" and state.fishId and game_cfg.Fish[state.fishId] or nil
  local reel = ctx.services and ctx.services.reel
  local active = not reel or type(reel.active) ~= "function" or reel.active(state and state.reelSession)
  if not active or type(state) ~= "table" or state.phase ~= "hooked" or not fish
    or fish.ZoneId ~= "reefIsland" or type(state.castId) ~= "number" or view_util.read_vec3(state.hookPosition) == nil then
    return nil
  end
  return fish
end

function cast_source_view.spec()
  return {
    name = "CastSource",
    mount = function(scope, ctx)
      local active = scope:memo("CastSourceActive", function(ms)
        return resolve_reef_hook(ms:d(ctx.store.cast), ctx) ~= nil
      end)

      local function character()
        local stored = ctx.store.local_character and ctx.store.local_character:now()
        if stored then return stored end
        local ok, player = pcall(function() return game:GetService("Players").LocalPlayer end) -- 宿主 Players 服务未就绪时安全回退
        return ok and player and player.Character or nil
      end

      scope:phase("CastSourceActivePhase", active, function(ps)
        local body, line, current = nil, nil, nil
        local function clear()
          for _, unit in ipairs({ body, line }) do
            if unit and type(unit.Destroy) == "function" then
              pcall(unit.Destroy, unit) -- 世界单位可能已随场景销毁，忽略重复销毁异常
            end
          end
          body, line, current = nil, nil, nil
        end

        local function sync(state)
          local fish = resolve_reef_hook(state, ctx)
          if not fish then
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
            RenderMeshId = "official://mesh/" .. tostring(fish.model), PhysicsActive = false, CanQuery = false,
            ModelColor1 = Color.New(fish.VisualColor[1], fish.VisualColor[2], fish.VisualColor[3], fish.VisualColor[4]),
          })
          if not ok or not created then
            current = nil
            print("[cast_source_view] 创建来源失败", tostring(created))
            return
          end
          body = created
          local line_ok, created_line = pcall(create_world, ctx, "LinkEffectUnit", {
            Name = "CastSourceLine_" .. tostring(state.castId), EffectId = game_cfg.Casting.LineEffect,
            Position = vector(p), EndPosition = vector(p),
          })
          if line_ok and created_line then
            line = created_line
          elseif not line_ok then
            print("[cast_source_view] 创建钓线失败", tostring(created_line))
          end
        end

        ps:effect("CastSourceSync", function(es)
          sync(es:d(ctx.store.cast))
        end)

        ps:subscribe(ctx.clock.on_frame, function()
          if not body or not current then return end
          local target = character()
          local state = ctx.store.cast:now()
          local dx, dy, dz = view_util.read_vec3(target and target.Position)
          local ox, oy, oz = view_util.read_vec3(type(state) == "table" and state.hookPosition or nil)
          if dx == nil or ox == nil then return end
          local reel = ctx.services and ctx.services.reel
          local progress = type(reel) == "table" and type(reel.progress) == "function" and reel.progress() or 50
          local t = math.min(1, math.max(0, ((progress or 50) - 50) / 50))
          local p = Vector3.New(
            ox + (dx - ox) * t,
            oy + (dy + 2 - oy) * t,
            oz + (dz - oz) * t
          )
          local ok, err = pcall(function()
            body.Position = p
            if line then
              line.Position = Vector3.New(dx, dy + 1, dz)
              line.EndPosition = p
            end
          end)
          if not ok then
            print("[cast_source_view] 更新来源失败", tostring(err))
            clear()
          end
        end)

        ps:on_cleanup(clear)
      end)
    end,
  }
end

return cast_source_view
