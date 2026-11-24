-- 编辑器收尾：镜像落盘后执行 code validate --strict --json → （与编辑器有差异时）code push →
-- code diff 复核。validate 的判据是结构化 JSON（ok / data.valid / issues / warnings），不认文本。
-- 三端（client/common/server）里地图有、宿主没有的文件是本地已删的代码，用
-- code push --delete --yes 一并删掉；三端以外的地图独有文件（temp/ 等编辑器生成物）只提示、保留。
-- 两类同时出现时 --delete 分不开它们，失败关闭、不推送。push 之后仍不一致才报告尚未同步。
--
-- 本模块依赖正在运行的编辑器与宿主侧的 editor-cli.exe（位置由接缝层 tools.seam 从 USERPROFILE
-- 推导）。推导失败时报错并返回退出码 3；编辑器没装、宿主未绑定或地图未打开时打印跳过，磁盘镜像
-- 仍算完成，但不宣称编辑器内代码已同步。宿主必须有自己的 eggy.json，避免 CLI 向上下层目录寻找
-- 绑定而读到别的工程。
--
-- 子进程一律走 seam.spawn / seam.capture（argv 形式，不拼整条命令串，也不再有 wslpath）；
-- 需要读输出时用 capture，它内部把 stdout/stderr 重定向到临时文件再读回。
--
-- 纯解析部分（parse_changelist / map_only / split_map_only / behind_count）单独导出，可脱离编辑器测。
local dkjson = require("dkjson")
local seam = require("tools.seam")
local exit_code = require("tools.exit_code")
local plan = require("tools.deploy_plan")

local M = {}

-- 跑一条 code 子命令：argv 形式，--workspace 传 Windows 正斜杠路径（ws 由 eggy_workspace 给出）。
-- 必须给 --workspace：不给就按进程 cwd 找绑定，而 cwd 是仓库根。
-- 输出由 seam.capture 落临时文件再读回（接缝只认 argv，不拼命令串）。
local function editor_cli(exe, ws, args)
  local argv = { exe }
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  argv[#argv + 1] = "--workspace"
  argv[#argv + 1] = ws
  return seam.capture({ argv = argv })
end

-- `code validate --strict --json` 的结构化判据（#189）：ok=true、data.valid=true、
-- data.issues 与 warnings 均为空。返回 true 或 nil, 可读原因。
-- dkjson 解出的 JSON 空数组是「没有数组部分的 table」，JSON null 是 dkjson.null 哨兵。
local function empty_list(value)
  if value == nil or value == dkjson.null then return true end
  return type(value) == "table" and #value == 0
end

function M.validate_verdict(out)
  local body = out and out:match("%b{}")
  if not body then return nil, "输出里没有 JSON 对象" end
  local parsed, _, json_err = dkjson.decode(body, 1, nil)
  if type(parsed) ~= "table" then
    return nil, "JSON 解析失败: " .. tostring(json_err)
  end
  if parsed.ok ~= true then return nil, "ok 不是 true" end
  local data = parsed.data
  if type(data) ~= "table" then return nil, "缺 data 对象" end
  if data.valid ~= true then return nil, "data.valid 不是 true" end
  if not empty_list(data.issues) then
    return nil, "data.issues 非空: " .. dkjson.encode(data.issues)
  end
  local meta = parsed.meta
  if not empty_list(type(meta) == "table" and meta.warnings or nil) then
    return nil, "meta.warnings 非空: " .. dkjson.encode(meta.warnings)
  end
  if not empty_list(data.warnings) then
    return nil, "data.warnings 非空: " .. dkjson.encode(data.warnings)
  end
  return true
end

-- 解析 `code diff` 文本里的 changelist 行：
-- changelist: only-local=n differs=n only-on-map=n unchanged=n
function M.parse_changelist(out)
  local line = out:match("changelist:[^\r\n]*")
  if not line then return nil end
  local cl = {}
  for k, v in line:gmatch("([%w%-]+)=(%d+)") do cl[k] = tonumber(v) end
  return cl
end

-- 解析 `code diff` 文本里逐行列出的地图独有文件（`  only-on-map  <路径>`）。
-- 清单条数与 changelist 计数对不上时返回 nil, 原因：分不清删除候选就不能带 --delete 推送。
function M.map_only(out, cl)
  local paths = {}
  for line in out:gmatch("[^\r\n]+") do
    local path = line:match("^%s*only%-on%-map%s+(.-)%s*$")
    if path then paths[#paths + 1] = path end
  end
  local expected = cl["only-on-map"] or 0
  if #paths ~= expected then
    return nil, "code diff 的 only-on-map 计数 " .. expected .. " 与逐行清单 " .. #paths
      .. " 条对不上，分不清删除候选，未推送:\n" .. out
  end
  return paths
end

-- 按部署白名单把地图独有文件分成三端内（本仓库拥有，可删）与三端外（编辑器生成物，保留）。
function M.split_map_only(paths)
  local owned, foreign = {}, {}
  for _, path in ipairs(paths) do
    local realm = path:match("^([^/]+)/")
    local mine = false
    for _, r in ipairs(plan.REALMS) do
      if realm == r then mine = true end
    end
    if mine then owned[#owned + 1] = path else foreign[#foreign + 1] = path end
  end
  return owned, foreign
end

-- 落后编辑器的文件数：本地独有 + 两侧不同 + 三端内的地图独有（本地已删、待从地图删）。
function M.behind_count(cl, owned_map_only)
  return (cl["only-local"] or 0) + (cl["differs"] or 0) + (owned_map_only or 0)
end

-- 读一次 diff 输出：changelist 与三端内外的地图独有清单；任何一步读不出都返回 nil, 原因。
local function read_diff(out)
  local cl = M.parse_changelist(out)
  if not cl then return nil, "读不到 changelist" end
  local paths, err = M.map_only(out, cl)
  if not paths then return nil, err end
  local owned, foreign = M.split_map_only(paths)
  return { cl = cl, owned = owned, foreign = foreign }
end

-- 返回 true 表示收尾完成（含跳过）；失败返回 nil, 原因[, 3]——第三个值 exit_code.UNAVAILABLE 表示
-- 外部工具不可用（USERPROFILE 推导失败，推不出 editor-cli.exe），调用方据此退 3。
function M.run(ws)
  ws = seam.normalize(ws)
  local exe, err = seam.editor_cli()
  if not exe then
    return nil, "编辑器收尾失败: " .. tostring(err), exit_code.UNAVAILABLE
  end
  if not seam.exists(exe) then
    print("编辑器收尾跳过: 未找到 editor-cli.exe（" .. exe .. "）")
    return true
  end
  if not seam.exists(ws .. "/eggy.json") then
    print("编辑器收尾跳过: 宿主目录没有 eggy.json（" .. ws .. " 不是编辑器绑定的 Lua 工程）")
    return true
  end

  local code, out = editor_cli(exe, ws, { "code", "validate", "--strict", "--json" })
  local verdict, why = M.validate_verdict(out)
  if not verdict then
    return nil, "code validate --strict 未通过（退出码 " .. tostring(code) .. "）："
      .. tostring(why) .. "\n" .. out
  end
  print("validate: OK")

  code, out = editor_cli(exe, ws, { "code", "diff" })
  if not M.parse_changelist(out) then
    print("编辑器未打开该地图（diff 给不出 changelist），未校验编辑器内代码"
      .. "（磁盘已是最新）")
    return true
  end
  if out:find("channel=offline", 1, true) then
    print("编辑器没开该地图（diff 走的是离线地图目录），未校验编辑器内代码"
      .. "（磁盘已是最新）")
    return true
  end
  local d, derr = read_diff(out)
  if not d then return nil, derr end
  if #d.owned > 0 and #d.foreign > 0 then
    return nil, "地图独有文件里三端内 " .. #d.owned .. " 个、三端外 " .. #d.foreign
      .. " 个，code push --delete 会把三端外的一并删掉，未推送。三端外: "
      .. table.concat(d.foreign, ", ")
  end

  local dirty = M.behind_count(d.cl, #d.owned)
  if dirty > 0 then
    local push = #d.owned > 0 and { "code", "push", "--delete", "--yes" } or { "code", "push" }
    local pcode, pout = editor_cli(exe, ws, push)
    if pcode ~= 0 then
      return nil, "code push 失败（退出码 " .. tostring(pcode) .. "）:\n" .. pout
    end
    print("push: 已推送 " .. M.behind_count(d.cl) .. " 个本地新增或不同文件，删除地图上 "
      .. #d.owned .. " 个本地已删的三端文件")

    local dcode, dout = editor_cli(exe, ws, { "code", "diff" })
    if dcode ~= 0 then
      return nil, "code push 后 code diff 复核失败（退出码 " .. tostring(dcode) .. "）:\n" .. dout
    end
    if dout:find("channel=offline", 1, true) then
      return nil, "code push 后 code diff 走离线地图目录，无法确认编辑器内代码:\n" .. dout
    end
    local after, aerr = read_diff(dout)
    if not after then
      return nil, "code push 后" .. aerr .. "，无法确认编辑器内代码（退出码 "
        .. tostring(dcode) .. "）:\n" .. dout
    end
    local left = M.behind_count(after.cl, #after.owned)
    if left > 0 then
      return nil, "code push 后编辑器内仍有 " .. left .. " 个未同步文件"
        .. (#after.owned > 0 and ("（地图仍有本地已删的: " .. table.concat(after.owned, ", ") .. "）") or "")
        .. ":\n" .. dout
    end
    d = after
  end

  print("编辑器: 已同步（unchanged=" .. (d.cl["unchanged"] or 0) .. "）")
  if #d.foreign > 0 then
    print("注意: 地图侧多出 " .. #d.foreign .. " 个三端外的文件（编辑器生成物等），deploy 保留。")
  end
  return true
end

return M
