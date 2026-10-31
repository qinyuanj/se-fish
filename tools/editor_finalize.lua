-- 编辑器收尾：镜像落盘后执行 code validate → （与编辑器有差异时）code push → code diff 复核。
-- 三端（client/common/server）里地图有、宿主没有的文件是本地已删的代码，用
-- code push --delete --yes 一并删掉；三端以外的地图独有文件（temp/ 等编辑器生成物）只提示、保留。
-- 两类同时出现时 --delete 分不开它们，失败关闭、不推送。push 之后仍不一致才报告尚未同步。
--
-- 本模块依赖正在运行的编辑器与部署端的 editor-cli.exe（位置由 WSL 接缝层从 USERPROFILE
-- 推导）。interop 或推导失败时报错并返回非零；编辑器没装、宿主未绑定或地图未打开时打印
-- 跳过，磁盘镜像仍算完成，但不宣称编辑器内代码已同步。
-- 宿主必须有自己的 eggy.json，避免 CLI 向上下层目录寻找绑定而读到别的工程。
--
-- 纯解析部分（parse_changelist / map_only / split_map_only / behind_count）单独导出，可脱离编辑器测。
local shell = require("tools.wsl_seam")
local exit_code = require("tools.exit_code")
local plan = require("tools.deploy_plan")

local M = {}

-- 跑一条 code 子命令。必须给 --workspace：不给就按进程 cwd 找绑定，而 cwd 是仓库根。
-- 部署端的 exe 只认 Windows 路径，所以 --workspace 经 wslpath 转成 Windows 形式。
local function editor_cli(exe, ws_win, argline)
  return shell.capture(shell.q(exe) .. " " .. argline .. " --workspace " .. shell.q(ws_win))
end

-- 解析 `code diff` 文本里的 changelist 行：
-- changelist: only-local=N differs=N only-on-map=N unchanged=N
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

-- 返回 true 表示收尾完成（含跳过）；失败返回 nil, 原因[, 3]——第三个值 exit_code.UNAVAILABLE 表示平台不可用
-- （interop 或 USERPROFILE 推导失败，推不出 editor-cli.exe），调用方据此退 3。
function M.run(ws)
  local exe, err = shell.editor_cli()
  if not exe then
    return nil, "编辑器收尾失败: " .. tostring(err), exit_code.UNAVAILABLE
  end
  if not shell.exists(exe) then
    print("编辑器收尾跳过: 未找到 editor-cli.exe（" .. exe .. "）")
    return true
  end
  if not shell.exists(ws .. "/eggy.json") then
    print("编辑器收尾跳过: 宿主目录没有 eggy.json（" .. ws .. " 不是编辑器绑定的 Lua 工程）")
    return true
  end
  local ws_win, win_err = shell.to_windows(ws)
  if not ws_win then
    return nil, "编辑器收尾失败: " .. tostring(win_err)
  end

  local code, out = editor_cli(exe, ws_win, "code validate")
  if not out:find("validate: OK", 1, true) then
    return nil, "code validate 未通过（退出码 " .. tostring(code) .. "）:\n" .. out
  end
  print("validate: OK")

  code, out = editor_cli(exe, ws_win, "code diff")
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
    local push = #d.owned > 0 and "code push --delete --yes" or "code push"
    local pcode, pout = editor_cli(exe, ws_win, push)
    if pcode ~= 0 then
      return nil, "code push 失败（退出码 " .. tostring(pcode) .. "）:\n" .. pout
    end
    print("push: 已推送 " .. M.behind_count(d.cl) .. " 个本地新增或不同文件，删除地图上 "
      .. #d.owned .. " 个本地已删的三端文件")

    local dcode, dout = editor_cli(exe, ws_win, "code diff")
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
