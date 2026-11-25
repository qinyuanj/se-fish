-- 宿主运行日志（<宿主目录>/log.txt）按阈值清理模块。
-- 内部模块，供 tools/deploy.lua 日常调用。
-- 仅在 log.txt 超过体积或静置时长阈值时直接删除；若被编辑器占用则打印提示并跳过，不中断部署。
local seam = require("tools.seam")

local M = {}

M.LOG_NAME = "log.txt"
M.MAX_BYTES = 512 * 1024
M.MAX_AGE_SEC = 4 * 3600

-- 纯判定：是否应当清理。返回 should_clean, reason。
function M.should_clean(info, opts)
  opts = opts or {}
  local size = type(info) == "table" and info.size or nil
  local mtime = type(info) == "table" and info.mtime or nil
  if not size or size <= 0 then
    return false, "missing_or_empty"
  end
  local max_bytes = opts.max_bytes ~= nil and opts.max_bytes or M.MAX_BYTES
  if max_bytes and size > max_bytes then
    return true, "size"
  end
  local max_age_sec = opts.max_age_sec ~= nil and opts.max_age_sec or M.MAX_AGE_SEC
  if max_age_sec and mtime then
    local now = opts.now or os.time()
    if (now - mtime) > max_age_sec then
      return true, "age"
    end
  end
  return false, "below_threshold"
end

-- 执行宿主 log.txt 阈值清理。
-- 返回 { status = "removed"|"skipped"|"locked", reason = <string>, size = <int> }。
function M.clean(ws, opts)
  opts = opts or {}
  if not ws or ws == "" then
    return { status = "skipped", reason = "no_workspace", size = 0 }
  end
  local log_path = seam.normalize(ws) .. "/" .. M.LOG_NAME
  local size = seam.size(log_path)
  local mtime = seam.mtime(log_path)
  local should, reason = M.should_clean({ size = size, mtime = mtime }, opts)
  if not should then
    return { status = "skipped", reason = reason, size = size or 0 }
  end
  local remove_fn = opts.remove_fn or os.remove
  local ok, err = remove_fn(log_path)
  if not ok then
    return { status = "locked", reason = tostring(err or "文件被占用"), size = size }
  end
  return { status = "removed", reason = reason, size = size }
end

local REASON_LABEL = {
  size = "超过 512KB",
  age = "超过 4 小时未写入",
}

-- 供 deploy 调用：未达阈值时静默，清理或遇锁时打印一行提示，绝不中断主流程。
function M.maybe_clean(ws, opts)
  local ok, res = pcall(M.clean, ws, opts)
  if not ok then
    print("宿主日志清理跳过（内部异常：" .. tostring(res) .. "）")
    return nil
  end
  if res.status == "removed" then
    print(string.format("宿主日志已清理（%s，%.1f KB）",
      REASON_LABEL[res.reason] or tostring(res.reason), res.size / 1024))
  elseif res.status == "locked" then
    print("宿主日志清理跳过（log.txt 可能被编辑器占用：" .. tostring(res.reason) .. "）")
  end
  return res
end

return M
