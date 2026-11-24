-- editor 子命令：打开、查看、停止编辑器与地图，统一走 editor-cli。
-- 不为某张地图或某类启动失败做特殊分支；失败时只报告 status 摘要和通用下一步。
local seam = require("tools.seam")
local dkjson = require("dkjson")

local M = {}

function M.usage()
  return table.concat({
    "用法: lua tools/cli.lua editor [open|status|stop] [选项]",
    "",
    "  open              启动编辑器并打开地图（缺省动作）；已打开时直接返回",
    "  status            查看编辑器与地图是否就绪",
    "  stop <target>     停止实例，target 为 pid 或 http port",
    "  --map <id|目录>   指定地图；省略时取 map_ledger 中最近更新的 SE 地图",
    "  --wait <秒>       open 等待就绪的秒数，默认 120",
    "示例: lua tools/cli.lua editor open --map 6aab8e60ee615830184f4963",
  }, "\n") .. "\n"
end

-- CLI 输出前面可能有 warning，取第一个 JSON 对象即可。
function M.parse_json(out)
  if type(out) ~= "string" then return nil, "没有输出" end
  local body = out:match("%b{}")
  if not body then return nil, "输出不含 JSON 对象" end
  local ok, value = pcall(dkjson.decode, body)
  if not ok or type(value) ~= "table" then return nil, "JSON 解析失败" end
  return value
end

-- map_ledger.json 里取 updated_at 最大的 SE 地图；只给 open 当缺省目标。
function M.parse_map_ledger(text)
  local ok, ledger = pcall(dkjson.decode, text)
  if not ok or type(ledger) ~= "table" then return nil end
  local best, best_time
  for id, item in pairs(ledger) do
    if type(item) == "table" and item.is_se and type(item.updated_at) == "number"
      and (not best_time or item.updated_at > best_time) then
      best, best_time = { id = id, dir = item.map_dir }, item.updated_at
    end
  end
  return best
end

function M.default_map()
  local home = seam.windows_env("USERPROFILE")
  if not home then return nil end
  local file = io.open(home .. "/.eggitor/cli/map_ledger.json", "rb")
  if not file then return nil end
  local text = file:read("a")
  file:close()
  return M.parse_map_ledger(text)
end

local function editor_cli()
  local exe = seam.editor_cli()
  if not exe or not seam.exists(exe) then return nil, "找不到 editor-cli：" .. tostring(exe) end
  return exe
end

function M.status()
  local exe, err = editor_cli()
  if not exe then return nil, err end
  local _, out = seam.capture({ argv = { exe, "--json", "status" } })
  local parsed, json_err = M.parse_json(out)
  if not parsed then return nil, json_err end
  return parsed
end

function M.summary(s)
  if type(s) ~= "table" or not s.running then return "没有运行中的编辑器实例" end
  if s.ready and s.role == "editor" and s.map_name and s.map_name ~= "" then
    return "地图已打开：" .. s.map_name .. "（" .. tostring(s.editor_mode)
      .. "，map_id=" .. tostring(s.map_id) .. "）"
  end
  return "编辑器在运行但未进图：role=" .. tostring(s.role)
    .. " lifecycle=" .. tostring(s.lifecycle)
    .. " mode=" .. tostring(s.editor_mode) .. " ready=" .. tostring(s.ready)
end

local function is_open(s)
  return type(s) == "table" and s.ready and s.role == "editor"
    and s.map_name ~= nil and s.map_name ~= ""
end

function M.open(target, wait)
  local exe, err = editor_cli()
  if not exe then io.stderr:write("editor: " .. err .. "\n"); return 1 end
  local current = M.status()
  if is_open(current) then
    print("无需启动，" .. M.summary(current))
    return 0
  end
  if not target then
    local map = M.default_map()
    if not map then
      io.stderr:write("editor: 无法从 map_ledger 确定地图，请用 --map <id|目录>\n")
      return 1
    end
    target = map.id or map.dir
  end
  local argv = { exe, "--json", "start", "--map", target,
    "--wait-timeout", tostring(wait or 120), "--keep-on-timeout" }
  local _, out = seam.capture({ argv = argv })
  local result, json_err = M.parse_json(out)
  if not result then
    io.stderr:write("editor: start 没返回可用结果：" .. tostring(json_err) .. "\n")
    return 1
  end
  if result.error then
    io.stderr:write("editor: start 失败 " .. tostring(result.error.code) .. "："
      .. tostring(result.error.message) .. "\n")
    return 1
  end
  local after = M.status()
  print(M.summary(after))
  if is_open(after) then return 0 end
  io.stderr:write("editor: start 已提交但地图未就绪；用 editor status 查看后重试 open。\n")
  return 1
end

function M.stop(target)
  local exe, err = editor_cli()
  if not exe then io.stderr:write("editor: " .. err .. "\n"); return 1 end
  if not target then io.stderr:write("editor: stop 需要 pid 或 http port\n" .. M.usage()); return 2 end
  local code, out = seam.spawn({ argv = { exe, "stop", target } })
  if code ~= 0 then io.stderr:write("editor: stop 失败（退出码 " .. tostring(code) .. "）："
    .. tostring(out) .. "\n"); return 1 end
  print("已停止：" .. target)
  return 0
end

function M.main(args)
  args = args or {}
  local action, target, wait = "open", nil, 120
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then io.write(M.usage()); return 0
    elseif a == "open" or a == "status" or a == "stop" then action = a
    elseif a == "--map" then
      i = i + 1
      if i > #args then io.stderr:write(M.usage()); return 2 end
      target = args[i]
    elseif a == "--wait" then
      i = i + 1
      if i > #args then io.stderr:write(M.usage()); return 2 end
      wait = tonumber(args[i])
      if not wait or wait <= 0 then io.stderr:write("editor: --wait 必须是正数\n"); return 2 end
    elseif action == "stop" and target == nil then target = a
    else
      io.stderr:write("editor: 未知参数 " .. a .. "\n" .. M.usage())
      return 2
    end
    i = i + 1
  end
  if action == "status" then
    local s, err = M.status()
    if not s then io.stderr:write("editor: " .. err .. "\n"); return 1 end
    print(M.summary(s))
    return is_open(s) and 0 or 1
  elseif action == "stop" then
    return M.stop(target)
  end
  return M.open(target, wait)
end

return M
