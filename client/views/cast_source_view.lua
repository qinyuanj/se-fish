local EngineRead = require("common.engine_read")
local GameCfg = require("common.game_cfg")
local ViewUtil = require("client.views.view_util")

local CastSourceView = {}

local function vector(p) return Vector3.New(p.x, p.y, p.z) end

---@return any
local function create_world(ctx, kind, props)
  local services = ctx.services or {}
  if type(services.create_unit) == "function" then return services.create_unit(kind, props) end
  local ok_w, world = EngineRead.get_service("World", "CastSourceView.create_world")
  if ok_w and world ~= nil and type(world.CreateUnit) == "function" then
    local ok_c, created = pcall(function() return world:CreateUnit(kind, props) end)
    if ok_c then return created else print("[CastSourceView] operation=create_world", tostring(kind), tostring(created)) end
  end
  return nil
end

local function resolve_reef_hook(state, ctx)
  local fish = type(state) == "table" and state.fishId and GameCfg.Fish[state.fishId] or nil
  local reel = ctx.services and ctx.services.reel
  local active = not reel or type(reel.active) ~= "function" or reel.active(state and state.reelSession)
  if not active or type(state) ~= "table" or state.phase ~= "hooked" or not fish
    or fish.ZoneId ~= "reefIsland" or type(state.castId) ~= "number" or ViewUtil.read_vec3(state.hookPosition) == nil then
    return nil
  end
  return fish
end

function CastSourceView.spec()
  return {
    name = "CastSource",
    mount = function(scope, ctx)
      local active = scope:memo("CastSourceActive", function(ms)
        return resolve_reef_hook(ms:d(ctx.store.cast), ctx) ~= nil
      end)

      local function character()
        local stored = ctx.store.local_character and ctx.store.local_character:now()
        if stored then return stored end
        local ok_p, players = EngineRead.get_service("Players", "CastSourceView.character")
        if not ok_p then return nil end
        local ok_lp, player = EngineRead.read_field(players, "LocalPlayer", "CastSourceView.character")
        if not ok_lp then return nil end
        local ok_ch, ch = EngineRead.read_character(player, "CastSourceView.character")
        return ok_ch and ch or nil
      end

      scope:phase("CastSourceActivePhase", active, function(ps)
        local body, current = nil, nil
        local line ---@type any
        local function clear()
          for _, unit in ipairs({ body, line }) do
            if unit ~= nil then
              EngineRead.destroy_unit(unit, "CastSourceView.clear")
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
            RenderMeshId = "official://mesh/" .. tostring(fish.Model), PhysicsActive = false, CanQuery = false,
            ModelColor1 = Color.New(fish.VisualColor[1], fish.VisualColor[2], fish.VisualColor[3], fish.VisualColor[4]),
          })
          if not ok or not created then
            current = nil
            print("[CastSourceView] 创建来源失败", tostring(created))
            return
          end
          body = created
          local line_ok, created_line = pcall(create_world, ctx, "LinkEffectUnit", {
            Name = "CastSourceLine_" .. tostring(state.castId), EffectId = GameCfg.Casting.LineEffect,
            Position = vector(p), EndPosition = vector(p),
          })
          if line_ok and created_line then
            line = created_line
          elseif not line_ok then
            print("[CastSourceView] 创建钓线失败", tostring(created_line))
          end
        end

        ps:effect("CastSourceSync", function(es)
          sync(es:d(ctx.store.cast))
        end)

        ps:subscribe(ctx.clock.on_frame, function()
          if not body or not current then return end
          local target = character()
          local state = ctx.store.cast:now()
          local ok_tpos, tpos = EngineRead.read_position(target, "CastSourceView.on_frame")
          local dx, dy, dz = ViewUtil.read_vec3(ok_tpos and tpos or nil)
          local ox, oy, oz = ViewUtil.read_vec3(type(state) == "table" and state.hookPosition or nil)
          if dx == nil or ox == nil then return end
          local reel = ctx.services and ctx.services.reel
          local raw_progress = type(reel) == "table" and type(reel.progress) == "function" and reel.progress() or 50
          local progress = tonumber(raw_progress) or 50
          local t = math.min(1, math.max(0, (progress - 50) / 50)) ---@type number
          local ok_v, p = EngineRead.new_vector3(
            ox + (dx - ox) * t,
            oy + (dy + 2 - oy) * t,
            oz + (dz - oz) * t,
            "CastSourceView.on_frame"
          )
          if not ok_v then
            clear()
            return
          end
          local ok_b = EngineRead.write_field(body, "Position", p, "CastSourceView.on_frame")
          local ok_l = true
          if line then
            local ok_lv, line_pos = EngineRead.new_vector3(dx, dy + 1, dz, "CastSourceView.on_frame")
            if not ok_lv then
              ok_l = false
            else
              ok_l = EngineRead.write_field(line, "Position", line_pos, "CastSourceView.on_frame")
                and EngineRead.write_field(line, "EndPosition", p, "CastSourceView.on_frame")
            end
          end
          if not ok_b or not ok_l then
            print("[CastSourceView] 更新来源失败")
            clear()
          end
        end)

        ps:on_cleanup(clear)
      end)
    end,
  }
end

return CastSourceView
