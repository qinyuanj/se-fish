-- 部署计划：仓库根白名单 → 本仓库拥有的子树清单。纯模块：不碰文件系统、不起子进程，
-- 目录清单由调用方注入（tools/deploy.lua 交给 tools/wsl_seam 枚举）。部署规则在这里回答
-- 一次，镜像与编辑器收尾只搬字节。
local M = {}

-- 官方强制的工作区根目录，即部署白名单；顺序即部署顺序。
-- 重置粒度是每个端下的一级子树；宿主端根下仓库没有的条目见 M.stale；
-- 白名单之外的内容（无论仓库根还是宿主目录）一律不碰。
M.REALMS = { "client", "common", "server" }

-- 本仓库拥有的子树清单：<端>/<child>，仓库路径与宿主目录路径同名。
-- 三端 packages/ 与业务子目录同样归本仓库，镜像与 clean 一视同仁。
-- list_entries(realm) 返回 { {name=, dir=}, ... }（调用方保证按名排序）。
-- 返回 { {rel=, dir=, src=, dst=}, ... }；dir 在这里定一次，后续不再问文件系统。
function M.targets(workspace, list_entries, realms)
  local targets = {}
  for _, realm in ipairs(realms or M.REALMS) do
    for _, child in ipairs(list_entries(realm)) do
      local rel = realm .. "/" .. child.name
      targets[#targets + 1] = {
        rel = rel,
        dir = child.dir,
        src = rel,
        dst = workspace .. "/" .. rel,
      }
    end
  end
  return targets
end

-- 宿主残留清单：宿主 <端>/ 下有、仓库 <端>/ 下没有的一级条目（仓库已删的散文件或整棵子树）。
-- 宿主端根专用于镜像，这些条目只会是旧部署留下的，镜像前删掉；端以外的宿主内容不在清单里。
-- list_entries 同时回答仓库端根（realm）与宿主端根（workspace/realm），宿主端根不存在时返回空表。
-- 返回 { {rel=, dir=, dst=}, ... }，按端、再按名排序。
function M.stale(workspace, list_entries, realms)
  local stale = {}
  for _, realm in ipairs(realms or M.REALMS) do
    local owned = {}
    for _, child in ipairs(list_entries(realm)) do owned[child.name] = true end
    for _, child in ipairs(list_entries(workspace .. "/" .. realm)) do
      if not owned[child.name] then
        local rel = realm .. "/" .. child.name
        stale[#stale + 1] = { rel = rel, dir = child.dir, dst = workspace .. "/" .. rel }
      end
    end
  end
  return stale
end

return M
