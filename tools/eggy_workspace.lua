-- 编辑器宿主目录定位：deploy 与 sync 共用的唯一真源（ADR-0017，Windows 原生单环境）。
-- 宿主目录 = 编辑器 `code init` 绑定的本地 Lua 工程（根有 eggy.json），仓库只往里镜像
-- 白名单子树，不往里写别的东西。默认值由接缝层推导：读进程环境变量 USERPROFILE，拼出
-- 钓鱼图宿主目录。EGGY_WORKSPACE 可覆盖，空串当作未设置（避免把镜像写到文件系统根）；
-- 结果统一为正斜杠绝对路径，不再有 to_linux / /mnt/c 形式。
local seam = require("tools.seam")

local M = {}

M.DEFAULT_REL = seam.DEFAULT_WORKSPACE_REL

-- 返回宿主目录（正斜杠绝对路径）；定位失败返回 nil, 原因。
function M.resolve()
  local override = seam.windows_env("EGGY_WORKSPACE")
  if override ~= nil and override ~= "" then
    if not (override:match("^%a:/") or override:sub(1, 2) == "//") then
      return nil, "EGGY_WORKSPACE 必须是绝对路径: " .. tostring(override)
    end
    return override
  end
  return seam.default_workspace()
end

return M
