-- 编辑器宿主目录定位：deploy 与 sync 共用的唯一真源。
-- 宿主目录 = 编辑器 `code init` 绑定的本地 Lua 工程（根有 eggy.json），仓库只往里镜像
-- 白名单子树，不往里写别的东西。默认值由 WSL 接缝层推导：USERPROFILE 经 cmd.exe 取值后
-- 转成 WSL 路径，再拼出钓鱼图宿主目录。EGGY_WORKSPACE 可覆盖，接受 Linux 形式与
-- `C:\...` 形式，空串当作未设置（避免把 /MIR 写到文件系统根）。
local seam = require("tools.wsl_seam")

local M = {}

M.DEFAULT_REL = "Desktop/dev/eggy/LuaSource_钓鱼怎么这么危险啊喂！"

-- 返回宿主目录（Linux 形式）；定位失败返回 nil, 原因。
function M.resolve()
  local override = os.getenv("EGGY_WORKSPACE")
  if override ~= nil and override ~= "" then
    local path, err = seam.to_linux(override)
    if not path then return nil, "EGGY_WORKSPACE 无法转成 WSL 路径: " .. tostring(err) end
    if path:sub(1, 1) ~= "/" then
      return nil, "EGGY_WORKSPACE 必须是绝对路径: " .. tostring(override)
    end
    return path
  end
  return seam.default_workspace()
end

return M
