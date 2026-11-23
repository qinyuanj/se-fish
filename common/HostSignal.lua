-- 把 SE 信号连接纳入调用方已有的 Spoke 作用域；不拥有事件分发或额外生命周期。
local HostSignal = {}

function HostSignal.connect(scope, signal, handler)
  if scope == nil or signal == nil or type(signal.Connect) ~= "function" then return nil end
  local connection = signal:Connect(handler)
  scope:on_cleanup(function()
    pcall(function() connection:Disconnect() end)
  end)
  return connection
end

-- 动态短生命周期信号由调用方保存返回句柄，并在其已有清理函数中 Disconnect。
function HostSignal.listen(signal, handler)
  if signal == nil or type(signal.Connect) ~= "function" then return nil end
  return signal:Connect(handler)
end

return HostSignal
