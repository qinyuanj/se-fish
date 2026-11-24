-- 把 SE 信号连接纳入调用方已有的 Spoke 作用域；不拥有事件分发或额外生命周期。
local HostSignal = {}

function HostSignal.connect(scope, signal, handler)
  if scope == nil or signal == nil or type(signal.Connect) ~= "function" then return nil end
  local connection = signal:Connect(handler)
  scope:on_cleanup(function()
    pcall(function() connection:Disconnect() end) -- 宿主单位或信号可能已先卸载
  end)
  return connection
end

return HostSignal
