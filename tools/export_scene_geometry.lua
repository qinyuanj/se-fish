-- 编辑态场景几何校验与只读数据表导出器（ADR-0013 / #406 / #409）。
-- 从活体编辑器按 ADR-0035 四条硬边界采集 7 区全部契约标记与 Z*_Water* 水域标记，
-- 执行全量契约校验（缺标记/重名/不在所属区/越界/尺寸或朝向非法/水域重叠均阻断报错），
-- 确定性导出只读 Lua 表：
--   common/cfg/scene_geometry.lua       （7 区边界墙与全部具名点位标记）
--   common/cfg/scene_water_geometry.lua （7 区 189 块可钓水域只读几何）
--
-- 用法（仓库根执行）：
--   lua tools/export_scene_geometry.lua           # 采集、校验并写入两张只读表
--   lua tools/export_scene_geometry.lua --check   # 采集、校验并与已提交只读表逐字节比对

local seam = require('tools.seam')

local M = {}
M.GEOMETRY_OUT = 'common/cfg/scene_geometry.lua'
M.WATER_OUT = 'common/cfg/scene_water_geometry.lua'
M.ZONE_NAMES = { '01 鱼塘', '02 虾池', '03 蟹湖', '04 树林岛', '05 沙滩岛', '06 礁石岛', '07 火山岛' }

local function finite(v)
    return type(v) == 'number' and v == v and math.abs(v) < math.huge
end

local function round4(v)
    local r = math.floor(v * 10000 + 0.5) / 10000
    if r == 0 then return 0 end
    return r
end

local function fmt_num(v)
    local r = round4(v)
    if r == math.floor(r) then
        return string.format('%d', r)
    end
    local s = string.format('%.4f', r):gsub('0+$', ''):gsub('%.$', '')
    if s == '-0' then return '0' end
    return s
end

local function water_order(name, prefix)
    local suffix = name:sub(#prefix + 1)
    if suffix == '' then return 0 end
    return suffix:match('^%d+$') and tonumber(suffix) or nil
end

local function check_vec3(v, label, name)
    if type(v) ~= 'table' or not finite(v.x) or not finite(v.y) or not finite(v.z) then
        error('区域标记' .. label .. '非法: ' .. tostring(name), 0)
    end
    return { x = round4(v.x), y = round4(v.y), z = round4(v.z) }
end

local function check_size(v, name)
    local s = check_vec3(v, '尺寸', name)
    if s.x <= 0 or s.y <= 0 or s.z <= 0 then
        error('区域标记尺寸非法: ' .. tostring(name), 0)
    end
    return s
end

local function inside_bounds(b, p)
    return p.x > b.MinX and p.x < b.MaxX and p.z > b.MinZ and p.z < b.MaxZ
end

local function overlaps(a, b)
    return math.abs(a.cx - b.cx) < (a.hx + b.hx) and math.abs(a.cz - b.cz) < (a.hz + b.hz)
end

--- 解析编辑态导出的标记行数组。
--- 每行格式：ZONE|<zone_name> 或 ITEM|<zone_name>|<name>|<px>|<py>|<pz>|<sx>|<sy>|<sz>
function M.parse_editor_lines(lines)
    local raw = { zone_counts = {}, items = {} }
    for _, line in ipairs(lines or {}) do
        local zname = line:match('SCENE_EXPORT_ZONE|([^\r\n]+)$')
        if zname then
            raw.zone_counts[zname] = (raw.zone_counts[zname] or 0) + 1
        else
            local zn, name, px, py, pz, sx, sy, sz = line:match(
                'SCENE_EXPORT_ITEM|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|\r\n]+)$'
            )
            if zn and name then
                raw.items[#raw.items + 1] = {
                    zone = zn,
                    name = name,
                    pos = { x = tonumber(px), y = tonumber(py), z = tonumber(pz) },
                    size = { x = tonumber(sx), y = tonumber(sy), z = tonumber(sz) },
                }
            end
        end
    end
    return raw
end

--- 严格校验原始场景标记并构建标准化导出结构；任意缺标记/重名/越界/非法尺寸/水域重叠直接报错。
function M.validate_and_build(raw, cfg)
    if type(raw) ~= 'table' or type(raw.items) ~= 'table' then
        error('导出器输入无效: 缺少 items 列表', 0)
    end
    cfg = cfg or require('common.game_cfg')
    local ZoneMarkers = require('common.zone_markers')
    local contract = ZoneMarkers.contract(cfg)

    -- 1. 校验 7 个区域目录存在且唯一
    local zone_index_by_name = {}
    for index, zname in ipairs(M.ZONE_NAMES) do
        zone_index_by_name[zname] = index
        local zc = (raw.zone_counts and raw.zone_counts[zname]) or 0
        if zc == 0 then error('区域目录缺失: ' .. zname, 0) end
        if zc > 1 then error('区域目录重名: ' .. zname .. ' x' .. zc, 0) end
    end

    -- 2. 全图名字频次统计 & 按区归类
    local global_counts = {}
    local zones_raw = {}
    for index = 1, #M.ZONE_NAMES do
        zones_raw[index] = { by_name = {}, waters = {} }
    end

    for _, item in ipairs(raw.items) do
        if type(item.name) ~= 'string' or item.name == '' then
            error('导出器发现空名标记', 0)
        end
        if item.name:find("['\"\\\r\n]") then
            error('导出器发现非法标记名字符: ' .. item.name, 0)
        end
        global_counts[item.name] = (global_counts[item.name] or 0) + 1
        local zidx = zone_index_by_name[item.zone]
        local water_znum = tonumber(item.name:match('^Z(%d+)_Water%d*$'))
        if water_znum and water_znum ~= zidx then
            error('水域标记不在所属区: ' .. tostring(item.zone) .. '/' .. item.name, 0)
        end
        if zidx then
            local zr = zones_raw[zidx]
            zr.by_name[item.name] = item
            local prefix = 'Z' .. zidx .. '_Water'
            if item.name:sub(1, #prefix) == prefix and water_order(item.name, prefix) then
                zr.waters[#zr.waters + 1] = item
            end
        end
    end

    local function require_unique(name)
        local c = global_counts[name] or 0
        if c == 0 then error('区域标记缺失: ' .. name, 0) end
        if c > 1 then error('区域标记重名: ' .. name .. ' x' .. c, 0) end
    end

    local function require_unit(zone_index, name)
        require_unique(name)
        local item = zones_raw[zone_index].by_name[name]
        if not item then
            error('区域标记不在所属区: ' .. M.ZONE_NAMES[zone_index] .. '/' .. name, 0)
        end
        return item
    end

    -- 3. 按区校验边界、点位与水域
    local baked_zones = {}
    local baked_waters = {}
    local all_water_boxes = {}

    -- 按区归集契约中的非边界点位
    local point_names_by_zone = {}
    for index = 1, #M.ZONE_NAMES do point_names_by_zone[index] = {} end
    for _, entry in ipairs(contract) do
        if entry.role ~= 'Boundary' then
            local list = point_names_by_zone[entry.zone_index]
            list[#list + 1] = entry.Name
        end
    end
    for index = 1, #M.ZONE_NAMES do
        table.sort(point_names_by_zone[index])
    end

    for index, zname in ipairs(M.ZONE_NAMES) do
        local prefix = 'Z' .. index .. '_'
        -- 边界四面墙
        local boundary_walls = {}
        for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
            local wname = prefix .. 'Boundary' .. side
            local u = require_unit(index, wname)
            local p = check_vec3(u.pos, '坐标', wname)
            local s = check_size(u.size, wname)
            boundary_walls[side] = { x = p.x, y = p.y, z = p.z, sx = s.x, sy = s.y, sz = s.z }
        end
        local west, east = boundary_walls.West, boundary_walls.East
        local south, north = boundary_walls.South, boundary_walls.North
        if west.x >= east.x or south.z >= north.z then
            error('区域边界方向非法: ' .. zname, 0)
        end
        if west.sx >= west.sz or east.sx >= east.sz
            or south.sz >= south.sx or north.sz >= north.sx then
            error('区域边界墙朝向非法: ' .. zname, 0)
        end
        local bounds = { MinX = west.x, MaxX = east.x, MinZ = south.z, MaxZ = north.z }

        -- 点位标记
        local points = {}
        local seen_pt = {}
        for _, pname in ipairs(point_names_by_zone[index]) do
            if not seen_pt[pname] then
                seen_pt[pname] = true
                local u = require_unit(index, pname)
                local p = check_vec3(u.pos, '坐标', pname)
                if not inside_bounds(bounds, p) then
                    error('区域标记越出本区边界: ' .. zname .. '/' .. pname, 0)
                end
                points[pname] = p
            end
        end

        -- 水域标记
        local waters = zones_raw[index].waters
        if #waters == 0 then
            error('区域水域缺失: ' .. zname, 0)
        end
        local wprefix = prefix .. 'Water'
        table.sort(waters, function(a, b)
            return water_order(a.name, wprefix) < water_order(b.name, wprefix)
        end)
        local zw_out = {}
        for _, wu in ipairs(waters) do
            require_unique(wu.name)
            local p = check_vec3(wu.pos, '坐标', wu.name)
            local s = check_size(wu.size, wu.name)
            if not inside_bounds(bounds, p) then
                error('区域水域越出本区边界: ' .. wu.name, 0)
            end
            local box = { name = wu.name, cx = p.x, cz = p.z, hx = s.x / 2, hz = s.z / 2 }
            for _, other in ipairs(all_water_boxes) do
                if overlaps(box, other) then
                    error('区域水域重叠: ' .. wu.name .. ' / ' .. other.name, 0)
                end
            end
            all_water_boxes[#all_water_boxes + 1] = box
            zw_out[#zw_out + 1] = { wu.name, p.x, p.y, p.z, s.x, s.y, s.z }
        end

        baked_zones[index] = {
            name = zname,
            boundary = boundary_walls,
            points = points,
            point_order = point_names_by_zone[index],
        }
        baked_waters[index] = zw_out
    end

    return { zones = baked_zones, waters = baked_waters }
end

function M.render_geometry_lua(baked)
    local out = {
        '-- 由 tools/export_scene_geometry.lua 从编辑态场景标记自动校验导出，禁止手改（ADR-0013）。',
        'return {',
        '    schema_version = 1,',
        '    zones = {',
    }
    for index, z in ipairs(baked.zones) do
        out[#out + 1] = string.format("        [%d] = { name = '%s',", index, z.name)
        out[#out + 1] = '            boundary = {'
        for _, side in ipairs({ 'West', 'East', 'South', 'North' }) do
            local w = z.boundary[side]
            out[#out + 1] = string.format(
                '                %s = { x = %s, y = %s, z = %s, sx = %s, sy = %s, sz = %s },',
                side, fmt_num(w.x), fmt_num(w.y), fmt_num(w.z), fmt_num(w.sx), fmt_num(w.sy), fmt_num(w.sz)
            )
        end
        out[#out + 1] = '            },'
        out[#out + 1] = '            points = {'
        local seen = {}
        for _, pname in ipairs(z.point_order) do
            if not seen[pname] then
                seen[pname] = true
                local p = z.points[pname]
                out[#out + 1] = string.format(
                    '                %s = { x = %s, y = %s, z = %s },',
                    pname, fmt_num(p.x), fmt_num(p.y), fmt_num(p.z)
                )
            end
        end
        out[#out + 1] = '            },'
        out[#out + 1] = '        },'
    end
    out[#out + 1] = '    },'
    out[#out + 1] = '}'
    out[#out + 1] = ''
    return table.concat(out, '\n')
end

function M.render_water_lua(baked)
    local out = {
        '-- 由 tools/export_scene_geometry.lua 从编辑态场景标记自动校验导出，禁止手改（ADR-0013）。',
        '-- 每项：{ name, x, y, z, sx, sy, sz }（Position 与 Size，水面 SurfaceY = y + sy）',
        'return {',
        '    schema_version = 1,',
        '    zones = {',
    }
    for index, list in ipairs(baked.waters) do
        out[#out + 1] = string.format('        [%d] = {', index)
        for _, w in ipairs(list) do
            out[#out + 1] = string.format(
                "            { '%s', %s, %s, %s, %s, %s, %s },",
                w[1], fmt_num(w[2]), fmt_num(w[3]), fmt_num(w[4]), fmt_num(w[5]), fmt_num(w[6]), fmt_num(w[7])
            )
        end
        out[#out + 1] = '        },'
    end
    out[#out + 1] = '    },'
    out[#out + 1] = '}'
    out[#out + 1] = ''
    return table.concat(out, '\n')
end

local function editor_cli_path()
    local home = os.getenv('USERPROFILE') or os.getenv('HOME') or ''
    local candidate = seam.normalize(home) .. '/' .. seam.EDITOR_CLI_REL
    if seam.exists(candidate) then return candidate end
    local found = seam.which('editor-cli')
    if found then return found end
    error('找不到 editor-cli 可执行文件: ' .. candidate, 0)
end

-- 生成符合 ADR-0035 四条硬边界的只读编辑态采集脚本
local function build_editor_probe_lua(tag)
    return string.format([=[
local TAG = %q
local World = editor:GetService("World")
local zones = { "01 鱼塘", "02 虾池", "03 蟹湖", "04 树林岛", "05 沙滩岛", "06 礁石岛", "07 火山岛" }
local zone_set = {}
for _, zn in ipairs(zones) do zone_set[zn] = true end

local function safe_prop(u, k)
  local ok, v = pcall(function() return u:GetProperty(k) end)
  return ok and v or nil
end
local function safe_name(u)
  local ok, n = pcall(function() return u:GetProperty("Name") end)
  if ok and n then return tostring(n) end
  ok, n = pcall(function() return u.Name end)
  return (ok and n) and tostring(n) or ""
end
local function safe_parent(u)
  local ok, p = pcall(function() return u:GetParent() end)
  if ok and p then return p end
  ok, p = pcall(function() return u.Parent end)
  return ok and p or nil
end
local function vec3_xyz(v)
  if not v then return nil end
  local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
  if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
  local ok2, a, b, c = pcall(function() return v[1], v[2], v[3] end)
  if ok2 and type(a) == "number" and type(b) == "number" and type(c) == "number" then return a, b, c end
  return nil
end
local function find_zone_name(u)
  local cur = u
  local depth = 0
  while cur and depth < 25 do
    local n = safe_name(cur)
    if zone_set[n] then return n end
    if n == "World" then return "-" end
    cur = safe_parent(cur)
    depth = depth + 1
  end
  return "-"
end

for _, f in ipairs(World:GetUnitsByUnitType("Folder") or {}) do
  local n = safe_name(f)
  if zone_set[n] then
    print(TAG .. " SCENE_EXPORT_ZONE|" .. n)
  end
end

local function emit_unit(u, unit_kind)
  local n = safe_name(u)
  if n:match("^Z%%d+_") then
    local zn = find_zone_name(u)
    if unit_kind == "TriggerUnit" then
      print(string.format("%%s SCENE_EXPORT_ERROR|%%s|发现已退役的TriggerUnit回流: %%s", TAG, zn, n))
      return
    end
    local px, py, pz = vec3_xyz(safe_prop(u, "Position"))
    local sx, sy, sz = vec3_xyz(safe_prop(u, "Size"))
    if px == nil or sx == nil then
      print(string.format("%%s SCENE_EXPORT_ERROR|%%s|属性Position/Size读取失败: %%s", TAG, zn, n))
      return
    end
    print(string.format("%%s SCENE_EXPORT_ITEM|%%s|%%s|%%.4f|%%.4f|%%.4f|%%.4f|%%.4f|%%.4f",
      TAG, zn, n, px, py, pz, sx, sy, sz))
  end
end
for _, u in ipairs(World:GetUnitsByUnitType("WorldUnit") or {}) do emit_unit(u, "WorldUnit") end
for _, u in ipairs(World:GetUnitsByUnitType("TriggerUnit") or {}) do emit_unit(u, "TriggerUnit") end
print(TAG .. " SCENE_EXPORT_DONE")
]=], tag)
end

function M.fetch_from_editor()
    local edcli = editor_cli_path()
    local tag = string.format('[EXPORT_GEOM_%d]', os.time())
    seam.ensure_dir('tmp')
    local probe_path = 'tmp/export_scene_geometry_probe.lua'
    local f = assert(io.open(probe_path, 'wb'))
    f:write(build_editor_probe_lua(tag))
    f:close()

    local code1, out1 = seam.capture({ argv = { edcli, 'exec', '--file', probe_path, '--expect-edit-mode' } })
    os.remove(probe_path)
    if code1 ~= 0 then
        error('编辑态采集脚本执行失败 (exit=' .. tostring(code1) .. '): ' .. tostring(out1), 0)
    end

    local code2, out2 = seam.capture({ argv = { edcli, 'log', 'grep', tag:sub(2, -2), '--max-matches', '1000' } })
    if code2 ~= 0 then
        error('读取编辑态采集日志失败 (exit=' .. tostring(code2) .. '): ' .. tostring(out2), 0)
    end

    local lines = {}
    local saw_done = false
    for line in out2:gmatch('[^\r\n]+') do
        if line:sub(1, 1) == '>' then
            local cleaned = line:gsub('"%s*$', '')
            local err_msg = cleaned:match('SCENE_EXPORT_ERROR|(.+)$')
            if err_msg then
                error('编辑态采集阻断: ' .. err_msg, 0)
            end
            if cleaned:find('SCENE_EXPORT_DONE', 1, true) then
                saw_done = true
            end
            lines[#lines + 1] = cleaned
        end
    end
    if not saw_done then
        error('编辑态采集日志未完整收到 SCENE_EXPORT_DONE 标记', 0)
    end
    return M.parse_editor_lines(lines)
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

local function write_file(path, text)
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
end

local function main(argv)
    local check = argv and argv[1] == '--check'
    local raw = M.fetch_from_editor()
    local baked = M.validate_and_build(raw)
    local geom_lua = M.render_geometry_lua(baked)
    local water_lua = M.render_water_lua(baked)

    local water_total = 0
    for _, list in ipairs(baked.waters) do water_total = water_total + #list end

    if check then
        local cur_geom = read_file(M.GEOMETRY_OUT)
        local cur_water = read_file(M.WATER_OUT)
        if cur_geom == geom_lua and cur_water == water_lua then
            print(string.format('只读几何导出表已同步：7 区、%d 块水域', water_total))
            return
        end
        print('只读几何导出表不同步：请运行 lua tools/export_scene_geometry.lua')
        os.exit(1)
    end

    write_file(M.GEOMETRY_OUT, geom_lua)
    write_file(M.WATER_OUT, water_lua)
    print(string.format('已导出只读几何表：7 区、%d 块水域 -> %s, %s', water_total, M.GEOMETRY_OUT, M.WATER_OUT))
end

if arg and arg[0] and arg[0]:find('export_scene_geometry', 1, true) then
    main(arg)
end

return M
