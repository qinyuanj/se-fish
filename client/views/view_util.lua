
local Number = require("common.number")

local ViewUtil = {}

function ViewUtil.is_record(value)
  local kind = type(value)
  return kind == "table" or kind == "userdata"
end

function ViewUtil.read_vec2(value)
  if not ViewUtil.is_record(value) then
    return nil
  end
  local ok, x, y = pcall(function() return value.x, value.y end) -- 兼容引擎 Vector2 userdata 坐标读取
  if ok and Number.is_finite_number(x) and Number.is_finite_number(y) then
    return x, y
  end
  return nil
end

function ViewUtil.read_vec3(value)
  if not ViewUtil.is_record(value) then
    return nil
  end
  local ok, x, y, z = pcall(function() return value.x, value.y, value.z end) -- 兼容引擎 Vector3 userdata 坐标读取
  if ok and Number.is_finite_number(x) and Number.is_finite_number(y) and Number.is_finite_number(z) then
    return x, y, z
  end
  return nil
end

function ViewUtil.distance_sq_xz(a, b)
  local ax, _, az = ViewUtil.read_vec3(a)
  local bx, _, bz = ViewUtil.read_vec3(b)
  if ax == nil or bx == nil then
    return nil
  end
  local dx = ax - bx
  local dz = az - bz
  return dx * dx + dz * dz
end

function ViewUtil.distance_sq_xyz(a, b)
  local ax, ay, az = ViewUtil.read_vec3(a)
  local bx, by, bz = ViewUtil.read_vec3(b)
  if ax == nil or bx == nil then
    return nil
  end
  local dx = ax - bx
  local dy = ay - by
  local dz = az - bz
  return dx * dx + dy * dy + dz * dz
end

local function valid_resolution(raw)
  local x, y = ViewUtil.read_vec2(raw)
  if x ~= nil and y ~= nil and x > 0 and y > 0 then
    return { x = x, y = y }
  end
  return nil
end

local function try_read_res(label, fn)
  local ok, raw = pcall(fn)
  if ok then return valid_resolution(raw) end
  print("[ViewUtil] 读取分辨率失败", label, tostring(raw))
  return nil
end
function ViewUtil.get_resolution(ctx, options)
  if type(options) == "table" and type(options.get_resolution) == "function" then
    local resolved = try_read_res("options.get_resolution", options.get_resolution)
    if resolved ~= nil then return resolved end
  end

  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" then
    if type(services.get_device_resolution) == "function" then
      local resolved = try_read_res("services.get_device_resolution", services.get_device_resolution)
      if resolved ~= nil then return resolved end
    end
    local fallback_res = services.resolution
    local resolved = type(fallback_res) == "function" and try_read_res("services.resolution", fallback_res) or valid_resolution(fallback_res)
    if resolved ~= nil then return resolved end
  end

  if game ~= nil then
    local ok, raw = pcall(function() -- 宿主 EUI 管理器未就绪或分辨率接口异常时记录并返回 nil
      local players = game:GetService("Players")
      -- 优先通过本地玩家读取宿主 EuiManager
      -- 若不可用则记日志返回 nil
      -- 不再回退 1920x1080
      local lp = players and players.LocalPlayer
      local eui_mgr = lp and lp.PlayerGui and lp.PlayerGui.EuiManager or nil
      return eui_mgr and eui_mgr:GetDeviceResolution() or nil
    end)
    if not ok then
      print("[ViewUtil] 读取宿主 EUI 分辨率失败", tostring(raw))
    else
      local resolved = valid_resolution(raw)
      if resolved ~= nil then return resolved end
    end
  end
  print("[ViewUtil] 未获取到有效设备分辨率，返回 nil")
  return nil
end

function ViewUtil.wrap_text(text, columns)
  local limit = math.max(1, math.floor(tonumber(columns) or 1))
  local out, count = {}, 0
  for character in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if character == "\n" then
      out[#out + 1] = character
      count = 0
    else
      if count >= limit then
        out[#out + 1] = "\n"
        count = 0
      end
      out[#out + 1] = character
      count = count + 1
    end
  end
  return table.concat(out)
end

function ViewUtil.notify(ctx, text)
  if text == nil or text == "" then
    return
  end
  local fn = type(ctx) == "table" and ctx.services and ctx.services.notify or nil
  if type(fn) == "function" then
    fn(text)
  end
end

function ViewUtil.vec2(x, y)
  if Vector2 ~= nil and type(Vector2.New) == "function" then
    return Vector2.New(x, y)
  end
  return { x = x, y = y }
end

function ViewUtil.color(rgba)
  if Color ~= nil and type(Color.New) == "function" then
    return Color.New(rgba[1], rgba[2], rgba[3], rgba[4] or 255)
  end
  return rgba
end

function ViewUtil.create_anchor_scene_node(scope, ctx, entry, height, kind, fallback_name)
  local services = type(ctx) == "table" and ctx.services or nil
  local create_scene = services and (services.create_anchor_scene_node or services.create_scene_node)
  local node
  if type(create_scene) == "function" then
    node = ctx.own_node(scope, create_scene(entry, height, kind))
  else
    node = ctx.create_node(scope, "EUIImage", {
      Name = fallback_name,
      Visible = true,
    })
  end
  if node ~= nil and node.Name == nil then
    node.Name = fallback_name
  end
  return node
end

function ViewUtil.resolve_clock(ctx, label, override_now)
  if type(override_now) == "function" then
    return override_now
  end
  local services = type(ctx) == "table" and ctx.services or nil
  if type(services) == "table" and type(services.now) == "function" then
    return services.now
  end
  local clock = type(ctx) == "table" and ctx.clock or nil
  if type(clock) == "table" and type(clock.now) == "function" then
    return clock.now
  end
  error("[" .. tostring(label or "ViewUtil") .. "] 缺少注入时钟（services.now 或 ctx.clock.now）", 3)
end

function ViewUtil.read_now(clock_now, label)
  local ok, value = pcall(clock_now)
  if ok and Number.is_finite_number(value) then
    return value
  end
  print("[" .. tostring(label or "ViewUtil") .. "] 读取时钟失败", tostring(value))
  return nil
end

return ViewUtil
