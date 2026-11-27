-- 官方包单向输出叶子投影层（ability / attr）共用的小工具：
-- 叶子层的错误上报统一成「opts.on_error 优先、否则按模块标签打印玩家标识」，避免每层各写一份。
-- 本模块与 ability_leaf / attr_leaf 同层（server.world_host），只被叶子层向下复用。

local LeafReport = {}

--- 叶子层统一错误上报：opts.on_error 优先，否则按标签与玩家标识打印。
---@param opts table 叶子选项（可带 on_error 回调）
---@param tag string 打印标签（模块名，如 "AbilityLeaf"）
---@param user_id any 玩家标识，仅用于打印
---@param msg string 错误消息
function LeafReport.report_error(opts, tag, user_id, msg)
  if type(opts.on_error) == "function" then
    opts.on_error(msg)
  else
    print("[" .. tag .. "]", user_id, msg)
  end
end

return LeafReport
